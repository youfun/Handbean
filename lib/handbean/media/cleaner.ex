defmodule Handbean.Media.Cleaner do
  @moduledoc """
  Bounded cleanup for abandoned staged media and retryable pending deletes.

  A staged object is never collected while its conversation has an active run.
  The long default TTL also keeps cleanup away from the normal tool_end commit
  window.
  """

  use GenServer

  require Logger

  @default_interval_ms :timer.hours(1)
  @default_staged_ttl_seconds 24 * 60 * 60
  @default_pending_ttl_seconds 60

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc false
  def run_now do
    GenServer.call(__MODULE__, :run_now, 30_000)
  end

  @doc false
  def schedule_pending_delete do
    Process.send_after(__MODULE__, :cleanup_once, (@default_pending_ttl_seconds + 1) * 1_000)
    :ok
  end

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      staged_ttl_seconds: Keyword.get(opts, :staged_ttl_seconds, @default_staged_ttl_seconds),
      pending_ttl_seconds: Keyword.get(opts, :pending_ttl_seconds, @default_pending_ttl_seconds)
    }

    schedule(state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_call(:run_now, _from, state) do
    {:reply, cleanup(state), state}
  end

  @impl true
  def handle_info(:cleanup_once, state) do
    _result = cleanup(state)
    {:noreply, state}
  end

  def handle_info(:cleanup, state) do
    _result = cleanup(state)
    schedule(state.interval_ms)
    {:noreply, state}
  end

  defp cleanup(state) do
    staged_before = DateTime.add(DateTime.utc_now(), -state.staged_ttl_seconds, :second)
    pending_before = DateTime.add(DateTime.utc_now(), -state.pending_ttl_seconds, :second)

    staged =
      "staged"
      |> Handbean.Media.gc_candidates(staged_before)
      |> Enum.reject(&active_conversation?/1)

    staged_result =
      Enum.reduce(staged, %{deleted: 0, failed: 0}, fn media, counts ->
        case Handbean.Media.mark_pending_delete(media.conversation_id, [media.id]) do
          {:ok, 1} -> delete_one(%{media | status: "pending_delete"}, counts)
          {:error, _reason} -> Map.update!(counts, :failed, &(&1 + 1))
        end
      end)

    result =
      "pending_delete"
      |> Handbean.Media.gc_candidates(pending_before, active_conversation_only?: true)
      |> Enum.reduce(staged_result, &delete_one/2)
      |> cleanup_pending_conversations(pending_before)

    if result.failed > 0 do
      Logger.warning(
        "[Media.Cleaner] cleanup failures=#{result.failed} deleted=#{result.deleted}"
      )
    end

    result
  end

  defp cleanup_pending_conversations(counts, pending_before) do
    pending_before
    |> Handbean.ConversationStore.Deletion.pending_groups()
    |> Enum.reduce(counts, fn group, acc ->
      conversation_ids = Enum.map(group.conversations, & &1.id)

      if Handbean.ConversationStore.Deletion.runtime_active?(conversation_ids) do
        Handbean.ConversationStore.Deletion.force_quiesce(conversation_ids)
        Map.update!(acc, :failed, &(&1 + 1))
      else
        Handbean.ConversationStore.Deletion.force_quiesce(conversation_ids)
        media = Handbean.Media.pending_for_conversations(conversation_ids)
        delete_results = Enum.map(media, &Handbean.Media.delete_object/1)

        if Enum.all?(delete_results, &(&1 == :ok)) do
          case Handbean.ConversationStore.Deletion.finalize(
                 group.root_id,
                 conversation_ids,
                 Enum.map(media, & &1.id)
               ) do
            :ok -> Map.update!(acc, :deleted, &(&1 + length(media)))
            {:error, _reason} -> Map.update!(acc, :failed, &(&1 + 1))
          end
        else
          Map.update!(acc, :failed, &(&1 + 1))
        end
      end
    end)
  end

  defp delete_one(media, counts) do
    case Handbean.Media.delete_pending(media) do
      :ok -> Map.update!(counts, :deleted, &(&1 + 1))
      {:error, _reason} -> Map.update!(counts, :failed, &(&1 + 1))
    end
  end

  defp active_conversation?(media) do
    match?({:ok, %{running?: true}}, Handbean.Agent.Runner.status(media.conversation_id))
  end

  defp schedule(interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :cleanup, interval_ms)
  end
end
