defmodule Handbean.Repo do
  use Ecto.Repo,
    otp_app: :handbean,
    adapter: Ecto.Adapters.SQLite3

  require Logger

  @impl true
  def init(_type, config) do
    config =
      config
      |> resolve_database()
      |> Keyword.put(:journal_mode, :wal)
      # WAL + NORMAL: commits survive process crashes (the common agent
      # failure); only a power loss can lose the newest frames, bounded by
      # the FULL checkpoints taken at turn/run boundaries (see
      # checkpoint_wal/0). FULL would fsync every stream flush — one per
      # StreamBatch interval — the dominant write cost on mobile flash.
      |> Keyword.put_new(:synchronous, :normal)
      |> Keyword.put(:foreign_keys, :on)
      |> Keyword.put_new(:busy_timeout, 5_000)
      |> Keyword.put_new(:wal_auto_check_point, 1_000)

    {:ok, config}
  end

  @doc """
  Best-effort FULL WAL checkpoint for lifecycle boundaries.

  With `synchronous: :normal`, committed frames stay in the WAL — durable
  across process crashes — until a checkpoint copies them into the database
  file and syncs it. Checkpointing at turn/run boundaries bounds what a power
  loss can lose to the streaming deltas since the last boundary. A busy
  result (readers still active) is not a failure; the next boundary retries.
  """
  @spec checkpoint_wal() :: :ok
  def checkpoint_wal do
    case query("PRAGMA wal_checkpoint(FULL)") do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.debug(fn -> "[Repo] wal checkpoint skipped: #{inspect(reason)}" end)
        :ok
    end
  rescue
    _error -> :ok
  end

  @doc false
  def database_path(config \\ Application.fetch_env!(:handbean, __MODULE__)) do
    config
    |> resolve_database()
    |> Keyword.fetch!(:database)
    |> Path.expand()
  end

  defp resolve_database(config) do
    case Handbean.Host.get(:data_dir) do
      dir when is_binary(dir) and dir != "" ->
        if configured_database?(config),
          do: config,
          else: Keyword.put(config, :database, Path.join(dir, "handbean.db"))

      _ ->
        config
    end
  end

  # Dev sets both data_dir and an explicit database. Packaged hosts set only
  # data_dir and expect handbean.db beside it.
  defp configured_database?(config) do
    case Keyword.get(config, :database) do
      path when is_binary(path) and path != "" -> true
      _ -> false
    end
  end
end
