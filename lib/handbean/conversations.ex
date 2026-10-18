defmodule Handbean.Conversations do
  @moduledoc """
  Authorized projections of workspace conversations. No runtime is owned here.

  Cursors expire after one hour and bind the caller, query and complete projected
  snapshot. Any append, edit or deletion invalidates pagination: restart explicitly.
  Character offsets count Unicode codepoints, including within a single message.
  Each page has at most 16,000 codepoints and 50 message fragments.
  """
  alias Handbean.{ConversationStore, ConversationTranscriptStore}

  def identity(%{conversation_id: id, workspace_id: workspace}) when is_binary(workspace) do
    with {:ok, meta} <- ConversationStore.get_metadata(id),
         true <- meta["workspace_id"] == workspace and visible?(meta) and not free_chat?(meta) do
      {:ok, meta}
    else
      _ -> {:error, :unauthorized}
    end
  end

  def identity(_), do: {:error, :unauthorized}

  def authorize(context, id) do
    with {:ok, source} <- identity(context),
         {:ok, target} <- ConversationStore.get_metadata(id),
         true <-
           target["workspace_id"] == source["workspace_id"] and visible?(target) and
             not free_chat?(target) do
      {:ok, target}
    else
      _ -> {:error, :not_accessible}
    end
  end

  def visible?(meta), do: meta["visibility"] not in ["internal", "task"]

  defp free_chat?(meta), do: meta["scope"] == "free"

  def list(input, context) do
    with {:ok, source} <- identity(context),
         :ok <- validate(input, ~w(archived updated_after limit cursor)),
         {:ok, archived} <- archived_filter(input),
         {:ok, after_time} <- text(input, "updated_after", "", 40),
         {:ok, after_time} <- timestamp(after_time),
         {:ok, limit} <- integer(input, "limit", 10, 1, 20) do
      discover(source, context, input, "list", nil, archived, after_time, limit)
    end
  end

  def find(input, context) do
    with {:ok, source} <- identity(context),
         :ok <- validate(input, ~w(query archived updated_after limit cursor)),
         {:ok, query} <- text(input, "query", nil, 200),
         query <- String.trim(query),
         true <- query != "",
         {:ok, archived} <- archived_filter(input),
         {:ok, after_time} <- text(input, "updated_after", "", 40),
         {:ok, after_time} <- timestamp(after_time),
         {:ok, limit} <- integer(input, "limit", 10, 1, 20) do
      discover(source, context, input, "find", query, archived, after_time, limit)
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  def trajectory(input, context), do: Handbean.Conversations.Trajectory.get(input, context)

  defp discover(source, context, input, kind, query, archived, after_time, limit) do
    entries =
      source["workspace_id"]
      |> ConversationStore.list_conversation_summaries()
      |> Enum.filter(fn summary ->
        archived_match?(summary["archived_at"], archived) and
          title_match?(summary["title"], query) and
          updated_since?(summary["updated_at"], after_time)
      end)
      |> Enum.map(&project_conversation_summary/1)

    binding = binding(kind, context, input, entries)

    with {:ok, offset} <- position(input["cursor"], binding) do
      next = offset + limit

      {:ok,
       %{
         conversations: Enum.slice(entries, offset, limit),
         next_cursor: cursor(next < length(entries), binding, next)
       }}
    end
  end

  defp project_conversation_summary(summary) do
    title = summary["title"] || ""

    summary
    |> Map.put("title", String.slice(title, 0, 200))
    |> Map.put("summary", String.slice(title, 0, 200))
    |> Map.put("summary_source", "title")
    |> Map.put("summary_truncated", String.length(title) > 200)
  end

  defp archived_filter(input) do
    case Map.get(input, "archived", "active") do
      value when value in ["active", "archived", "all"] -> {:ok, value}
      _ -> {:error, :invalid_input}
    end
  end

  defp archived_match?(nil, "active"), do: true
  defp archived_match?(archived_at, "archived"), do: is_binary(archived_at)
  defp archived_match?(_archived_at, "all"), do: true
  defp archived_match?(_archived_at, _filter), do: false

  defp title_match?(_title, nil), do: true

  defp title_match?(title, query) do
    String.contains?(String.downcase(title || ""), String.downcase(query))
  end

  def read(input, context) do
    with :ok <-
           validate(
             input,
             ~w(conversation start_message end_message max_chars include_tools cursor)
           ),
         true <- is_boolean(Map.get(input, "include_tools", false)),
         {:ok, _} <- authorize(context, input["conversation"]),
         {:ok, first} <- integer(input, "start_message", 0, 0, 1_000_000),
         {:ok, last} <- integer(input, "end_message", 1_000_000, first, 1_000_000),
         {:ok, max} <- integer(input, "max_chars", 8000, 1, 16_000),
         {:ok, entries} <- ConversationTranscriptStore.list(input["conversation"]) do
      include_tools? = Map.get(input, "include_tools", false)

      messages =
        entries
        |> Enum.reject(&(not include_tools? and tool_entry?(&1)))
        |> Enum.map(&project_message/1)
        |> Enum.slice(first..last)

      binding = binding("read", context, input, messages)

      with {:ok, offset} <- position(input["cursor"], binding) do
        {parts, remaining, consumed} = slice_messages(messages, offset, max)

        {:ok,
         %{
           messages: parts,
           truncated: remaining,
           next_cursor: cursor(remaining, binding, offset + consumed)
         }}
      end
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  def status(input, context) do
    with :ok <- validate(input, ["conversation"]),
         {:ok, meta} <- authorize(context, input["conversation"]) do
      runtime =
        case Handbean.Agent.Coordinator.status(meta["id"]) do
          {:ok, value} -> value
          _ -> %{}
        end

      state =
        cond do
          runtime[:status] in [
            :awaiting_approval,
            "awaiting_approval",
            :interrupted,
            "interrupted"
          ] and runtime[:running?] ->
            "awaiting_approval"

          runtime[:running?] ->
            "running"

          true ->
            "idle"
        end

      {:ok,
       %{
         id: meta["id"],
         state: state,
         current_run: runtime[:run_id],
         last_activity: meta["updated_at"],
         last_result: meta["last_run_result"],
         note: "idle means no active run, not successful completion"
       }}
    end
  end

  def project_message(entry) do
    base = %{
      "id" => entry["id"],
      "role" => entry["role"],
      "content" => project_content(entry),
      "created_at" => entry["created_at"],
      "handoff_id" => entry["handoff_id"] || get_in(entry, ["origin", "handoff_id"]),
      "consumption" => entry["consumption"]
    }

    if tool_entry?(entry) do
      base
      |> Map.put("tool_name", entry["tool_name"])
      |> Map.put("tool_status", entry["tool_status"])
    else
      base
    end
  end

  defp tool_entry?(entry),
    do: entry["role"] == "tool" or entry["content_type"] == "tool"

  defp project_content(%{"content" => content}) when is_binary(content) and content != "" do
    Handbean.Log.Redactor.redact(content)
  end

  defp project_content(entry) do
    if tool_entry?(entry) do
      tool_name = entry["tool_name"] || "tool"
      status = entry["tool_status"] || "done"
      header = "[tool #{tool_name} (#{status})]"

      input_part =
        case entry["input"] do
          input when is_map(input) and map_size(input) > 0 ->
            "input: " <> Handbean.JSON.encode!(Handbean.Log.Redactor.redact(input))

          input when is_binary(input) and input != "" ->
            "input: " <> input

          _ ->
            nil
        end

      output_part =
        cond do
          is_binary(entry["output"]) and entry["output"] != "" ->
            entry["output"]

          is_binary(entry["tool_error"]) and entry["tool_error"] != "" ->
            "error: " <> entry["tool_error"]

          true ->
            nil
        end

      [header, input_part, output_part]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")
      |> Handbean.Log.Redactor.redact()
    else
      ""
    end
  end

  def validate(input, keys) when is_map(input) do
    if Enum.all?(Map.keys(input), &(&1 in keys)), do: :ok, else: {:error, :invalid_input}
  end

  def validate(_, _), do: {:error, :invalid_input}

  def text(input, key, default, max) do
    value = Map.get(input, key, default)

    if is_binary(value) and byte_size(value) <= max * 4 and String.valid?(value) and
         String.length(value) <= max, do: {:ok, value}, else: {:error, :invalid_input}
  end

  def integer(input, key, default, min, max) do
    value = Map.get(input, key, default)

    if is_integer(value) and value >= min and value <= max,
      do: {:ok, value},
      else: {:error, :invalid_input}
  end

  defp binding(kind, context, input, snapshot) do
    :crypto.hash(
      :sha256,
      :erlang.term_to_binary(
        {kind, context.conversation_id, context.workspace_id, Map.delete(input, "cursor"),
         snapshot}
      )
    )
    |> Base.url_encode64(padding: false)
  end

  defp timestamp(""), do: {:ok, nil}

  defp timestamp(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} -> {:ok, datetime}
      _ -> {:error, :invalid_input}
    end
  end

  defp updated_since?(_, nil), do: true

  defp updated_since?(value, threshold) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} -> DateTime.compare(datetime, threshold) != :lt
      _ -> false
    end
  end

  defp updated_since?(_, _), do: false

  defp position(cursor, _binding) when cursor in [nil, ""], do: {:ok, 0}

  defp position(token, binding) when is_binary(token) and byte_size(token) <= 2048 do
    case Handbean.EndpointAdapter.verify("conversation-page", token, max_age: 3600) do
      {:ok, {^binding, offset}} when is_integer(offset) and offset >= 0 -> {:ok, offset}
      _ -> {:error, :stale_or_invalid_cursor}
    end
  end

  defp position(_, _), do: {:error, :stale_or_invalid_cursor}
  defp cursor(false, _, _), do: nil

  defp cursor(true, binding, offset),
    do: Handbean.EndpointAdapter.sign("conversation-page", {binding, offset})

  defp slice_messages(messages, offset, budget) do
    {parts, _, _left, consumed, remaining} =
      Enum.reduce(messages, {[], offset, budget, 0, false}, fn m,
                                                               {parts, skip, left, used, more} ->
        codepoints = String.to_charlist(m["content"])
        size = max(length(codepoints), 1)

        cond do
          skip >= size ->
            {parts, skip - size, left, used, more}

          left == 0 or length(parts) >= 50 ->
            {parts, skip, left, used, true}

          true ->
            count = min(size - skip, left)

            part =
              m
              |> Map.put("content", codepoints |> Enum.slice(skip, count) |> List.to_string())
              |> Map.put("offset", skip)
              |> Map.put("continued", skip + count < size)

            {[part | parts], 0, left - count, used + count, more or skip + count < size}
        end
      end)

    {Enum.reverse(parts), remaining, consumed}
  end
end
