defmodule Handbean.ConversationArtifacts.Cleaner do
  @moduledoc """
  Periodically applies retention and capacity limits to conversation artifacts.
  Stale snapshot temporary files are removed. Final snapshots are retained because
  asynchronous publishers may outlive the registered run; orphan pruning requires
  a caller that can establish there are no pending publishers.

  Newly written tool-result spills have a minimum retention window, so capacity
  cleanup does not remove results from current or recently completed runs.
  """

  use GenServer

  require Logger

  @default_interval_ms :timer.hours(1)
  @default_retention_days 30
  @default_max_bytes 512 * 1024 * 1024
  @default_min_retention_seconds 24 * 60 * 60

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc false
  def run_now do
    GenServer.call(__MODULE__, :run_now, 30_000)
  end

  @impl true
  def init(opts) do
    interval_ms =
      Keyword.get(opts, :interval_ms, configured(:cleanup_interval_ms, @default_interval_ms))

    schedule(interval_ms)
    {:ok, %{interval_ms: interval_ms}}
  end

  @impl true
  def handle_call(:run_now, _from, state) do
    {:reply, cleanup(), state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    _result = cleanup()
    schedule(state.interval_ms)
    {:noreply, state}
  end

  defp cleanup do
    result =
      Handbean.ConversationArtifacts.prune_tool_results(
        retention_seconds: configured(:retention_days, @default_retention_days) * 24 * 60 * 60,
        max_bytes: configured(:max_tool_result_bytes, @default_max_bytes),
        min_retention_seconds:
          configured(:min_tool_result_retention_seconds, @default_min_retention_seconds)
      )

    snapshots =
      Handbean.ConversationArtifacts.prune_change_snapshots(
        retention_seconds: configured(:retention_days, @default_retention_days) * 24 * 60 * 60,
        max_bytes: configured(:max_change_snapshot_bytes, @default_max_bytes),
        min_retention_seconds:
          configured(:min_change_snapshot_retention_seconds, @default_min_retention_seconds)
      )

    result = Map.merge(result, snapshots, fn _key, first, second -> first + second end)

    if result.failed > 0 do
      Logger.warning(
        "[ConversationArtifacts.Cleaner] cleanup failures=#{result.failed} " <>
          "deleted=#{result.deleted} freed_bytes=#{result.freed_bytes}"
      )
    end

    result
  end

  defp configured(key, default) do
    :handbean
    |> Application.get_env(:conversation_artifacts, [])
    |> Keyword.get(key, default)
  end

  defp schedule(interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :cleanup, interval_ms)
  end
end
