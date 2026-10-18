defmodule Handbean.Agent.TranscriptRecovery do
  @moduledoc """
  Seals orphaned durable replies and tools after host restart.

  Candidates come from indexed SQLite envelope columns. Recovery never replays
  tools or restores executable approval continuations.
  """

  use GenServer

  require Logger

  alias Handbean.Agent.{Runner, TranscriptPersistence}
  alias Handbean.ConversationTranscriptStore.ConversationStore, as: SQLiteTranscript

  @startup_delay_ms 10_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def run, do: GenServer.call(__MODULE__, :run, :infinity)
  def recover(id), do: GenServer.call(__MODULE__, {:recover, id}, :infinity)

  # Kept as a transition API for callers that previously maintained marker
  # files. SQLite unfinished-entry indexes are now the only candidate source.
  def mark(_id), do: :ok
  def clear(_id), do: :ok

  @impl true
  def init(opts) do
    if Keyword.get(opts, :recover_on_start, true) do
      Process.send_after(self(), :recover, @startup_delay_ms)
    end

    {:ok, nil}
  end

  @impl true
  def handle_info(:recover, state) do
    recover_all()
    {:noreply, state}
  end

  def handle_info({:transcript_retry_persisted, id}, state) do
    case recover_orphan(id) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("[TranscriptRecovery] retry closure #{id}: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_call(:run, _from, state), do: {:reply, recover_all(), state}
  def handle_call({:recover, id}, _from, state), do: {:reply, recover_orphan(id), state}

  defp recover_all do
    SQLiteTranscript.unfinished_runs()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.reduce_while(:ok, fn {conversation_id, run_ids}, :ok ->
      case recover_runs(conversation_id, run_ids) do
        :ok ->
          {:cont, :ok}

        {:error, reason} ->
          Logger.error("[TranscriptRecovery] #{conversation_id}: #{inspect(reason)}")
          {:halt, {:error, reason}}
      end
    end)
  end

  defp recover_orphan(conversation_id) do
    case Runner.status(conversation_id) do
      {:error, :not_found} ->
        recover_runs(conversation_id, SQLiteTranscript.unfinished_runs(conversation_id))

      _ ->
        :ok
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  defp recover_runs(conversation_id, run_ids) do
    if active_runner?(conversation_id) do
      :ok
    else
      run_ids
      |> Enum.uniq()
      |> Enum.reduce_while(:ok, fn run_id, :ok ->
        result =
          TranscriptPersistence.handle_event(
            conversation_id,
            {:run_end, %{status: "error", error: "Host stopped before the run completed"}},
            run_id: run_id,
            source: :recovery
          )

        case result do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp active_runner?(conversation_id) do
    case Runner.status(conversation_id) do
      {:error, :not_found} -> false
      _ -> true
    end
  catch
    :exit, _reason -> false
  end
end
