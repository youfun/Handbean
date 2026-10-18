defmodule Handbean.PubSub.Projection do
  @moduledoc """
  Shared Web/native event admission and persisted-text projection.

  Session epoch/seq orders runtime events, not transcript history. Subscribe
  before loading a snapshot; discard seq <= its high-water mark within the same
  epoch. A gap or changed epoch requires snapshot and durable history recovery,
  never blindly concatenating missed text.

  Persisted text patches carry a transcript id, UTF-8 byte offset and clean
  text. A history read may be ahead of the Session snapshot: overlap is ignored
  and a missing prefix requires recovery. Neither case replays a side effect.
  """

  alias Handbean.PubSub.{AgentEvent, Session}

  def classify(event, topic, last_seq, epoch \\ nil)

  def classify(%AgentEvent{topic: topic, epoch: event_epoch}, topic, _last_seq, epoch)
      when is_binary(epoch) and is_binary(event_epoch) and event_epoch != epoch,
      do: :recover

  def classify(%AgentEvent{topic: topic, seq: seq}, topic, last_seq, _epoch) do
    cond do
      seq <= last_seq -> :ignore
      seq == last_seq + 1 -> :apply
      true -> :recover
    end
  end

  def classify(_event, _topic, _last_seq, _epoch), do: :ignore

  def snapshot(id) do
    if Session.whereis(id),
      do: Session.snapshot(id),
      else: %{last_seq: 0, events: [], meta: %{running?: false}}
  catch
    :exit, _ -> %{last_seq: 0, events: [], meta: %{running?: false}}
  end

  @doc "Read snapshot before durable history; callers commit neither on history failure."
  def recover(id, count \\ 100) do
    if Session.whereis(id) do
      snapshot = Session.recovery_snapshot(id)
      with {:ok, page} <- history(id, count), do: {:ok, %{snapshot: snapshot, history: page}}
    else
      {:error, :session_unavailable}
    end
  catch
    :exit, _ -> {:error, :session_unavailable}
  end

  @doc "Reload the newest history window while retaining the number of entries already loaded."
  def history(id, count \\ 100) do
    history_page(id, max(count, 100), nil, [])
  end

  @internal_content_types MapSet.new(["model_compaction", "memory_reflection"])

  @doc "Hide internal transcript records from user-facing projections."
  def visible_entries(entries) when is_list(entries) do
    Enum.reject(entries, fn entry ->
      MapSet.member?(@internal_content_types, entry["content_type"] || entry[:content_type])
    end)
  end

  defp history_page(id, count, before, newer) do
    case Handbean.ConversationTranscriptStore.page(id, limit: min(count, 200), before: before) do
      {:ok, page} ->
        visible = visible_entries(page.entries)
        entries = visible ++ newer
        remaining = count - length(visible)

        if remaining > 0 and page.has_more? do
          history_page(id, remaining, page.before, entries)
        else
          {:ok, %{page | entries: entries}}
        end

      error ->
        error
    end
  end

  def text_patch(
        entries,
        %{"transcript_id" => id, "text_offset" => offset, "text" => text} = payload
      ) do
    text_patch(entries, %{
      transcript_id: id,
      text_offset: offset,
      text: text,
      run_id: payload["run_id"]
    })
  end

  def text_patch(entries, %{transcript_id: id, text_offset: offset, text: text} = payload)
      when is_binary(id) and is_integer(offset) and offset >= 0 and is_binary(text) do
    existing = Enum.find(entries, &(&1["id"] == id))
    content = if existing, do: existing["content"] || "", else: ""
    size = byte_size(content)

    cond do
      size >= offset + byte_size(text) ->
        :ignore

      size < offset ->
        :recover

      true ->
        suffix = binary_part(text, size - offset, byte_size(text) - (size - offset))

        entry =
          existing ||
            %{
              "id" => id,
              "content_type" => "assistant_msg",
              "role" => "assistant",
              "status" => "streaming",
              "run_id" => payload[:run_id]
            }

        {:ok, Map.put(entry, "content", content <> suffix)}
    end
  end

  def text_patch(_entries, _payload), do: :recover
end
