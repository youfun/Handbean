defmodule Handbean.ConversationStore.EntrySearch do
  @moduledoc false

  import Ecto.Query

  alias Handbean.Repo
  alias Handbean.Storage.{Conversation, ConversationEntry}

  @max_candidates 5_000

  def search(workspace_id, opts) when is_binary(workspace_id) and is_list(opts) do
    query = Keyword.fetch!(opts, :query)

    ConversationEntry
    |> join(:inner, [entry], conversation in Conversation,
      on: conversation.id == entry.conversation_id
    )
    |> where(
      [entry, conversation],
      conversation.status == "active" and conversation.scope == "workspace" and
        conversation.workspace_id == ^workspace_id and conversation.visibility == "user"
    )
    |> public_entries()
    |> exclude_current_execution(
      Keyword.get(opts, :exclude_conversation_id),
      Keyword.get(opts, :exclude_run_id)
    )
    |> archive_filter(Keyword.fetch!(opts, :archived))
    |> optional_equal(:conversation_id, Keyword.get(opts, :conversation_id))
    |> optional_equal(:run_id, Keyword.get(opts, :run_id))
    |> kind_filter(Keyword.get(opts, :kinds, []))
    |> tool_name_filter(Keyword.get(opts, :tool_name))
    |> file_path_filter(Keyword.get(opts, :file_path))
    |> errors_filter(Keyword.get(opts, :errors_only, false))
    |> updated_after_filter(Keyword.get(opts, :updated_after))
    |> literal_filter(query)
    |> order_by(
      [entry, conversation],
      desc: entry.updated_at,
      desc: entry.created_at,
      desc: conversation.id,
      desc: entry.sequence,
      desc: entry.entry_id,
      desc: entry.id
    )
    |> limit(^(@max_candidates + 1))
    |> select([entry, conversation], {entry, conversation})
    |> Repo.all()
    |> case do
      rows when length(rows) <= @max_candidates -> {:ok, Enum.map(rows, &row_map/1)}
      _rows -> {:error, :search_too_broad}
    end
  end

  def search(_workspace_id, _opts), do: {:error, :invalid_input}

  defp public_entries(query) do
    where(
      query,
      [entry, _conversation],
      (is_nil(entry.role) or entry.role != "internal") and
        (is_nil(entry.message_type) or entry.message_type != "internal") and
        (is_nil(entry.content_type) or
           entry.content_type not in ["memory_reflection", "model_compaction"]) and
        (is_nil(entry.status) or entry.status not in ["streaming", "running"]) and
        (is_nil(entry.tool_status) or entry.tool_status not in ["streaming", "running"])
    )
  end

  defp exclude_current_execution(query, conversation_id, run_id)
       when is_binary(conversation_id) and conversation_id != "" and is_binary(run_id) and
              run_id != "" do
    where(
      query,
      [entry, _conversation],
      entry.conversation_id != ^conversation_id or
        (not is_nil(entry.run_id) and entry.run_id != ^run_id)
    )
  end

  defp exclude_current_execution(query, conversation_id, _run_id)
       when is_binary(conversation_id) and conversation_id != "" do
    where(query, [entry, _conversation], entry.conversation_id != ^conversation_id)
  end

  defp exclude_current_execution(query, _conversation_id, _run_id), do: query

  defp archive_filter(query, "active"),
    do: where(query, [_entry, conversation], is_nil(conversation.archived_at))

  defp archive_filter(query, "archived"),
    do: where(query, [_entry, conversation], not is_nil(conversation.archived_at))

  defp archive_filter(query, "all"), do: query

  defp optional_equal(query, _field, nil), do: query

  defp optional_equal(query, :conversation_id, value),
    do: where(query, [entry, _conversation], entry.conversation_id == ^value)

  defp optional_equal(query, :run_id, value),
    do: where(query, [entry, _conversation], entry.run_id == ^value)

  defp kind_filter(query, []), do: query

  defp kind_filter(query, kinds) do
    condition =
      Enum.reduce(kinds, dynamic(false), fn
        "tool", acc ->
          dynamic(
            [entry, _conversation],
            ^acc or entry.role == "tool" or entry.content_type == "tool"
          )

        "user", acc ->
          dynamic(
            [entry, _conversation],
            ^acc or
              (entry.role == "user" and
                 (is_nil(entry.content_type) or entry.content_type != "tool"))
          )

        "assistant", acc ->
          dynamic(
            [entry, _conversation],
            ^acc or
              (entry.role == "assistant" and
                 (is_nil(entry.content_type) or entry.content_type != "tool"))
          )

        "system", acc ->
          dynamic(
            [entry, _conversation],
            ^acc or
              ((is_nil(entry.role) or entry.role not in ["user", "assistant", "tool"]) and
                 (is_nil(entry.content_type) or entry.content_type != "tool"))
          )
      end)

    where(query, ^condition)
  end

  defp tool_name_filter(query, nil), do: query

  defp tool_name_filter(query, tool_name) do
    where(
      query,
      [entry, _conversation],
      (entry.role == "tool" or entry.content_type == "tool") and
        fragment("json_extract(?, '$.tool_name') = ?", entry.payload, ^tool_name)
    )
  end

  defp file_path_filter(query, nil), do: query

  defp file_path_filter(query, file_path) do
    where(
      query,
      [entry, _conversation],
      fragment(
        "instr(lower(COALESCE(CAST(json_extract(?, '$.file_path') AS TEXT), '')), lower(?)) > 0 OR instr(lower(COALESCE(CAST(json_extract(?, '$.input.file_path') AS TEXT), '')), lower(?)) > 0 OR instr(lower(COALESCE(CAST(json_extract(?, '$.details.file_path') AS TEXT), '')), lower(?)) > 0",
        entry.payload,
        ^file_path,
        entry.payload,
        ^file_path,
        entry.payload,
        ^file_path
      )
    )
  end

  defp errors_filter(query, false), do: query

  defp errors_filter(query, true) do
    where(
      query,
      [entry, _conversation],
      entry.tool_status in ["error", "failed"] or entry.status in ["error", "failed"] or
        entry.message_type == "error" or
        fragment(
          "json_type(?, '$.tool_error') IN ('text', 'integer', 'real', 'true', 'object', 'array') AND COALESCE(CAST(json_extract(?, '$.tool_error') AS TEXT), '') NOT IN ('', '{}', '[]')",
          entry.payload,
          entry.payload
        ) or
        fragment(
          "json_type(?, '$.error') IN ('text', 'integer', 'real', 'true', 'object', 'array') AND COALESCE(CAST(json_extract(?, '$.error') AS TEXT), '') NOT IN ('', '{}', '[]')",
          entry.payload,
          entry.payload
        )
    )
  end

  defp updated_after_filter(query, nil), do: query

  defp updated_after_filter(query, updated_after),
    do: where(query, [entry, _conversation], entry.updated_at >= ^updated_after)

  defp literal_filter(query, value) do
    where(
      query,
      [entry, _conversation],
      fragment(
        "instr(lower(COALESCE(?, '')), lower(?)) > 0 OR instr(lower(COALESCE(CAST(json_extract(?, '$.tool_name') AS TEXT), '')), lower(?)) > 0 OR instr(lower(COALESCE(CAST(json_extract(?, '$.input') AS TEXT), '')), lower(?)) > 0 OR instr(lower(COALESCE(CAST(json_extract(?, '$.output') AS TEXT), '')), lower(?)) > 0 OR instr(lower(COALESCE(CAST(json_extract(?, '$.tool_error') AS TEXT), '')), lower(?)) > 0 OR instr(lower(COALESCE(CAST(json_extract(?, '$.error') AS TEXT), '')), lower(?)) > 0 OR instr(lower(COALESCE(CAST(json_extract(?, '$.file_path') AS TEXT), '')), lower(?)) > 0 OR instr(lower(COALESCE(CAST(json_extract(?, '$.input.file_path') AS TEXT), '')), lower(?)) > 0 OR instr(lower(COALESCE(CAST(json_extract(?, '$.details.file_path') AS TEXT), '')), lower(?)) > 0",
        entry.content,
        ^value,
        entry.payload,
        ^value,
        entry.payload,
        ^value,
        entry.payload,
        ^value,
        entry.payload,
        ^value,
        entry.payload,
        ^value,
        entry.payload,
        ^value,
        entry.payload,
        ^value,
        entry.payload,
        ^value
      )
    )
  end

  defp row_map({entry, conversation}) do
    %{
      entry: Handbean.ConversationTranscriptStore.ConversationStore.public_entry(entry),
      conversation_id: conversation.id,
      conversation_title: conversation.title || "",
      archived: not is_nil(conversation.archived_at)
    }
  end
end
