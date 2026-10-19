defmodule HandbeanWeb.WorkspaceHelper do
  @moduledoc """
  Pure template helper functions extracted from `HandbeanWeb.WorkspaceLive`.

  These functions are value mappers with no dependency on LiveView socket
  or assigns — they can be tested and used independently.
  """

  use Gettext, backend: Handbean.Gettext

  alias Handbean.TranscriptEntry
  alias HandbeanWeb.ChangeHelper

  @doc """
  Returns the CSS class for the status indicator dot.
  """
  def status_dot_class(:idle), do: "idle"
  def status_dot_class(:running), do: "running"
  def status_dot_class(:error), do: "error"
  def status_dot_class(:max_turns), do: "error"
  def status_dot_class(:stalled), do: "error"
  def status_dot_class(:budget_exceeded), do: "error"
  def status_dot_class(:halted), do: "error"
  def status_dot_class(:completed), do: "completed"
  def status_dot_class(_), do: "idle"

  @doc """
  Returns the Unicode icon for a tool execution status.
  """
  def tool_status_icon(:running), do: "◌"
  def tool_status_icon(:done), do: "✓"
  def tool_status_icon(:error), do: "✗"
  def tool_status_icon("running"), do: "◌"
  def tool_status_icon("done"), do: "✓"
  def tool_status_icon("error"), do: "✗"
  def tool_status_icon(_), do: "·"

  @doc """
  Returns the CSS text color class for a tool execution status.
  """
  def tool_status_class(:running), do: "text-warning"
  def tool_status_class(:done), do: "text-success"
  def tool_status_class(:error), do: "text-error"
  def tool_status_class("running"), do: "text-warning"
  def tool_status_class("done"), do: "text-success"
  def tool_status_class("error"), do: "text-error"
  def tool_status_class(_), do: "text-tertiary"

  @doc """
  Returns the CSS border class for a tool execution status.
  """
  def tool_border_class(:running), do: "border-l-warning"
  def tool_border_class(:done), do: "border-l-success"
  def tool_border_class(:error), do: "border-l-error"
  def tool_border_class(_), do: "border border-gray-600"

  @doc """
  Returns the human-readable label for a tool execution status.
  """
  def render_tool_status(:running), do: "running"
  def render_tool_status(:done), do: "done"
  def render_tool_status(:error), do: "error"
  def render_tool_status("running"), do: "running"
  def render_tool_status("done"), do: "done"
  def render_tool_status("error"), do: "error"
  def render_tool_status(_), do: ""

  @doc """
  Counts the number of tool entries in a timeline entry list.
  """
  def tool_entry_count(entries) when is_list(entries) do
    entries
    |> Enum.count(fn entry ->
      Map.get(entry, "content_type") == "tool" or Map.get(entry, :content_type) == "tool"
    end)
  end

  def tool_entry_count(_entries), do: 0

  @doc """
  Returns a truncated summary of the first non-empty message content in a timeline.
  """
  def timeline_summary(entries) when is_list(entries) do
    entries
    |> Enum.reject(
      &(get_in(&1, ["origin", "kind"]) == "conversation" or
          &1["content_type"] == "conversation_handoff" or
          delegation_reports(&1) != [])
    )
    |> Enum.find_value(fn entry ->
      content = Handbean.Utils.SafeMap.get_any(entry, "content", :content)
      if is_binary(content) and content != "", do: content
    end)
    |> case do
      nil -> ""
      content -> String.slice(content, 0, 80)
    end
  end

  def timeline_summary(_entries), do: ""

  @user_nav_summary_limit 36
  @background_report_marker "Background subagent report"
  @legacy_report_marker "Delegated report (requires parent review):"

  @doc """
  User turns for the conversation navigator: id, 1-based index, and a short summary.

  Assistant, tool, and system entries are omitted.
  """
  def user_message_nav_items(entries) when is_list(entries) do
    entries
    |> Enum.filter(&user_msg_entry?/1)
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {entry, index} ->
      case Handbean.Utils.SafeMap.get_any(entry, "id", :id) do
        id when is_binary(id) and id != "" ->
          content = Handbean.Utils.SafeMap.get_any(entry, "content", :content)

          attachments =
            Handbean.Utils.SafeMap.get_any(entry, "attachments", :attachments) || []

          [
            %{
              id: id,
              index: index,
              summary: user_message_nav_summary(content, attachments),
              age: user_message_nav_age(entry)
            }
          ]

        _ ->
          []
      end
    end)
  end

  def user_message_nav_items(_entries), do: []

  defp user_msg_entry?(entry) when is_map(entry) do
    (Map.get(entry, "content_type") == "user_msg" or Map.get(entry, :content_type) == "user_msg") and
      get_in(entry, ["origin", "kind"]) != "conversation" and delegation_reports(entry) == []
  end

  defp user_msg_entry?(_entry), do: false

  @doc """
  Projects a synthetic delegation transcript entry into report cards.

  The original entry remains untouched for persistence and model context. This
  projection deliberately exposes only report metadata and the JSON `report`
  field, never the synthetic wrapper text or its full JSON payload.
  """
  def delegation_reports(entry) when is_map(entry) do
    content_type = Handbean.Utils.SafeMap.get_any(entry, "content_type", :content_type)
    content = Handbean.Utils.SafeMap.get_any(entry, "content", :content)

    if content_type == "user_msg" and delegation_report_entry?(entry, content) do
      content
      |> report_chunks()
      |> Enum.with_index()
      |> Enum.map(fn {chunk, index} -> project_delegation_report(chunk, index) end)
    else
      []
    end
  end

  def delegation_reports(_entry), do: []

  defp delegation_report_entry?(entry, content) do
    source = Handbean.Utils.SafeMap.get_any(entry, "source", :source)
    channel = Handbean.Utils.SafeMap.get_any(entry, "channel", :channel)

    (source in [:delegation, "delegation"] and channel in [:internal, "internal"]) or
      (is_binary(content) and
         (String.starts_with?(content, @background_report_marker) or
            String.starts_with?(content, @legacy_report_marker)))
  end

  defp report_chunks(content) when is_binary(content) do
    chunks =
      Regex.split(~r/\n\n(?=Background subagent report)/, content, trim: true)

    if chunks == [], do: [content], else: chunks
  end

  defp report_chunks(_content), do: [""]

  defp project_delegation_report(chunk, index) do
    header_child_id =
      case Regex.run(~r/child_conversation_id\s+([^\s)]+)/, chunk, capture: :all_but_first) do
        [id] -> id
        _ -> nil
      end

    data = decode_report_payload(chunk)
    report = report_text(data)
    error = report_error(data)
    child_id = display_optional(report_value(data, "child_conversation_id") || header_child_id)

    %{
      key: "#{child_id || "unknown"}-#{index}",
      subagent_type: display_value(report_value(data, "subagent_type"), "subagent"),
      status: display_value(report_value(data, "status"), "unknown"),
      child_conversation_id: child_id,
      child_run_id: display_optional(report_value(data, "child_run_id")),
      report: report,
      error: error,
      availability: report_availability(report, error),
      usage: report_usage(data)
    }
  end

  defp decode_report_payload(chunk) do
    json =
      case String.split(chunk, "\n", parts: 2) do
        [_header, payload] -> String.trim(payload)
        [payload] -> String.trim(payload)
      end

    case Handbean.JSON.decode(json) do
      {:ok, data} when is_map(data) -> data
      _ -> %{}
    end
  end

  defp report_text(data) do
    case report_value(data, "report") do
      report when is_binary(report) -> String.trim(report)
      _ -> ""
    end
  end

  defp report_error(data) do
    case report_value(data, "error") do
      error when is_binary(error) -> String.trim(error)
      _ -> ""
    end
  end

  defp report_availability(report, _error) when report != "", do: :available
  defp report_availability(_report, error) when error != "", do: :failed
  defp report_availability(_report, _error), do: :unavailable

  defp report_usage(data) do
    usage = report_value(data, "usage")

    %{
      input_tokens: usage_token(usage, "input_tokens"),
      output_tokens: usage_token(usage, "output_tokens"),
      cache_read_tokens: usage_token(usage, "cache_read_input_tokens"),
      cache_write_tokens: usage_token(usage, "cache_creation_input_tokens")
    }
  end

  defp usage_token(usage, key) when is_map(usage) do
    case report_value(usage, key) do
      value when is_integer(value) and value >= 0 ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} when parsed >= 0 -> parsed
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp usage_token(_usage, _key), do: nil

  defp report_value(map, key) when is_map(map) do
    Handbean.Utils.SafeMap.get(map, key)
  end

  defp display_value(value, fallback) when is_binary(value) do
    if String.trim(value) == "", do: fallback, else: value
  end

  defp display_value(value, _fallback) when is_atom(value) and not is_nil(value),
    do: Atom.to_string(value)

  defp display_value(_value, fallback), do: fallback

  defp display_optional(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp display_optional(value) when is_atom(value) and not is_nil(value),
    do: Atom.to_string(value)

  defp display_optional(_value), do: nil

  defp user_message_nav_age(entry) do
    timestamp = Handbean.Utils.SafeMap.get_any(entry, "created_at", :created_at)

    case timestamp && DateTime.from_iso8601(timestamp) do
      {:ok, dt, _} ->
        diff = DateTime.diff(DateTime.utc_now(), dt, :second)

        cond do
          diff < 60 -> "now"
          diff < 3_600 -> "#{div(diff, 60)}m ago"
          diff < 86_400 -> "#{div(diff, 3_600)}h ago"
          diff < 86_400 * 30 -> "#{div(diff, 86_400)}d ago"
          true -> "#{div(diff, 86_400 * 30)}mo ago"
        end

      _ ->
        ""
    end
  end

  defp user_message_nav_summary(content, attachments) when is_binary(content) do
    trimmed = String.trim(content)

    cond do
      trimmed != "" -> truncate_user_nav_summary(trimmed)
      has_attachments?(attachments) -> gettext("（图片）")
      true -> gettext("（空消息）")
    end
  end

  defp user_message_nav_summary(_content, attachments) do
    if has_attachments?(attachments), do: gettext("（图片）"), else: gettext("（空消息）")
  end

  defp has_attachments?(attachments) when is_list(attachments), do: attachments != []
  defp has_attachments?(_attachments), do: false

  defp truncate_user_nav_summary(text) do
    if String.length(text) > @user_nav_summary_limit do
      String.slice(text, 0, @user_nav_summary_limit) <> "…"
    else
      text
    end
  end

  @doc """
  User-facing install card when a browser tool result is missing-binary.
  """
  def browser_install_prompt(entry) do
    Handbean.Browser.InstallPrompt.from_entry(entry)
  end

  @doc "Conversation card for a registered preview_id."
  def preview_card(entry) when is_map(entry) do
    details = Handbean.Utils.SafeMap.get_any(entry, "details", :details) || %{}
    preview_id = map_get(details, "preview_id") || map_get(entry, "preview_id")

    if is_binary(preview_id) do
      %{
        preview_id: preview_id,
        title: map_get(details, "title") || "Preview",
        conversation_id: map_get(details, "conversation_id"),
        preview_path: map_get(details, "preview_path") || "/preview/#{preview_id}"
      }
    end
  end

  def preview_card(_), do: nil

  @doc "Explicit takeover prompt from a browser tool result. Never auto-covers chat."
  def browser_takeover_prompt(entry) when is_map(entry) do
    details = Handbean.Utils.SafeMap.get_any(entry, "details", :details) || %{}

    if map_get(details, "needs_user") in [true, "true"] do
      %{
        session_id: map_get(details, "session_id"),
        reason: map_get(details, "reason") || "user takeover required"
      }
    end
  end

  def browser_takeover_prompt(_), do: nil

  defp map_get(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, known_detail_atom(key))
  end

  defp map_get(_, _), do: nil

  defp known_detail_atom("preview_id"), do: :preview_id
  defp known_detail_atom("title"), do: :title
  defp known_detail_atom("conversation_id"), do: :conversation_id
  defp known_detail_atom("preview_path"), do: :preview_path
  defp known_detail_atom("needs_user"), do: :needs_user
  defp known_detail_atom("session_id"), do: :session_id
  defp known_detail_atom("reason"), do: :reason
  defp known_detail_atom(_), do: nil

  @search_tools ~w(
    grep search file_search code_search glob glob_file_search find rg ripgrep
    semantic_search codebase_search
  )
  @file_tools ~w(read read_file write edit apply_patch list_dir)
  @command_tools ~w(bash shell command)

  @doc """
  Classifies a tool name into `:file`, `:search`, `:command`, or `:other`.
  """
  def tool_work_kind(name) do
    normalized =
      name
      |> to_string()
      |> String.downcase()
      |> String.replace_prefix("ext__", "")

    cond do
      normalized in @search_tools -> :search
      normalized in @file_tools -> :file
      normalized in @command_tools -> :command
      String.contains?(normalized, "search") -> :search
      String.contains?(normalized, "read") -> :file
      String.contains?(normalized, "write") -> :file
      String.contains?(normalized, "edit") -> :file
      String.contains?(normalized, "bash") or String.contains?(normalized, "shell") -> :command
      true -> :other
    end
  end

  @doc """
  Counts completed-work buckets for a list of tool entries.
  """
  def tool_work_counts(tools) when is_list(tools) do
    Enum.reduce(tools, %{files: 0, searches: 0, commands: 0, others: 0}, fn tool, acc ->
      case tool_work_kind(tool_name(tool)) do
        :file -> %{acc | files: acc.files + 1}
        :search -> %{acc | searches: acc.searches + 1}
        :command -> %{acc | commands: acc.commands + 1}
        :other -> %{acc | others: acc.others + 1}
      end
    end)
  end

  def tool_work_counts(_), do: %{files: 0, searches: 0, commands: 0, others: 0}

  @doc """
  Collapsed summary separating edits from exploration. Edited paths are counted
  once; line totals sum the recorded diffs shown by individual file cards.
  """
  def tool_work_summary(tools) when is_list(tools) and tools != [] do
    {advisors, tools} =
      Enum.split_with(tools, &(normalized_tool_name(tool_name(&1)) == "advisor"))

    {edits, other_tools} = Enum.split_with(tools, &(tool_work_role(tool_name(&1)) == :edit))
    advisor_summary = if advisors == [], do: "", else: gettext("Called advisor model")

    [edited_work_summary(edits), explored_work_summary(other_tools), advisor_summary]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(", ")
  end

  def tool_work_summary(_), do: ""

  defp explored_work_summary([]), do: ""

  defp explored_work_summary(tools) do
    counts = tool_work_counts(tools)
    details = format_tool_work_details(counts)

    cond do
      counts.files + counts.searches > 0 ->
        gettext("Explored %{details}", details: details)

      counts.commands > 0 and counts.others == 0 ->
        gettext("Ran %{details}", details: details)

      true ->
        gettext("Used %{details}", details: details)
    end
  end

  # Count recorded changes just as the individual file cards do. Failed edits
  # are actions, not changed files; repeated edits count the path only once.
  defp edited_work_summary(edits) do
    {successful, failed} =
      Enum.split_with(edits, &(TranscriptEntry.tool_status(&1) in [nil, "", :done, "done"]))

    changes = Enum.map(successful, &ChangeHelper.change_from_entry/1)

    files =
      successful
      |> Enum.zip(changes)
      |> Enum.with_index()
      |> Enum.map(fn {{entry, change}, index} ->
        change["file_path"] || input_string(TranscriptEntry.input(entry), "file_path") ||
          input_string(TranscriptEntry.input(entry), "path") || {:unknown, index}
      end)
      |> Enum.uniq()
      |> length()

    lines = Enum.flat_map(changes, &(&1["diff_lines"] || []))
    %{added: added, removed: removed} = HandbeanWeb.FileChangeCard.line_counts(lines)

    summary =
      if files > 0 do
        label = ngettext("Edited %{count} file", "Edited %{count} files", files)
        if added + removed > 0, do: "#{label} (+#{added} -#{removed})", else: label
      else
        ""
      end

    failed_summary =
      if failed == [] do
        ""
      else
        details = ngettext("%{count} action", "%{count} actions", length(failed))
        gettext("Used %{details}", details: details)
      end

    [summary, failed_summary]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(", ")
  end

  @doc """
  One expanded activity line: verb plus the argument a person would scan.

  Reads and searches sit one step further right than edits and commands when
  a group contains both, matching the nested "Explored" list.
  """
  def tool_work_line(entry) when is_map(entry) do
    name = normalized_tool_name(tool_name(entry))
    input = TranscriptEntry.input(entry)

    %{
      verb: work_verb(name),
      target: work_target(name, input, entry)
    }
  end

  def tool_work_line(_), do: %{verb: "tool", target: ""}

  @doc """
  `:explore` for reads and searches, `:edit` for writes, `:command` for shell.
  """
  def tool_work_role(name) do
    normalized = normalized_tool_name(name)

    cond do
      edit_tool?(normalized) -> :edit
      command_tool?(normalized) -> :command
      tool_work_kind(normalized) in [:search, :file] -> :explore
      true -> :other
    end
  end

  @doc """
  Annotates consecutive tool streaks with collapse metadata.

  Completed groups are collapsed unless `expanded_ids` contains the group id
  (the first tool entry id in that streak). `trailing_open?: true` keeps the
  final streak stable while a run is still appending tools.
  """
  def apply_tool_work_collapse(entries, expanded_ids \\ MapSet.new(), opts \\ [])

  def apply_tool_work_collapse(entries, expanded_ids, opts) when is_list(entries) do
    expanded_ids = MapSet.new(expanded_ids, &to_string/1)
    trailing_open? = Keyword.get(opts, :trailing_open?, false)

    chunks =
      entries
      |> Enum.with_index()
      |> Enum.chunk_by(fn {entry, _idx} -> tool_entry?(entry) end)

    trailing_chunk_index = length(chunks) - 1

    updates =
      chunks
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {[], _chunk_index} ->
          []

        {[{entry, _idx} | _rest] = chunk, chunk_index} ->
          if tool_entry?(entry) do
            open? = trailing_open? and chunk_index == trailing_chunk_index
            annotate_tool_work_chunk(chunk, expanded_ids, open?)
          else
            []
          end
      end)
      |> Map.new()

    entries
    |> Enum.with_index()
    |> Enum.map(fn {entry, idx} ->
      case Map.fetch(updates, idx) do
        {:ok, updated} ->
          updated

        :error ->
          entry
          |> Map.delete("work_group_id")
          |> Map.delete("work_group_first")
          |> Map.delete("work_group_complete")
          |> Map.delete("work_collapsed")
          |> Map.delete("work_summary")
      end
    end)
  end

  def apply_tool_work_collapse(entries, _expanded_ids, _opts), do: entries

  defp annotate_tool_work_chunk(chunk, expanded_ids, open?) do
    tools = Enum.map(chunk, &elem(&1, 0))
    first = hd(tools)
    group_id = entry_id(first)
    completed? = not open? and Enum.all?(tools, &tool_terminal?/1)
    collapsed? = completed? and group_id != "" and not MapSet.member?(expanded_ids, group_id)
    summary = if open?, do: nil, else: tool_work_summary(tools)
    roles = Enum.map(tools, &tool_work_role(tool_name(&1)))
    nested_explore? = not open? and :explore in roles and Enum.any?(roles, &(&1 != :explore))

    Enum.map(chunk, fn {entry, idx} ->
      role = tool_work_role(tool_name(entry))
      line = tool_work_line(entry)
      indent = if nested_explore? and role == :explore, do: 2, else: 1

      {idx,
       entry
       |> Map.put("work_group_id", group_id)
       |> Map.put("work_group_first", entry_id(entry) == group_id)
       |> Map.put("work_group_complete", completed?)
       |> Map.put("work_collapsed", collapsed?)
       |> Map.put("work_summary", summary)
       |> Map.put("work_indent", indent)
       |> Map.put("work_verb", line.verb)
       |> Map.put("work_target", line.target)}
    end)
  end

  defp tool_entry?(entry) when is_map(entry) do
    Map.get(entry, "content_type") == "tool" or Map.get(entry, :content_type) == "tool"
  end

  defp tool_entry?(_), do: false

  defp tool_terminal?(entry) do
    status = TranscriptEntry.tool_status(entry)

    status in [nil, "", :done, :error, "done", "error"]
  end

  defp normalized_tool_name(name) do
    name
    |> to_string()
    |> String.downcase()
    |> String.replace_prefix("ext__", "")
  end

  defp edit_tool?(name) do
    name in ~w(write edit apply_patch) or String.contains?(name, "write") or
      String.contains?(name, "edit")
  end

  defp command_tool?(name) do
    name in @command_tools or String.contains?(name, "bash") or String.contains?(name, "shell")
  end

  defp work_verb(name) do
    cond do
      name in ~w(grep rg ripgrep) or String.contains?(name, "grep") ->
        "Grep"

      name in ~w(file_search glob glob_file_search) ->
        "Searched files"

      name in ~w(code_search semantic_search codebase_search) ->
        "Searched"

      name in ~w(list_dir) or String.starts_with?(name, "list") ->
        "List"

      name in ~w(read read_file) or String.contains?(name, "read") ->
        "read"

      edit_tool?(name) and String.contains?(name, "write") ->
        "Created"

      edit_tool?(name) ->
        "edit"

      command_tool?(name) ->
        "$"

      true ->
        name
    end
  end

  defp work_target(name, input, entry) do
    summary = TranscriptEntry.input_summary(entry) || ""

    cond do
      name in ~w(grep rg ripgrep) or String.contains?(name, "grep") ->
        grep_target(input, summary)

      command_tool?(name) ->
        input_string(input, "command") || summary

      edit_tool?(name) or name in ~w(read read_file) or String.contains?(name, "read") or
          String.starts_with?(name, "list") ->
        file_target(input, summary)

      true ->
        input_string(input, "query") || input_string(input, "pattern") || summary
    end
  end

  defp grep_target(input, summary) do
    path = input_string(input, "path") || input_string(input, "file_path")
    pattern = input_string(input, "pattern") || input_string(input, "query")

    cond do
      is_binary(path) and is_binary(pattern) -> path <> " \"" <> pattern <> "\""
      is_binary(pattern) -> pattern
      is_binary(path) -> path
      true -> summary
    end
  end

  defp file_target(input, summary) do
    path = input_string(input, "file_path") || input_string(input, "path")

    if is_binary(path) and path != "" do
      path <> line_span(input)
    else
      summary
    end
  end

  defp line_span(input) do
    offset = input_int(input, "offset")
    limit = input_int(input, "limit")

    cond do
      is_integer(offset) and offset > 0 and is_integer(limit) and limit > 0 ->
        " L#{offset}-#{offset + limit - 1}"

      is_integer(offset) and offset > 0 ->
        " L#{offset}"

      true ->
        ""
    end
  end

  defp input_string(input, key) when is_map(input) do
    case Map.get(input, key) || Map.get(input, atom_key(key)) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp input_string(_, _), do: nil

  defp input_int(input, key) when is_map(input) do
    case Map.get(input, key) || Map.get(input, atom_key(key)) do
      value when is_integer(value) -> value
      _ -> nil
    end
  end

  defp input_int(_, _), do: nil

  defp atom_key("command"), do: :command
  defp atom_key("file_path"), do: :file_path
  defp atom_key("path"), do: :path
  defp atom_key("pattern"), do: :pattern
  defp atom_key("query"), do: :query
  defp atom_key("offset"), do: :offset
  defp atom_key("limit"), do: :limit
  defp atom_key(_), do: nil

  defp tool_name(entry) when is_map(entry) do
    TranscriptEntry.tool_name(entry) || "tool"
  end

  defp tool_name(_), do: "tool"

  defp entry_id(entry) when is_map(entry) do
    case Handbean.Utils.SafeMap.get_any(entry, "id", :id) do
      id when is_binary(id) -> id
      id when is_atom(id) -> Atom.to_string(id)
      id -> to_string(id)
    end
  end

  defp entry_id(_), do: ""

  defp format_tool_work_details(counts) do
    []
    |> maybe_count_part(counts.files, "%{count} file", "%{count} files")
    |> maybe_count_part(counts.searches, "%{count} search", "%{count} searches")
    |> maybe_count_part(counts.commands, "%{count} command", "%{count} commands")
    |> maybe_count_part(counts.others, "%{count} action", "%{count} actions")
    |> Enum.join(", ")
  end

  defp maybe_count_part(parts, count, _one, _other) when count <= 0, do: parts

  defp maybe_count_part(parts, count, one, other) do
    parts ++ [Gettext.ngettext(Handbean.Gettext, one, other, count)]
  end

  @doc """
  Formats a duration in milliseconds to a human-readable string.
  """
  def format_duration(nil), do: nil
  def format_duration(ms) when ms < 1000, do: "#{ms}ms"
  def format_duration(ms), do: "#{Float.round(ms / 1000, 1)}s"

  @doc """
  Formats a byte count to a human-readable string (B / KB / MB).
  """
  def format_bytes(nil), do: "0 B"
  def format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  def format_bytes(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  def format_bytes(bytes), do: "#{Float.round(bytes / 1_048_576, 2)} MB"

  @doc """
  Formats tokens with decimal K/M units and at most one decimal place.
  Rounds half up and promotes rounded 1000K to 1M.

  ## Examples

      iex> HandbeanWeb.WorkspaceHelper.format_tokens(5481)
      "5.5K"

      iex> HandbeanWeb.WorkspaceHelper.format_tokens(999_950)
      "1M"
  """
  def format_tokens(:unknown), do: "unknown"
  def format_tokens(tokens) when tokens < 1000, do: Integer.to_string(tokens)
  def format_tokens(tokens) when tokens < 999_950, do: compact_tokens(tokens, 1000, "K")
  def format_tokens(tokens), do: compact_tokens(tokens, 1_000_000, "M")

  defp compact_tokens(tokens, unit, suffix) do
    value = (tokens / unit) |> Float.round(1) |> :erlang.float_to_binary(decimals: 1)
    String.trim_trailing(value, ".0") <> suffix
  end

  @doc """
  Formats the run's token-weighted cache read rate, not a mean of request rates.
  No reported cache activity (or no input) is shown as unavailable.

  ## Examples

      iex> HandbeanWeb.WorkspaceHelper.format_cache_hit_rate(%{total_input_tokens: 1000, cache_read_tokens: 800, cache_write_tokens: 0})
      "80.0%"
  """
  def format_cache_hit_rate(%{
        total_input_tokens: total,
        cache_read_tokens: read,
        cache_write_tokens: write
      })
      when total > 0 and (read > 0 or write > 0) do
    :erlang.float_to_binary(100 * read / total, decimals: 1) <> "%"
  end

  def format_cache_hit_rate(_), do: "—"

  @doc """
  Returns the diff line prefix character for a given diff type.
  """
  def diff_prefix("ins"), do: "+"
  def diff_prefix("del"), do: "-"
  def diff_prefix("skip"), do: "⋯"
  def diff_prefix(_), do: " "

  @doc """
  Reads the value for a key from a map, trying both atom and string forms.
  Returns `default` when the key is not found.
  """
  def file_value(file, key, default) do
    key_str = if is_atom(key), do: Atom.to_string(key), else: key
    Map.get(file, key_str, Map.get(file, key, default))
  end

  @doc """
  Counts the number of archived conversations in a Phoenix LiveView stream entries list.
  """
  def archived_stream_count(stream_entries) when is_list(stream_entries) do
    Enum.count(stream_entries, fn {_, conv} -> conv.archived end)
  end

  def archived_stream_count(_), do: 0

  @doc """
  Renders a file preview as HTML-safe text.

  Returns "" for nil paths, escaped content for workspace files,
  and a safe message for files that cannot be rendered as UTF-8 text.
  """
  def render_file_preview(path, workspace_root \\ Handbean.Workspace.root()) do
    if is_nil(path) do
      ""
    else
      case Handbean.Workspace.resolve(path, workspace_root) do
        {:ok, _} ->
          case File.read(path) do
            {:ok, content} when is_binary(content) ->
              if previewable_text?(content) do
                content
                |> String.slice(0, 10_000)
                |> String.replace("&", "&amp;")
                |> String.replace("<", "&lt;")
                |> String.replace(">", "&gt;")
              else
                "[Binary file preview unavailable]"
              end

            {:error, _} ->
              "[Error reading file]"
          end

        {:error, reason} ->
          "[Access denied: #{reason}]"
      end
    end
  end

  @doc false
  def file_preview_error(nil, _workspace_root), do: nil

  def file_preview_error(path, workspace_root) do
    case Handbean.Workspace.resolve(path, workspace_root) do
      {:ok, _} ->
        case File.read(path) do
          {:ok, content} ->
            if previewable_text?(content),
              do: nil,
              else: "Binary files cannot be previewed as text"

          {:error, reason} ->
            reason
        end

      {:error, reason} ->
        reason
    end
  end

  defp previewable_text?(content) do
    String.valid?(content) and :binary.match(content, <<0>>) == :nomatch
  end
end
