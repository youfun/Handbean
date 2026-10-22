defmodule HandbeanWeb.WorkspaceLive.RuntimeProjection.Timeline do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [stream_insert: 3, stream_insert: 4]

  def timeline_insert(socket, entry, opts \\ []) do
    expanded = Map.get(socket.assigns, :expanded_tool_groups, MapSet.new())
    previous_timeline = socket.assigns.timeline
    pending_ids = pending_id_set(socket)
    collapse_opts = Keyword.take(opts, [:trailing_open?])

    {timeline, position, inserted?, incremental?} =
      previous_timeline
      |> upsert_in_sequence(entry, pending_ids)
      |> then(fn {entries, position, inserted?} ->
        if incremental_open_tool?(entries, position, inserted?, pending_ids, collapse_opts) do
          {project_open_tool(entries, position), position, inserted?, true}
        else
          timeline =
            HandbeanWeb.WorkspaceHelper.apply_tool_work_collapse(
              entries,
              expanded,
              collapse_opts
            )

          {timeline, position, inserted?, false}
        end
      end)

    entry_id = Map.get(entry, "id")
    projected = Enum.find(timeline, &(Map.get(&1, "id") == entry_id)) || entry

    socket
    |> put_timeline(previous_timeline, timeline, projected, incremental?)
    |> stream_timeline_entry(projected, position, inserted?)
    |> stream_changed_entries(previous_timeline, timeline, entry_id, incremental?)
    |> stream_related_handoffs(timeline, projected, inserted?)
  end

  def reconcile_handoffs(socket, entries) when is_list(entries) do
    entries
    |> Enum.filter(&conversation_entry?/1)
    |> reconcile_entries(socket)
  end

  def reconcile_transcript(socket, entries) when is_list(entries) do
    entries
    |> Handbean.PubSub.Projection.visible_entries()
    |> reconcile_entries(socket)
  end

  defp reconcile_entries(entries, socket) do
    entries
    |> Enum.filter(&entry_in_loaded_window?(socket, &1))
    |> Enum.reject(&timeline_entry_unchanged?(socket.assigns.timeline, &1))
    |> Enum.reduce(socket, fn entry, acc -> timeline_insert(acc, entry) end)
  end

  def mark_revert_confirm(socket, change_id) do
    socket = assign(socket, :revert_confirm_change_id, change_id)

    timeline =
      Enum.map(socket.assigns.timeline, fn entry ->
        id = change_id_of(entry)

        cond do
          id == change_id and is_binary(id) ->
            Map.put(entry, "revert_confirming", true)

          Map.get(entry, "revert_confirming") == true ->
            Map.delete(entry, "revert_confirming")

          true ->
            entry
        end
      end)

    reinsert_changed(socket, timeline)
  end

  def refresh_file_change(socket, id) when is_binary(id) do
    expanded = Map.get(socket.assigns, :expanded_file_changes, MapSet.new())
    open? = MapSet.member?(expanded, id)

    timeline =
      Enum.map(socket.assigns.timeline, fn entry ->
        if Map.get(entry, "id") == id, do: Map.put(entry, "file_change_open", open?), else: entry
      end)

    case Enum.find(timeline, &(Map.get(&1, "id") == id)) do
      %{} = entry ->
        socket
        |> assign(:timeline, timeline)
        |> stream_insert(:timeline, entry)

      _ ->
        assign(socket, :timeline, timeline)
    end
  end

  def refresh_tool_work(socket, group_id) do
    expanded = Map.get(socket.assigns, :expanded_tool_groups, MapSet.new())

    timeline =
      HandbeanWeb.WorkspaceHelper.apply_tool_work_collapse(socket.assigns.timeline, expanded)

    Enum.reduce(timeline, assign(socket, :timeline, timeline), fn entry, acc ->
      if Map.get(entry, "work_group_id") == group_id,
        do: stream_insert(acc, :timeline, entry),
        else: acc
    end)
  end

  def find_entry(timeline, id), do: Enum.find(timeline, &(Map.get(&1, "id") == id))

  defp change_id_of(entry) do
    change = HandbeanWeb.ChangeHelper.change_from_entry(entry)
    Map.get(change, "change_id")
  end

  def reinsert_changed(socket, timeline) do
    changed =
      timeline
      |> Enum.zip(socket.assigns.timeline)
      |> Enum.flat_map(fn
        {entry, entry} -> []
        {entry, _old} -> [entry]
      end)

    Enum.reduce(changed, assign(socket, :timeline, timeline), fn entry, acc ->
      stream_insert(acc, :timeline, entry)
    end)
  end

  def seal_tool_work(socket) do
    expanded = Map.get(socket.assigns, :expanded_tool_groups, MapSet.new())

    timeline =
      HandbeanWeb.WorkspaceHelper.apply_tool_work_collapse(socket.assigns.timeline, expanded)

    reinsert_changed(socket, timeline)
  end

  def finalize_assistant(%{assigns: %{current_assistant_entry_id: nil}} = socket), do: socket

  def finalize_assistant(socket) do
    case find_entry(socket.assigns.timeline, socket.assigns.current_assistant_entry_id) do
      %{"content_type" => "assistant_msg"} = entry ->
        timeline_insert(socket, Map.put(entry, "final", true))

      _ ->
        socket
    end
  end

  def update_messages(socket, chunk) do
    {thinking_text, clean_chunk, buffer} =
      Handbean.Agent.ThinkingFilter.strip(Map.get(socket.assigns, :think_buffer, ""), chunk)

    socket = assign(socket, :think_buffer, buffer)
    socket = if thinking_text != "", do: assign(socket, :thinking_active, true), else: socket
    socket = if clean_chunk != "", do: assign(socket, :thinking_active, false), else: socket
    update_assistant(socket, clean_chunk)
  end

  defdelegate update_status(socket, overrides), to: HandbeanWeb.WorkspaceLive.StatusProjection

  defdelegate maybe_update_status(socket, overrides),
    to: HandbeanWeb.WorkspaceLive.StatusProjection

  def usage_tokens(usage) when is_map(usage) do
    input = Map.get(usage, :input_tokens, Map.get(usage, "input_tokens", 0)) || 0
    output = Map.get(usage, :output_tokens, Map.get(usage, "output_tokens", 0)) || 0

    read =
      Map.get(usage, :cache_read_input_tokens, Map.get(usage, "cache_read_input_tokens", 0)) || 0

    write =
      Map.get(
        usage,
        :cache_creation_input_tokens,
        Map.get(usage, "cache_creation_input_tokens", 0)
      ) || 0

    unknown? = Map.get(usage, :unknown?, Map.get(usage, "unknown?", false))

    %{
      input_tokens: if(unknown?, do: :unknown, else: input),
      total_input_tokens:
        if(unknown?,
          do: :unknown,
          else: payload_value(usage, :total_input_tokens, input + read + write)
        ),
      output_tokens: if(unknown?, do: :unknown, else: output),
      cache_read_tokens: read,
      cache_write_tokens: write
    }
  end

  def usage_tokens(_),
    do: %{
      input_tokens: 0,
      total_input_tokens: 0,
      output_tokens: 0,
      cache_read_tokens: 0,
      cache_write_tokens: 0
    }

  def payload_value(payload, key, default \\ nil)

  def payload_value(payload, key, default) when is_map(payload) and is_atom(key),
    do: Map.get(payload, key, Map.get(payload, Atom.to_string(key), default))

  def payload_value(_payload, _key, default), do: default

  def safe_status(value) when is_atom(value), do: value
  def safe_status("completed"), do: :completed
  def safe_status("running"), do: :running
  def safe_status("error"), do: :error
  def safe_status("cancelled"), do: :cancelled
  def safe_status("timeout"), do: :timeout
  def safe_status("max_turns"), do: :max_turns
  def safe_status("interrupted"), do: :interrupted
  def safe_status("awaiting_approval"), do: :awaiting_approval
  def safe_status("stalled"), do: :stalled
  def safe_status("budget_exceeded"), do: :budget_exceeded
  def safe_status("halted"), do: :halted
  def safe_status(_), do: :idle

  def unique_id(prefix), do: "#{prefix}-#{Ecto.UUID.generate()}"

  def assistant_final?(entry, running, current_id) do
    cond do
      settled_assistant?(entry) -> true
      Map.has_key?(entry, "final") -> truthy?(Map.get(entry, "final"))
      running && Map.get(entry, "id") == current_id -> false
      true -> true
    end
  end

  def assistant_streaming?(entry, running, current_id) do
    running && Map.get(entry, "id") == current_id &&
      !assistant_final?(entry, running, current_id)
  end

  defp settled_assistant?(entry) do
    Map.get(entry, "status", Map.get(entry, :status)) in [
      "completed",
      :completed,
      "cancelled",
      :cancelled,
      "error",
      :error
    ]
  end

  defp update_assistant(socket, ""), do: socket

  defp update_assistant(socket, chunk) do
    id = socket.assigns.current_assistant_entry_id || unique_id("msg-assistant")

    {socket, entry} =
      case find_entry(socket.assigns.timeline, id) do
        nil ->
          socket = maybe_seal_tool_work(socket)

          {socket,
           %{
             "id" => id,
             "content_type" => "assistant_msg",
             "role" => "assistant",
             "content" => chunk
           }}

        existing ->
          {socket, Map.put(existing, "content", (Map.get(existing, "content") || "") <> chunk)}
      end

    # The first text entry seals completed tool work. Later deltas only update
    # that entry, avoiding a full regroup for every chunk.
    socket
    |> assign(:current_assistant_entry_id, id)
    |> assign(:timeline, replace_or_append(socket.assigns.timeline, entry))
    |> stream_insert(:timeline, entry)
  end

  defp maybe_seal_tool_work(socket) do
    if Enum.any?(socket.assigns.timeline, fn entry ->
         tool_entry?(entry) and Map.get(entry, "work_group_complete") == false
       end) do
      seal_tool_work(socket)
    else
      socket
    end
  end

  defp replace_or_append([], entry), do: [entry]

  defp replace_or_append([%{"id" => id} | rest], %{"id" => id} = entry),
    do: [entry | rest]

  defp replace_or_append([head | rest], entry) do
    [head | replace_or_append(rest, entry)]
  end

  defp upsert_in_sequence(timeline, %{"id" => id} = entry, pending_ids) do
    case Enum.find_index(timeline, &(Map.get(&1, "id") == id)) do
      nil ->
        position = insert_position(timeline, entry, id, pending_ids)
        {List.insert_at(timeline, position, entry), position, true}

      position ->
        {List.replace_at(timeline, position, entry), position, false}
    end
  end

  defp upsert_in_sequence(timeline, entry, _pending_ids),
    do: {timeline ++ [entry], length(timeline), true}

  defp insert_position(timeline, entry, id, pending_ids) do
    if MapSet.member?(pending_ids, id) do
      length(timeline)
    else
      position = sequence_insert_position(timeline, Map.get(entry, "sequence"))
      pinned_at = first_pending_index(timeline, pending_ids)
      if is_integer(pinned_at), do: min(position, pinned_at), else: position
    end
  end

  defp first_pending_index(timeline, pending_ids) do
    timeline
    |> Enum.with_index()
    |> Enum.find_value(fn {entry, index} ->
      if MapSet.member?(pending_ids, Map.get(entry, "id")), do: index
    end)
  end

  defp pending_id_set(socket) do
    socket.assigns
    |> Map.get(:pending_messages, %{})
    |> Kernel.||(%{})
    |> Map.keys()
    |> MapSet.new()
  end

  defp incremental_open_tool?(entries, position, inserted?, pending_ids, opts) do
    entry = Enum.at(entries, position)

    Keyword.get(opts, :trailing_open?, false) and tool_entry?(entry) and
      if inserted? do
        open_tool_insert?(entries, position, pending_ids)
      else
        is_binary(Map.get(entry, "work_group_id")) and
          Map.get(entry, "work_group_complete") == false
      end
  end

  defp open_tool_insert?(entries, position, pending_ids) do
    before = if position > 0, do: Enum.at(entries, position - 1)

    previous_group_open? =
      not tool_entry?(before) or Map.get(before, "work_group_complete") == false

    trailing? =
      entries
      |> Enum.drop(position + 1)
      |> Enum.all?(&MapSet.member?(pending_ids, Map.get(&1, "id")))

    previous_group_open? and trailing?
  end

  defp project_open_tool(entries, position) do
    previous = if position > 0, do: Enum.at(entries, position - 1)
    entry = Enum.fetch!(entries, position)
    group_id = if tool_entry?(previous), do: previous["work_group_id"], else: entry["id"]
    line = HandbeanWeb.WorkspaceHelper.tool_work_line(entry)

    projected =
      entry
      |> Map.put("work_group_id", group_id)
      |> Map.put("work_group_first", entry["id"] == group_id)
      |> Map.put("work_group_complete", false)
      |> Map.put("work_collapsed", false)
      |> Map.put("work_summary", nil)
      |> Map.put("work_indent", 1)
      |> Map.put("work_verb", line.verb)
      |> Map.put("work_target", line.target)

    List.replace_at(entries, position, projected)
  end

  defp tool_entry?(entry) when is_map(entry), do: Map.get(entry, "content_type") == "tool"
  defp tool_entry?(_entry), do: false

  def hydrate_timeline_entries(socket, ids) when is_list(ids) do
    present = MapSet.new(socket.assigns.timeline || [], &Map.get(&1, "id"))
    missing = Enum.filter(ids, &(is_binary(&1) and not MapSet.member?(present, &1)))

    if missing == [] do
      {:ok, socket}
    else
      conv_id = socket.assigns.current_conversation_id
      missing_set = MapSet.new(missing)

      with true <- is_binary(conv_id),
           {:ok, entries} <- Handbean.ConversationTranscriptStore.list(conv_id) do
        extras = Enum.filter(entries, &MapSet.member?(missing_set, Map.get(&1, "id")))

        if length(extras) == length(missing) do
          {:ok, Enum.reduce(extras, socket, fn entry, acc -> timeline_insert(acc, entry) end)}
        else
          {:error, :incomplete}
        end
      else
        false -> {:error, :no_conversation}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def durable_consumed?(timeline, ids) when is_list(ids) do
    by_id = Map.new(List.wrap(timeline), &{Map.get(&1, "id"), &1})

    ids != [] and
      Enum.all?(ids, fn id ->
        match?(%{"consumption" => "consumed"}, Map.get(by_id, id))
      end)
  end

  def refresh_history_cursor(socket, moved_ids) when is_list(moved_ids) do
    before = Map.get(socket.assigns, :history_before)

    if is_binary(before) and before in moved_ids do
      case socket.assigns.timeline do
        [%{"id" => id} | _] -> assign(socket, :history_before, id)
        _ -> assign(socket, :history_before, nil)
      end
    else
      socket
    end
  end

  defp sequence_insert_position(timeline, sequence) when is_integer(sequence) do
    timeline
    |> Stream.with_index()
    |> Enum.reduce(nil, fn {entry, index}, position ->
      case Map.get(entry, "sequence") do
        current when is_integer(current) and current <= sequence -> index + 1
        _ -> position
      end
    end)
    |> Kernel.||(0)
  end

  defp sequence_insert_position(timeline, _sequence), do: length(timeline)

  defp stream_timeline_entry(socket, entry, position, true),
    do: stream_insert(socket, :timeline, entry, at: position)

  defp stream_timeline_entry(socket, entry, _position, false),
    do: stream_insert(socket, :timeline, entry)

  defp put_timeline(socket, previous, timeline, projected, true) do
    if timeline_shell(previous) != timeline_shell(timeline) or
         visible_file_changes_may_have_changed?(socket, previous, projected) do
      assign(socket, :timeline, timeline)
    else
      %{socket | assigns: Map.put(socket.assigns, :timeline, timeline)}
    end
  end

  defp put_timeline(socket, _previous, timeline, _projected, false),
    do: assign(socket, :timeline, timeline)

  defp timeline_shell([]), do: :empty
  defp timeline_shell([_entry]), do: :single
  defp timeline_shell(_timeline), do: :multiple

  defp visible_file_changes_may_have_changed?(socket, previous, projected) do
    Map.get(socket.assigns, :right_panel_view) == :changes and
      (HandbeanWeb.FileChangeCard.change_source?(projected) or
         previous
         |> find_entry(Map.get(projected, "id"))
         |> HandbeanWeb.FileChangeCard.change_source?())
  end

  defp stream_changed_entries(socket, _previous, _timeline, _inserted_id, true), do: socket

  defp stream_changed_entries(socket, previous, timeline, inserted_id, false) do
    previous_by_id = Map.new(previous, &{Map.get(&1, "id"), &1})

    Enum.reduce(timeline, socket, fn entry, acc ->
      id = Map.get(entry, "id")

      if id != inserted_id and Map.get(previous_by_id, id) != entry,
        do: stream_insert(acc, :timeline, entry),
        else: acc
    end)
  end

  defp stream_related_handoffs(socket, timeline, inserted, true) do
    if conversation_entry?(inserted) do
      association = handoff_association(inserted)

      Enum.reduce(timeline, socket, fn entry, acc ->
        if Map.get(entry, "id") != Map.get(inserted, "id") and conversation_entry?(entry) and
             handoff_association(entry) == association,
           do: stream_insert(acc, :timeline, entry),
           else: acc
      end)
    else
      socket
    end
  end

  defp stream_related_handoffs(socket, _timeline, _inserted, false), do: socket

  defp timeline_entry_unchanged?(timeline, entry), do: Enum.any?(timeline, &(&1 == entry))

  defp entry_in_loaded_window?(socket, entry) do
    timeline = socket.assigns.timeline
    id = Map.get(entry, "id")

    cond do
      Enum.any?(timeline, &(Map.get(&1, "id") == id)) ->
        true

      not Map.get(socket.assigns, :history_has_more?, false) ->
        true

      true ->
        with sequence when is_integer(sequence) <- Map.get(entry, "sequence"),
             oldest when is_integer(oldest) <- oldest_loaded_sequence(timeline) do
          sequence >= oldest
        else
          _ -> false
        end
    end
  end

  defp oldest_loaded_sequence(timeline) do
    timeline
    |> Enum.map(&Map.get(&1, "sequence"))
    |> Enum.filter(&is_integer/1)
    |> Enum.min(fn -> nil end)
  end

  defp conversation_entry?(entry) do
    Map.get(entry, "content_type") == "conversation_handoff" or
      get_in(entry, ["origin", "kind"]) == "conversation"
  end

  defp handoff_association(entry) do
    Map.get(entry, "handoff_id") || get_in(entry, ["origin", "handoff_id"]) ||
      get_in(entry, ["origin", "request_id"]) || Map.get(entry, "id")
  end

  defp truthy?(value), do: value in [true, "true", 1, "1"]
end
