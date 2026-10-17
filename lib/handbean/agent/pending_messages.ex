defmodule Handbean.Agent.PendingMessages do
  @moduledoc """
  UI projection of candidate messages. Session/CandidateQueue remain the owner.
  """

  @type deliver_as :: :steer | :follow_up
  @type status :: :queued | :undelivered | :resending
  @type item :: %{
          optional(:content) => String.t() | nil,
          optional(:attachments) => list(),
          deliver_as: deliver_as(),
          status: status()
        }
  @type t :: %{optional(String.t()) => item()}

  @spec new() :: t()
  def new, do: %{}

  @spec put_queued(t(), String.t(), term(), map()) :: t()
  def put_queued(pending, id, deliver_as, extra \\ %{})

  def put_queued(pending, id, deliver_as, extra)
      when is_map(pending) and is_binary(id) and id != "" and is_map(extra) do
    deliver_as = normalize_deliver_as(deliver_as) || :steer
    extra = sanitize_extra(extra)

    Map.update(
      pending,
      id,
      Map.merge(%{deliver_as: deliver_as, status: :queued}, extra),
      fn existing ->
        existing
        |> Map.put(:deliver_as, deliver_as)
        |> Map.put(:status, :queued)
        |> Map.merge(extra, fn _key, left, right -> if is_nil(right), do: left, else: right end)
      end
    )
  end

  def put_queued(pending, _id, _deliver_as, _extra), do: pending

  @spec drop(t(), String.t() | [String.t()] | nil) :: t()
  def drop(pending, ids) when is_list(ids) do
    Enum.reduce(ids, pending, fn
      id, acc when is_binary(id) -> Map.delete(acc, id)
      _, acc -> acc
    end)
  end

  def drop(pending, id) when is_binary(id), do: Map.delete(pending, id)
  def drop(pending, _), do: pending

  @spec apply_injected(t(), map()) :: t()
  def apply_injected(pending, payload) when is_map(payload) do
    payload = stringify(payload)

    cond do
      is_list(payload["message_ids"]) ->
        drop(pending, payload["message_ids"])

      is_binary(payload["message_id"]) and payload["message_id"] != "" ->
        extra =
          if is_binary(payload["content"]),
            do: %{content: payload["content"]},
            else: %{}

        put_queued(pending, payload["message_id"], payload["deliver_as"], extra)

      true ->
        pending
    end
  end

  def apply_injected(pending, _), do: pending

  @spec apply_deleted(t(), map() | String.t()) :: t()
  def apply_deleted(pending, payload) when is_map(payload) do
    payload = stringify(payload)
    drop(pending, payload["message_id"] || payload["id"])
  end

  def apply_deleted(pending, id) when is_binary(id), do: drop(pending, id)
  def apply_deleted(pending, _), do: pending

  @spec apply_run_end(t(), term()) :: t()
  def apply_run_end(pending, status) do
    if terminal_run_end?(status), do: mark_undelivered(pending), else: pending
  end

  @doc "Recover missed queue controls in sequence, without replaying transcript text."
  def replay(pending, events, last_seq) do
    events
    |> Enum.filter(&(&1.seq > last_seq))
    |> Enum.sort_by(& &1.seq)
    |> Enum.reduce(pending, fn event, acc ->
      case event.kind do
        :candidate_message_injected -> apply_injected(acc, event.payload)
        :candidate_message_deleted -> apply_deleted(acc, event.payload)
        :run_end -> apply_run_end(acc, stringify(event.payload)["status"])
        _ -> acc
      end
    end)
  end

  @spec terminal_run_end?(term()) :: boolean()
  def terminal_run_end?(status), do: Handbean.PubSub.AgentEvent.terminal_status?(status)

  @spec mark_undelivered(t()) :: t()
  def mark_undelivered(pending) do
    Map.new(pending, fn
      {id, %{status: :queued} = item} -> {id, %{item | status: :undelivered}}
      pair -> pair
    end)
  end

  @spec put_status(t(), String.t(), status()) :: t()
  def put_status(pending, id, status)
      when is_map(pending) and is_binary(id) and status in [:queued, :undelivered, :resending] do
    case Map.get(pending, id) do
      nil -> pending
      item -> Map.put(pending, id, Map.put(item, :status, status))
    end
  end

  def put_status(pending, _id, _status), do: pending

  @spec reconcile(t(), [map()], boolean()) :: t()
  def reconcile(pending, session_items, running?, entries \\ [])

  def reconcile(pending, session_items, running?, entries)
      when is_map(pending) and is_list(session_items) do
    entries = List.wrap(entries)

    undelivered =
      pending
      |> Enum.filter(fn {_id, item} -> item[:status] in [:undelivered, :resending] end)
      |> Map.new()

    queued =
      if running? do
        session_items
        |> Enum.flat_map(&queued_from_session(&1, pending, entries))
        |> Map.new()
      else
        entries
        |> Enum.filter(fn entry ->
          entry["delivery"] in ["steer", "follow_up"] and
            entry["consumption"] == "pending"
        end)
        |> Enum.flat_map(fn entry ->
          queued_from_session(
            %{id: entry["id"], content: entry["content"], deliver_as: entry["delivery"]},
            pending,
            entries
          )
        end)
        |> Map.new()
        |> mark_undelivered()
      end

    if running?, do: Map.merge(undelivered, queued), else: Map.merge(queued, undelivered)
  end

  def reconcile(pending, _session_items, _running?, _entries), do: pending

  defp queued_from_session(item, pending, entries) do
    id = item_id(item)

    deliver_as =
      normalize_deliver_as(Handbean.Utils.SafeMap.get_any(item, :deliver_as, "deliver_as"))

    if id == "" or deliver_as not in [:steer, :follow_up] do
      []
    else
      existing = Map.get(pending, id, %{})
      entry = transcript_entry(entries, id)

      [
        {id,
         %{
           deliver_as: deliver_as,
           status: :queued,
           content: pick_text(existing[:content], entry, item),
           attachments: pick_attachments(existing[:attachments], entry)
         }}
      ]
    end
  end

  defp transcript_entry(entries, id) do
    Enum.find(entries, fn
      %{"id" => ^id} -> true
      %{id: ^id} -> true
      _ -> false
    end)
  end

  defp pick_text(existing, entry, item) do
    cond do
      is_binary(existing) and existing != "" -> existing
      is_binary(entry_field(entry, "content")) -> entry_field(entry, "content")
      is_binary(item[:content]) -> item[:content]
      is_binary(item["content"]) -> item["content"]
      true -> existing
    end
  end

  defp pick_attachments(existing, entry) do
    cond do
      is_list(existing) and existing != [] -> existing
      is_list(entry_field(entry, "attachments")) -> entry_field(entry, "attachments")
      true -> existing
    end
  end

  defp entry_field(nil, _key), do: nil

  defp entry_field(entry, key) when is_map(entry) and is_binary(key) do
    Map.get(entry, key) ||
      case key do
        "content" -> Map.get(entry, :content)
        "attachments" -> Map.get(entry, :attachments)
        _ -> nil
      end
  end

  defp item_id(%{id: id}) when is_binary(id) and id != "", do: id
  defp item_id(%{"id" => id}) when is_binary(id) and id != "", do: id
  defp item_id(_), do: ""

  defp sanitize_extra(extra) do
    extra
    |> Map.take([:content, :attachments])
    |> then(fn taken ->
      taken
      |> then(fn m -> if is_binary(m[:content]), do: m, else: Map.delete(m, :content) end)
      |> then(fn m -> if is_list(m[:attachments]), do: m, else: Map.delete(m, :attachments) end)
    end)
  end

  defp normalize_deliver_as(value) when value in [:follow_up, "follow_up"], do: :follow_up
  defp normalize_deliver_as(value) when value in [:steer, "steer"], do: :steer
  defp normalize_deliver_as(_), do: nil

  defp stringify(payload) when is_map(payload) do
    Map.new(payload, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end
end
