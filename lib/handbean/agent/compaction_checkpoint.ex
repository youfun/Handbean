defmodule Handbean.Agent.CompactionCheckpoint do
  @moduledoc false

  alias Handbean.Agent.Message
  alias Handbean.ConversationTranscriptStore

  @content_type "model_compaction"
  @version 1
  @stable_fields ~w(
    id role content content_type message_type attachments raw_content images status phase
    tool_use_id tool_name tool_status input output tool_error content_blocks
  )

  @spec persist(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def persist(conversation_id, event, opts)
      when is_binary(conversation_id) and is_map(event) and is_list(opts) do
    with false <- event[:context_edited] == true,
         {:ok, entries} <- ConversationTranscriptStore.list(conversation_id, opts),
         {:ok, checkpoint} <- build_entry(entries, event),
         {:ok, persisted} <- ConversationTranscriptStore.append(conversation_id, checkpoint, opts) do
      {:ok, persisted}
    else
      true -> {:error, :context_edited}
      {:error, _reason} = error -> error
    end
  end

  @spec checkpoint?(map()) :: boolean()
  def checkpoint?(%{"content_type" => @content_type, "version" => @version}), do: true
  def checkpoint?(_entry), do: false

  @spec valid?(map(), [map()]) :: boolean()
  def valid?(checkpoint, entries) do
    with true <- checkpoint?(checkpoint),
         true <- checkpoint_follows_boundary?(checkpoint, entries),
         {:ok, source} <-
           source_entries(
             entries,
             checkpoint["first_entry_id"],
             checkpoint["covered_through_id"]
           ) do
      checkpoint["source_count"] == length(source) and
        checkpoint["source_digest"] == digest(source)
    else
      _ -> false
    end
  end

  @spec projection([map()]) :: {:ok, map()} | :none
  def projection(entries) when is_list(entries) do
    checkpoint =
      entries
      |> Enum.reverse()
      |> Enum.find(&valid?(&1, entries))

    case checkpoint do
      %{} ->
        raw = Enum.reject(entries, &checkpoint?/1)
        first_index = Enum.find_index(raw, &(&1["id"] == checkpoint["first_entry_id"]))

        boundary_index =
          Enum.find_index(raw, &(&1["id"] == checkpoint["covered_through_id"]))

        {:ok,
         %{
           checkpoint: checkpoint,
           first_entry: Enum.at(raw, first_index),
           suffix_entries: Enum.drop(raw, boundary_index + 1)
         }}

      nil ->
        :none
    end
  end

  @spec digest([map()]) :: String.t()
  def digest(entries) do
    entries
    |> Enum.map(&Map.take(&1, @stable_fields))
    |> Handbean.JSON.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp build_entry(entries, event) do
    id_index = Map.new(entries, &{&1["id"], &1})
    previous_summary = event[:previous_summary]
    messages = List.wrap(event[:messages_to_summarize])

    with %Message{id: first_id} when is_binary(first_id) <- event[:first],
         true <- valid_provenance?(first_id, id_index, entries),
         true <- valid_previous_summary?(previous_summary, id_index, entries),
         true <-
           Enum.all?(messages, fn
             %Message{id: id} when is_binary(id) -> valid_provenance?(id, id_index, entries)
             _ -> false
           end),
         {:ok, boundary_id} <- raw_boundary(messages, id_index),
         {:ok, source} <- source_entries(entries, first_id, boundary_id),
         summary when is_binary(summary) and summary != "" <- event[:summary] do
      {:ok,
       %{
         "id" => "compaction-#{Ecto.UUID.generate()}",
         "content_type" => @content_type,
         "message_type" => "internal",
         "role" => "internal",
         "direction" => "internal",
         "version" => @version,
         "summary" => String.trim(summary),
         "first_entry_id" => first_id,
         "covered_through_id" => boundary_id,
         "source_count" => length(source),
         "source_digest" => digest(source),
         "model" => event[:model],
         "context_window" => event[:context_window],
         "context_generation" => event[:context_generation],
         "run_id" => event[:run_id]
       }}
    else
      false -> {:error, :invalid_provenance}
      nil -> {:error, :invalid_provenance}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_checkpoint}
    end
  end

  defp valid_previous_summary?(nil, _id_index, _entries), do: true

  defp valid_previous_summary?(%Message{id: id}, id_index, entries) when is_binary(id) do
    case id_index[id] do
      %{} = checkpoint -> checkpoint?(checkpoint) and valid?(checkpoint, entries)
      _ -> false
    end
  end

  defp valid_previous_summary?(_message, _id_index, _entries), do: false

  defp valid_provenance?(id, id_index, entries) do
    case id_index[id] do
      %{} = checkpoint -> not checkpoint?(checkpoint) or valid?(checkpoint, entries)
      _ -> false
    end
  end

  defp checkpoint_follows_boundary?(checkpoint, entries) do
    checkpoint_index = Enum.find_index(entries, &(&1["id"] == checkpoint["id"]))

    boundary_index =
      Enum.find_index(entries, &(&1["id"] == checkpoint["covered_through_id"]))

    is_integer(checkpoint_index) and is_integer(boundary_index) and
      checkpoint_index > boundary_index
  end

  defp raw_boundary(messages, id_index) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Message{id: id} when is_binary(id) ->
        case id_index[id] do
          %{} = entry -> if checkpoint?(entry), do: nil, else: id
          _ -> nil
        end

      _ ->
        nil
    end)
    |> case do
      nil -> {:error, :missing_boundary}
      id -> {:ok, id}
    end
  end

  defp source_entries(entries, first_id, boundary_id)
       when is_binary(first_id) and is_binary(boundary_id) do
    raw = Enum.reject(entries, &checkpoint?/1)
    first_index = Enum.find_index(raw, &(&1["id"] == first_id))
    boundary_index = Enum.find_index(raw, &(&1["id"] == boundary_id))

    if is_integer(first_index) and is_integer(boundary_index) and
         first_index <= boundary_index do
      {:ok, Enum.slice(raw, first_index..boundary_index)}
    else
      {:error, :invalid_boundary}
    end
  end

  defp source_entries(_entries, _first_id, _boundary_id), do: {:error, :invalid_boundary}
end
