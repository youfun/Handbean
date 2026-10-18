defmodule Handbean.Conversations.Search do
  @moduledoc false

  alias Handbean.{ConversationStore, Conversations}

  @cursor_salt "conversation-entry-search-page"
  @kinds ~w(user assistant tool system)

  def search(input, context) do
    with {:ok, source} <- Conversations.identity(context),
         :ok <-
           Conversations.validate(
             input,
             ~w(query conversation run_id updated_after kinds tool_name file_path errors_only archived limit max_chars cursor)
           ),
         {:ok, query} <- required_query(input),
         {:ok, conversation_id} <- optional_text(input, "conversation", 256),
         {:ok, run_id} <- optional_text(input, "run_id", 256),
         {:ok, updated_after, updated_after_text} <- optional_timestamp(input),
         {:ok, kinds} <- kinds(input),
         {:ok, tool_name} <- optional_text(input, "tool_name", 128),
         {:ok, file_path} <- optional_text(input, "file_path", 1_000),
         true <- is_boolean(Map.get(input, "errors_only", false)),
         {:ok, archived} <- archived(input),
         {:ok, limit} <- Conversations.integer(input, "limit", 10, 1, 20),
         {:ok, max_chars} <- Conversations.integer(input, "max_chars", 8_000, 2_000, 16_000),
         :ok <- authorize_explicit(context, conversation_id),
         filters <-
           normalized_filters(
             query,
             conversation_id,
             run_id,
             updated_after_text,
             kinds,
             tool_name,
             file_path,
             Map.get(input, "errors_only", false),
             archived,
             limit,
             max_chars
           ),
         {:ok, rows} <-
           ConversationStore.search_entries(
             source["workspace_id"],
             query: query,
             conversation_id: conversation_id,
             run_id: run_id,
             updated_after: updated_after,
             kinds: kinds,
             tool_name: tool_name,
             file_path: file_path,
             errors_only: Map.get(input, "errors_only", false),
             archived: archived
           ) do
      matches = project_matches(rows, query)
      snapshot = snapshot(matches)
      binding = binding(source, filters)

      with {:ok, offset} <- cursor_position(input["cursor"], binding, snapshot, length(matches)) do
        response(matches, offset, filters, binding, snapshot, limit, max_chars)
      end
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  defp required_query(input) do
    with {:ok, value} <- Conversations.text(input, "query", nil, 200),
         value <- String.trim(value),
         true <- value != "" do
      {:ok, value}
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  defp optional_text(input, key, max) do
    case Map.fetch(input, key) do
      :error ->
        {:ok, nil}

      {:ok, value} ->
        with {:ok, value} <- Conversations.text(%{key => value}, key, nil, max),
             true <- value != "" do
          {:ok, value}
        else
          false -> {:error, :invalid_input}
          error -> error
        end
    end
  end

  defp optional_timestamp(input) do
    case Map.fetch(input, "updated_after") do
      :error ->
        {:ok, nil, nil}

      {:ok, value} ->
        with {:ok, value} <-
               Conversations.text(%{"updated_after" => value}, "updated_after", nil, 40),
             {:ok, datetime, _offset} <- DateTime.from_iso8601(value) do
          datetime = DateTime.truncate(datetime, :microsecond)
          {:ok, datetime, DateTime.to_iso8601(datetime)}
        else
          _ -> {:error, :invalid_input}
        end
    end
  end

  defp kinds(input) do
    values = Map.get(input, "kinds", [])

    if is_list(values) and length(values) <= length(@kinds) and
         length(values) == length(Enum.uniq(values)) and Enum.all?(values, &(&1 in @kinds)) do
      {:ok, Enum.sort(values)}
    else
      {:error, :invalid_input}
    end
  end

  defp archived(input) do
    case Map.get(input, "archived", "all") do
      value when value in ["active", "archived", "all"] -> {:ok, value}
      _value -> {:error, :invalid_input}
    end
  end

  defp authorize_explicit(_context, nil), do: :ok

  defp authorize_explicit(context, conversation_id) do
    case Conversations.authorize(context, conversation_id) do
      {:ok, _metadata} -> :ok
      {:error, _reason} -> {:error, :not_accessible}
    end
  end

  defp normalized_filters(
         query,
         conversation_id,
         run_id,
         updated_after,
         kinds,
         tool_name,
         file_path,
         errors_only,
         archived,
         limit,
         max_chars
       ) do
    %{
      query: query,
      conversation: conversation_id,
      run_id: run_id,
      updated_after: updated_after,
      kinds: kinds,
      tool_name: tool_name,
      file_path: file_path,
      errors_only: errors_only,
      archived: archived,
      limit: limit,
      max_chars: max_chars
    }
  end

  defp project_matches(rows, query) do
    rows
    |> Enum.reduce([], fn row, matches ->
      values = searchable_values(row.entry)

      case Enum.find(values, &literal_contains?(&1, query)) do
        nil -> matches
        matched -> [project_match(row, matched, query) | matches]
      end
    end)
    |> Enum.reverse()
  end

  defp searchable_values(entry) do
    [
      entry["content"],
      entry["tool_name"],
      entry["input"],
      entry["output"],
      entry["tool_error"],
      entry["error"],
      entry["file_path"],
      get_in(entry, ["input", "file_path"]),
      get_in(entry, ["details", "file_path"])
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&sanitize_text/1)
  end

  defp project_match(row, matched, query) do
    entry = row.entry
    kind = record_kind(entry)

    %{
      conversation_id: bound_text(row.conversation_id, 256),
      conversation_title: row.conversation_title |> sanitize_text() |> bound_text(200),
      archived: row.archived,
      entry_id: entry["id"] |> sanitize_text() |> bound_text(256),
      sequence: entry["sequence"],
      revision: entry["revision"],
      run_id: bound_optional_text(entry["run_id"], 256),
      turn: entry["turn_number"],
      kind: kind,
      status: record_status(entry, kind),
      tool_name: bound_optional_value(entry["tool_name"], 128),
      file_path: entry |> file_path() |> bound_optional_value(1_000),
      created_at: entry["created_at"],
      updated_at: entry["updated_at"],
      snippet: snippet(matched, query)
    }
    |> drop_nil_values()
  end

  defp record_kind(entry) do
    cond do
      entry["role"] == "tool" or entry["content_type"] == "tool" -> "tool"
      entry["role"] == "user" -> "user"
      entry["role"] == "assistant" -> "assistant"
      true -> "system"
    end
  end

  defp record_status(entry, "tool"), do: normalize_status(entry["tool_status"] || entry["status"])
  defp record_status(entry, _kind), do: normalize_status(entry["status"] || "complete")

  defp normalize_status(status) when status in ["done", "completed", "complete", "succeeded"],
    do: "complete"

  defp normalize_status(status) when status in ["failed", "error"], do: "error"
  defp normalize_status(status) when status in ["streaming", "running"], do: "running"
  defp normalize_status(status) when is_binary(status), do: status
  defp normalize_status(_status), do: "unknown"

  defp file_path(entry) do
    entry["file_path"] || get_in(entry, ["input", "file_path"]) ||
      get_in(entry, ["details", "file_path"])
  end

  defp sanitize_text(value) do
    value = value |> Handbean.Log.Redactor.redact() |> Handbean.JsonSafe.normalize()
    if is_binary(value), do: value, else: Handbean.JSON.encode!(value)
  end

  defp bound_optional_value(nil, _max), do: nil
  defp bound_optional_value(value, max), do: value |> sanitize_text() |> bound_text(max)
  defp bound_optional_text(nil, _max), do: nil
  defp bound_optional_text(value, max), do: value |> sanitize_text() |> bound_text(max)

  defp literal_contains?(value, query) do
    String.contains?(String.downcase(value), String.downcase(query))
  end

  defp snippet(value, query) do
    downcased = String.downcase(value)
    needle = String.downcase(query)

    start =
      case :binary.match(downcased, needle) do
        {byte_offset, _length} -> max(original_codepoint_offset(value, byte_offset) - 100, 0)
        :nomatch -> 0
      end

    value
    |> String.slice(start, 300)
    |> bound_text(300)
  end

  defp original_codepoint_offset(value, folded_byte_offset) do
    value
    |> String.codepoints()
    |> Enum.reduce_while({0, 0}, fn codepoint, {index, folded_bytes} ->
      next_bytes = folded_bytes + byte_size(String.downcase(codepoint))

      if next_bytes <= folded_byte_offset do
        {:cont, {index + 1, next_bytes}}
      else
        {:halt, {index, folded_bytes}}
      end
    end)
    |> elem(0)
  end

  defp response(matches, offset, filters, binding, snapshot, limit, max_chars) do
    remaining = Enum.drop(matches, offset)
    base = base_response(filters)
    budget = max(max_chars - encoded_size(base) - 700, 0)
    page = take_matches(remaining, limit, budget)

    {:ok,
     fit_response(
       base,
       page,
       offset,
       length(matches),
       binding,
       snapshot,
       max_chars
     )}
  end

  defp base_response(filters) do
    %{
      schema_version: 1,
      generated_at:
        DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601(),
      matches: [],
      truncated: false,
      next_cursor: nil,
      filters: public_filters(filters)
    }
  end

  defp public_filters(filters) do
    filters
    |> Map.drop([:query, :limit, :max_chars])
    |> Map.update(:conversation, nil, &bound_text(&1, 200))
    |> Map.update(:run_id, nil, &bound_text(&1, 200))
    |> Map.update(:tool_name, nil, &bound_text(&1, 120))
    |> Map.update(:file_path, nil, &bound_text(&1, 240))
    |> drop_nil_values()
  end

  defp take_matches(matches, limit, budget) do
    matches
    |> Enum.take(limit)
    |> Enum.reduce_while({[], 2}, fn match, {kept, used} ->
      size = encoded_size(match) + if(kept == [], do: 0, else: 1)

      cond do
        used + size <= budget ->
          {:cont, {[match | kept], used + size}}

        kept == [] and budget > 300 ->
          bounded = minimal_match(match, budget)
          {:halt, {[bounded], encoded_size(bounded) + 2}}

        true ->
          {:halt, {kept, used}}
      end
    end)
    |> then(fn {kept, _used} -> Enum.reverse(kept) end)
  end

  defp minimal_match(match, budget) do
    match
    |> Map.update(:conversation_title, "", &bound_text(&1, 80))
    |> Map.update(:file_path, nil, &bound_text(&1, 200))
    |> Map.update(:snippet, "", &bound_text(&1, max(min(div(budget, 4), 160), 20)))
    |> drop_nil_values()
  end

  defp fit_response(base, page, offset, total, binding, snapshot, max_chars) do
    consumed = length(page)
    more? = offset + consumed < total

    next_cursor =
      if more? and consumed > 0 do
        Handbean.EndpointAdapter.sign(@cursor_salt, {binding, snapshot, offset + consumed})
      end

    response =
      base
      |> Map.put(:matches, page)
      |> Map.put(:truncated, more?)
      |> Map.put(:next_cursor, next_cursor)

    cond do
      encoded_size(response) <= max_chars or page == [] ->
        response

      length(page) > 1 ->
        fit_response(
          base,
          Enum.drop(page, -1),
          offset,
          total,
          binding,
          snapshot,
          max_chars
        )

      true ->
        compact = page |> hd() |> metadata_only_match()
        compact_response = Map.put(response, :matches, [compact])

        if encoded_size(compact_response) <= max_chars do
          compact_response
        else
          response |> Map.put(:matches, []) |> Map.put(:next_cursor, nil)
        end
    end
  end

  defp metadata_only_match(match) do
    match
    |> Map.take([
      :conversation_id,
      :entry_id,
      :sequence,
      :revision,
      :run_id,
      :turn,
      :kind,
      :status,
      :tool_name,
      :created_at,
      :updated_at
    ])
    |> Map.put(:detail_truncated, true)
    |> drop_nil_values()
  end

  defp binding(source, filters) do
    digest({"entry-search", source["id"], source["workspace_id"], filters})
  end

  defp snapshot(matches), do: digest(matches)

  defp digest(value) do
    :crypto.hash(:sha256, :erlang.term_to_binary(value))
    |> Base.url_encode64(padding: false)
  end

  defp cursor_position(cursor, _binding, _snapshot, _length) when cursor in [nil, ""],
    do: {:ok, 0}

  defp cursor_position(cursor, binding, snapshot, length)
       when is_binary(cursor) and byte_size(cursor) <= 4_096 do
    case Handbean.EndpointAdapter.verify(@cursor_salt, cursor, max_age: 3_600) do
      {:ok, {^binding, ^snapshot, offset}}
      when is_integer(offset) and offset > 0 and offset < length ->
        {:ok, offset}

      _other ->
        {:error, :stale_or_invalid_cursor}
    end
  end

  defp cursor_position(_cursor, _binding, _snapshot, _length),
    do: {:error, :stale_or_invalid_cursor}

  defp bound_text(value, max) when is_binary(value), do: String.slice(value, 0, max)
  defp bound_text(value, _max), do: value
  defp drop_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
  defp encoded_size(value), do: value |> Handbean.JSON.encode!() |> String.length()
end
