defmodule Handbean.Repo do
  use Ecto.Repo,
    otp_app: :handbean,
    adapter: Ecto.Adapters.SQLite3

  @impl true
  def init(_type, config) do
    config =
      config
      |> resolve_database()
      |> Keyword.put(:journal_mode, :wal)
      |> Keyword.put(:synchronous, :full)
      |> Keyword.put(:foreign_keys, :on)
      |> Keyword.put_new(:busy_timeout, 5_000)
      |> Keyword.put_new(:wal_auto_check_point, 1_000)

    {:ok, config}
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
