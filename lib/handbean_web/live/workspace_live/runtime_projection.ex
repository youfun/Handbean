defmodule HandbeanWeb.WorkspaceLive.RuntimeProjection do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1, stream_insert: 3, stream_insert: 4]

  require Logger

  alias Handbean.PubSub.{AgentEvent, Projection}
  alias HandbeanWeb.WorkspaceLive.CliSelection

  def timeline_insert(socket, entry) do
    expanded = Map.get(socket.assigns, :expanded_tool_groups, MapSet.new())
    previous_timeline = socket.assigns.timeline
    pending_ids = pending_id_set(socket)

    {timeline, position, inserted?} =
      previous_timeline
      |> upsert_in_sequence(entry, pending_ids)
      |> then(fn {entries, position, inserted?} ->
        {HandbeanWeb.WorkspaceHelper.apply_tool_work_collapse(entries, expanded), position,
         inserted?}
      end)

    entry_id = Map.get(entry, "id")
    projected = Enum.find(timeline, &(Map.get(&1, "id") == entry_id)) || entry

    socket
    |> assign(:timeline, timeline)
    |> stream_timeline_entry(projected, position, inserted?)
    |> stream_changed_entries(previous_timeline, timeline, entry_id)
    |> stream_related_handoffs(timeline, projected, inserted?)
  end

  def reconcile_handoffs(socket, entries) when is_list(entries) do
    entries
    |> Enum.filter(&conversation_entry?/1)
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

  defp reinsert_changed(socket, timeline) do
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

    entry =
      case find_entry(socket.assigns.timeline, id) do
        nil ->
          %{
            "id" => id,
            "content_type" => "assistant_msg",
            "role" => "assistant",
            "content" => chunk
          }

        existing ->
          Map.put(existing, "content", (Map.get(existing, "content") || "") <> chunk)
      end

    # Text deltas do not change tool streak membership. Keep the server-side
    # projection current for history/reset paths without regrouping every chunk.
    socket
    |> assign(:current_assistant_entry_id, id)
    |> assign(:timeline, replace_or_append(socket.assigns.timeline, entry))
    |> stream_insert(:timeline, entry)
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

  defp hydrate_timeline_entries(socket, ids) when is_list(ids) do
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

  defp durable_consumed?(timeline, ids) when is_list(ids) do
    by_id = Map.new(List.wrap(timeline), &{Map.get(&1, "id"), &1})

    ids != [] and
      Enum.all?(ids, fn id ->
        match?(%{"consumption" => "consumed"}, Map.get(by_id, id))
      end)
  end

  defp refresh_history_cursor(socket, moved_ids) when is_list(moved_ids) do
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
    |> Enum.with_index()
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

  defp stream_changed_entries(socket, previous, timeline, inserted_id) do
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

  alias HandbeanWeb.WorkspaceLive.Composer
  alias HandbeanWeb.WorkspaceLive.ConversationState
  alias HandbeanWeb.WorkspaceLive.EditorProjection
  alias HandbeanWeb.WorkspaceLive.ModelSelection
  alias HandbeanWeb.WorkspaceLive.ToolProjection

  @high_freq_events [:message_delta, :thinking_delta]

  def apply(socket, event), do: handle_current_agent_event(event, socket)
  def restore_active_session(socket), do: restore_active_session_snapshot(socket)
  def subscribe_session(socket), do: subscribe_to_session(socket)
  def subscribe_tasks(socket), do: subscribe_to_runtime_tasks(socket)
  def mark_cancelled(socket), do: mark_run_cancelled(socket)

  defp project_timeline(socket, entry, _opts), do: timeline_insert(socket, entry)

  def handle_current_agent_event(
        %Handbean.PubSub.AgentEvent{topic: "session:" <> _} = event,
        socket
      ) do
    unless event.kind in @high_freq_events do
      Logger.debug(
        "[WorkspaceLive] received agent event kind=#{inspect(event.kind)} " <>
          "topic=#{event.topic} current=#{session_topic(socket.assigns.current_conversation_id)}"
      )
    end

    case Projection.classify(
           event,
           session_topic(socket.assigns.current_conversation_id),
           Map.get(socket.assigns, :session_seq, 0),
           Map.get(socket.assigns, :session_epoch)
         ) do
      :apply ->
        if event.kind == :message_delta and
             Projection.text_patch(socket.assigns.timeline, event.payload) == :recover and
             (Map.has_key?(event.payload, :transcript_id) or
                Map.has_key?(event.payload, "transcript_id")) do
          restore_active_session_snapshot(socket)
        else
          socket =
            socket
            |> assign(:session_seq, event.seq)
            |> assign(:session_epoch, event.epoch || Map.get(socket.assigns, :session_epoch))

          handle_agent_event(event, socket)
        end

      :recover ->
        restore_active_session_snapshot(socket)

      :ignore ->
        socket
    end
  end

  def handle_current_agent_event(%Handbean.PubSub.AgentEvent{} = event, socket) do
    handle_agent_event(event, socket)
  end

  def handle_current_agent_event(event, socket), do: handle_agent_event(event, socket)

  def handle_agent_event(%{kind: :run_start, payload: payload}, socket) do
    Logger.debug(
      "[WorkspaceLive] applying run_start conversation=#{socket.assigns.current_conversation_id}"
    )

    socket
    |> assign(:running, true)
    |> assign(:running_conversation_id, socket.assigns.current_conversation_id)
    |> assign(:stream_suppressed, false)
    |> assign(:tools_active, %{})
    |> assign(:current_assistant_entry_id, nil)
    |> assign(:thinking_active, false)
    |> assign(:thinking_content, "")
    |> assign(:think_buffer, "")
    |> update_status(%{
      model: ModelSelection.model_display_name(payload[:model], socket.assigns.available_models),
      status: :running,
      status_detail: nil,
      input_tokens: 0,
      total_input_tokens: 0,
      output_tokens: 0,
      cache_read_tokens: 0,
      cache_write_tokens: 0,
      turns: 0
    })
  end

  def handle_agent_event(%{kind: :run_resumed}, socket) do
    socket
    |> assign(:pending_approval, nil)
    |> assign(:running, true)
    |> assign(:running_conversation_id, socket.assigns.current_conversation_id)
    |> update_status(%{status: :running, status_detail: nil})
  end

  def handle_agent_event(%{kind: :session_state, payload: payload}, socket) do
    if socket.assigns.stream_suppressed do
      socket
    else
      detail = payload_value(payload, :state)

      if is_binary(detail) and String.trim(detail) != "" do
        update_status(socket, %{status_detail: detail})
      else
        socket
      end
    end
  end

  def handle_agent_event(%{kind: :turn_start, payload: payload}, socket) do
    if socket.assigns.stream_suppressed do
      socket
    else
      turns = payload_value(payload, :turn, Map.get(socket.assigns.status_info, :turns, 0))

      socket
      |> assign(:running, true)
      |> assign(:running_conversation_id, socket.assigns.current_conversation_id)
      |> assign(:stream_suppressed, false)
      |> update_status(%{status: :running, turns: turns})
    end
  end

  def handle_agent_event(%{kind: :usage_updated, payload: payload}, socket) do
    if socket.assigns.stream_suppressed do
      socket
    else
      # Runtime usage is cumulative for this run; replace rather than add on replay.
      update_status(socket, payload |> payload_value(:usage, %{}) |> usage_tokens())
    end
  end

  def handle_agent_event(%{kind: :message_delta, payload: %{transcript_id: _} = payload}, socket) do
    project_text_patch(socket, payload)
  end

  def handle_agent_event(
        %{kind: :message_delta, payload: %{"transcript_id" => _} = payload},
        socket
      ) do
    project_text_patch(socket, payload)
  end

  def handle_agent_event(%{kind: :message_delta, payload: %{chunk: chunk}}, socket) do
    # Logger.debug(
    #   "[WorkspaceLive] agent event message_delta bytes=#{byte_size(chunk)} " <>
    #     "conversation=#{socket.assigns.current_conversation_id}"
    # )

    if socket.assigns.stream_suppressed do
      Logger.debug(
        "[WorkspaceLive] dropped suppressed message_delta bytes=#{byte_size(chunk)} " <>
          "conversation=#{socket.assigns.current_conversation_id}"
      )

      socket
    else
      update_messages(socket, chunk)
    end
  end

  def handle_agent_event(%{kind: :thinking_delta}, socket) do
    if socket.assigns.stream_suppressed do
      socket
    else
      assign(socket, :thinking_active, true)
    end
  end

  def handle_agent_event(%{kind: :tool_start, payload: payload}, socket) do
    if socket.assigns.stream_suppressed do
      Logger.debug(
        "[WorkspaceLive] dropped suppressed tool_start conversation=#{socket.assigns.current_conversation_id}"
      )

      socket
    else
      do_handle_tool_start(payload, socket)
    end
  end

  def handle_agent_event(%{kind: :tool_end, payload: payload}, socket) do
    if socket.assigns.stream_suppressed do
      Logger.debug(
        "[WorkspaceLive] dropped suppressed tool_end conversation=#{socket.assigns.current_conversation_id}"
      )

      socket
    else
      do_handle_tool_end(payload, socket)
    end
  end

  def handle_agent_event(%{kind: :tool_approval_requested, payload: payload}, socket) do
    Logger.debug(
      "[WorkspaceLive] tool_approval_requested conversation=#{socket.assigns.current_conversation_id}"
    )

    socket
    |> assign(:pending_approval, payload)
    |> update_status(%{status: :awaiting_approval})
  end

  def handle_agent_event(%{kind: :candidate_message_injected, payload: payload}, socket) do
    case payload_value(payload, :message_ids, []) do
      ids when is_list(ids) and ids != [] ->
        cond do
          durable_consumed?(socket.assigns.timeline, ids) ->
            Composer.assign_pending(
              socket,
              Handbean.Agent.PendingMessages.apply_injected(
                socket.assigns.pending_messages,
                payload
              )
            )

          true ->
            case hydrate_timeline_entries(socket, ids) do
              {:ok, socket} ->
                timeline =
                  Handbean.Agent.PendingMessages.move_to_end(
                    socket.assigns.timeline || [],
                    ids
                  )

                socket
                |> assign(:timeline, timeline)
                |> refresh_history_cursor(ids)
                |> Composer.assign_pending(
                  Handbean.Agent.PendingMessages.apply_injected(
                    socket.assigns.pending_messages,
                    payload
                  )
                )

              {:error, _reason} ->
                socket
            end
        end

      _ ->
        Composer.assign_pending(
          socket,
          Handbean.Agent.PendingMessages.apply_injected(socket.assigns.pending_messages, payload)
        )
    end
  end

  def handle_agent_event(%{kind: :candidate_message_deleted, payload: payload}, socket) do
    id = payload_value(payload, :message_id) || payload_value(payload, :id)

    socket =
      assign(
        socket,
        :timeline,
        Handbean.Agent.PendingMessages.drop_entry(socket.assigns.timeline || [], id)
      )

    pending =
      Handbean.Agent.PendingMessages.apply_deleted(socket.assigns.pending_messages, payload)

    Composer.assign_pending(socket, pending)
  end

  def handle_agent_event(%{kind: :run_end, payload: payload}, socket) do
    status_value = payload_value(payload, :status)

    Logger.debug(
      "[WorkspaceLive] agent event run_end status=#{inspect(status_value)} " <>
        "conversation=#{socket.assigns.current_conversation_id}"
    )

    status = safe_status(status_value)

    socket =
      if (socket.assigns.stream_suppressed and status != :cancelled) or
           not (AgentEvent.terminal_status?(status) or AgentEvent.waiting_status?(status)) do
        Logger.debug(
          "[WorkspaceLive] dropped suppressed run_end status=#{inspect(status_value)} " <>
            "conversation=#{socket.assigns.current_conversation_id}"
        )

        socket
      else
        assign(do_handle_run_end(payload, status, socket), :thinking_active, false)
      end

    # Only clear pending_approval on terminal run_end (not interrupted/awaiting_approval)
    socket =
      if AgentEvent.terminal_status?(status) do
        socket
        |> assign(:pending_approval, nil)
        |> Composer.assign_pending(
          Handbean.Agent.PendingMessages.apply_run_end(socket.assigns.pending_messages, status)
        )
      else
        if AgentEvent.waiting_status?(status) do
          socket
          |> assign(:running, true)
          |> assign(:running_conversation_id, socket.assigns.current_conversation_id)
        else
          socket
        end
      end

    socket
  end

  def handle_agent_event(_event, socket), do: socket

  defp project_text_patch(socket, payload) do
    if socket.assigns.stream_suppressed do
      socket
    else
      case Projection.text_patch(socket.assigns.timeline, payload) do
        {:ok, entry} ->
          socket
          |> assign(:current_assistant_entry_id, entry["id"])
          |> assign(:thinking_active, false)
          |> timeline_insert(entry)

        :ignore ->
          socket

        :recover ->
          restore_active_session_snapshot(socket)
      end
    end
  end

  def do_handle_tool_start(payload, socket) do
    %{entry: event, tool_name: tool_name} = ToolProjection.start(payload, &summarize_input/2)

    tools_active = Map.put(socket.assigns.tools_active, tool_name, :running)

    socket
    |> finalize_assistant()
    |> assign(:tools_active, tools_active)
    |> assign(:current_assistant_entry_id, nil)
    |> project_timeline(event, persist?: false)
  end

  def do_handle_tool_end(payload, socket) do
    {id, tool_name, tool_use_id} = ToolProjection.identity(payload)

    base_entry =
      find_entry(socket.assigns.timeline, id) ||
        %{
          "id" => id,
          "content_type" => "tool",
          "tool_use_id" => tool_use_id,
          "tool_name" => tool_name,
          "tool_input_summary" => ""
        }

    projection = ToolProjection.finish(payload, base_entry)
    %{entry: entry, status: status, file_path: file_path, diff_lines: diff_lines} = projection
    tools_active = Map.put(socket.assigns.tools_active, projection.tool_name, status)

    updated =
      socket
      |> assign(:tools_active, tools_active)
      |> project_timeline(entry, persist?: false)
      |> maybe_project_published_media(payload, status)
      |> EditorProjection.maybe_add_diff_file(
        file_path,
        diff_lines,
        ConversationState.current_checkout_path(socket)
      )

    if updated.assigns.editor_files != socket.assigns.editor_files do
      assign(updated, :refresh_tree_parent, Path.expand(file_path))
    else
      updated
    end
  end

  defp maybe_project_published_media(socket, payload, :done) do
    media =
      payload
      |> payload_value(:published_media, [])
      |> Handbean.Media.project()

    tool_use_id = payload_value(payload, :tool_use_id)

    if media != [] and is_binary(tool_use_id) do
      timeline_insert(socket, %{
        "id" => "msg-media-#{tool_use_id}",
        "content_type" => "assistant_msg",
        "message_type" => "assistant",
        "role" => "assistant",
        "direction" => "outbound",
        "phase" => "commentary",
        "status" => "completed",
        "content" => "",
        "run_id" => payload_value(payload, :run_id),
        "turn_number" => payload_value(payload, :turn_number),
        "tool_call_id" => tool_use_id,
        "parent_tool_call_id" => payload_value(payload, :parent_tool_call_id),
        "attachments" => media
      })
    else
      socket
    end
  end

  defp maybe_project_published_media(socket, _payload, _status), do: socket

  def do_handle_run_end(payload, status, socket) do
    turns = payload_value(payload, :turns, 0)
    run_error = payload_value(payload, :error)
    # Runtime already recorded a terminal run. Reload that conversation's
    # totals. Interrupted is not terminal, so keep the in-flight figures.
    usage =
      if status == :interrupted do
        payload |> payload_value(:usage, %{}) |> usage_tokens()
      else
        ConversationState.load_conversation_token_usage(socket.assigns.current_conversation_id)
      end

    socket =
      socket
      |> assign(:conv_tokens, usage)
      |> finalize_assistant()
      |> assign(:running, false)
      |> assign(:running_conversation_id, nil)
      |> assign(:stream_suppressed, status == :cancelled)
      |> assign(:tools_active, %{})
      |> assign(:current_assistant_entry_id, nil)
      |> update_status(Map.merge(%{status: status, status_detail: nil, turns: turns}, usage))
      |> maybe_append_error_message(run_error, persist?: false)

    # If the send path did not name the chat, try again now. A completed run
    # must not be required for the first title.
    ConversationState.maybe_auto_title(socket, status)
  end

  def mark_run_cancelled(socket) do
    socket
    |> finalize_assistant()
    |> assign(:running, false)
    |> assign(:running_conversation_id, nil)
    |> assign(:stream_suppressed, true)
    |> assign(:tools_active, %{})
    |> assign(:current_assistant_entry_id, nil)
    |> assign(:pending_approval, nil)
    |> update_status(%{status: :cancelled, status_detail: nil})
  end

  def restore_active_session_snapshot(socket) do
    conv_id = socket.assigns.current_conversation_id

    if is_binary(conv_id) do
      with {:ok, %{snapshot: snapshot, history: history}} <-
             Projection.recover(conv_id, length(socket.assigns.timeline)) do
        meta = snapshot.meta
        pid = meta[:agent_pid]
        running? = meta[:running?] == true and is_pid(pid) and Process.alive?(pid)

        pending =
          Handbean.Agent.PendingMessages.replay(
            socket.assigns.pending_messages || %{},
            snapshot.pending_events,
            if(Map.get(socket.assigns, :session_epoch) == snapshot.epoch,
              do: Map.get(socket.assigns, :session_seq, 0),
              else: 0
            )
          )

        socket =
          HandbeanWeb.WorkspaceLive.ConversationState.sync_conv_state(socket,
            reload?: true,
            force_transcript?: true,
            transcript_page: history
          )

        socket =
          socket
          |> assign(:session_seq, snapshot.last_seq)
          |> assign(:session_epoch, snapshot.epoch)
          |> assign(:running, running?)
          |> assign(:running_conversation_id, if(running?, do: conv_id))
          |> assign(:pending_approval, nil)
          |> assign(:tools_active, %{})
          |> assign(
            :current_assistant_entry_id,
            streaming_assistant_message_id(socket.assigns.timeline, meta[:run_id])
          )

        # Durable text is already in history. Replay only active-run control state,
        # bypassing admission because these events are at/below the checkpoint.
        socket =
          if running? do
            snapshot.control_events
            |> Enum.reject(&(&1.kind in [:message_delta, :thinking_delta]))
            |> Enum.reduce(socket, &handle_agent_event/2)
          else
            socket
          end

        pending =
          Handbean.Agent.PendingMessages.reconcile(
            pending,
            session_pending_messages(conv_id),
            running?,
            socket.assigns.timeline || []
          )

        Composer.assign_pending(socket, pending)
      else
        {:error, _} -> socket
      end
      |> CliSelection.restore_current()
    else
      socket
    end
  end

  def session_pending_messages(conv_id) do
    if Handbean.PubSub.Session.whereis(conv_id) do
      Handbean.PubSub.Session.get_pending_messages(conv_id)
    else
      []
    end
  catch
    :exit, _ -> []
  end

  def maybe_skip_message_delta_events(events, true), do: events

  def maybe_skip_message_delta_events(events, false) do
    Enum.reject(events, &(&1.kind == :message_delta))
  end

  def timeline_has_assistant_message?(timeline) do
    Enum.any?(timeline, fn entry ->
      Map.get(entry, "content_type") == "assistant_msg" or
        Map.get(entry, :content_type) == "assistant_msg"
    end)
  end

  def streaming_assistant_message_id(timeline, run_id) do
    timeline
    |> Enum.reverse()
    |> Enum.find_value(fn entry ->
      content_type = Map.get(entry, "content_type", Map.get(entry, :content_type))
      status = Map.get(entry, "status", Map.get(entry, :status))
      entry_run_id = Map.get(entry, "run_id", Map.get(entry, :run_id))

      if content_type == "assistant_msg" and status in ["streaming", :streaming] and
           entry_run_id == run_id do
        Map.get(entry, "id", Map.get(entry, :id))
      end
    end)
  end

  def summarize_input(input, _tool_name) do
    case input do
      %{file_path: path} when is_binary(path) ->
        Path.basename(path) <> range_suffix(input)

      %{"file_path" => path} when is_binary(path) ->
        Path.basename(path) <> range_suffix(input)

      %{command: cmd} when is_binary(cmd) ->
        String.slice(cmd, 0, 60)

      %{"command" => cmd} when is_binary(cmd) ->
        String.slice(cmd, 0, 60)

      %{content: content} when is_binary(content) ->
        String.slice(content, 0, 60)

      %{"content" => content} when is_binary(content) ->
        String.slice(content, 0, 60)

      %{query: query} when is_binary(query) ->
        String.slice(query, 0, 60)

      %{"query" => query} when is_binary(query) ->
        String.slice(query, 0, 60)

      _ when input == %{} ->
        ""

      _ ->
        input |> inspect() |> String.slice(0, 60)
    end
  end

  def range_suffix(input) do
    offset = get_offset(input)
    limit = get_limit(input)

    cond do
      is_integer(offset) and offset > 0 and is_integer(limit) ->
        end_line = offset + limit - 1
        ":#{offset}-#{end_line}"

      is_integer(offset) and offset > 0 ->
        ":#{offset}"

      true ->
        ""
    end
  end

  def get_offset(%{offset: offset}) when is_integer(offset), do: offset
  def get_offset(%{"offset" => offset}) when is_integer(offset), do: offset
  def get_offset(_), do: nil
  def get_limit(%{limit: limit}) when is_integer(limit), do: limit
  def get_limit(%{"limit" => limit}) when is_integer(limit), do: limit
  def get_limit(_), do: nil
  def maybe_append_error_message(socket, error, opts)
  def maybe_append_error_message(socket, nil, _opts), do: socket

  def maybe_append_error_message(socket, error, opts) do
    msg = "Run error: #{error}"

    entry = %{
      "id" => unique_id("msg-system"),
      "content_type" => "system_msg",
      "role" => "system",
      "content" => msg
    }

    project_timeline(socket, entry, opts)
  end

  def subscribe_to_runtime_tasks(socket) do
    if connected?(socket) do
      Handbean.Runtime.TaskTracker.subscribe()
      Handbean.Runtime.TaskTracker.viewing(self(), socket.assigns.current_conversation_id)
      assign(socket, :runtime_tasks, Handbean.Runtime.TaskTracker.snapshot())
    else
      assign(socket, :runtime_tasks, %{running_count: 0, waiting_count: 0, tasks: []})
    end
  end

  def subscribe_to_session(socket) do
    if connected?(socket) do
      Handbean.Runtime.TaskTracker.viewing(self(), socket.assigns.current_conversation_id)
      conv_id = socket.assigns.current_conversation_id
      topic = session_topic(conv_id)
      previous_topic = Map.get(socket.assigns, :subscribed_session_topic)

      if previous_topic && previous_topic != topic do
        Phoenix.PubSub.unsubscribe(Handbean.PubSub, previous_topic)
      end

      if previous_topic != topic do
        Phoenix.PubSub.subscribe(Handbean.PubSub, topic)
      end

      socket
      |> assign(:subscribed_session_topic, topic)
      |> assign(
        :session_seq,
        if(previous_topic == topic, do: Map.get(socket.assigns, :session_seq, 0), else: 0)
      )
      |> assign(
        :session_epoch,
        if(previous_topic == topic, do: Map.get(socket.assigns, :session_epoch))
      )
      |> subscribe_to_extension_ui()
    else
      socket
    end
  end

  def session_topic(conv_id), do: "session:#{conv_id}"

  def subscribe_to_extension_ui(socket) do
    if connected?(socket) do
      conv_id = socket.assigns.current_conversation_id
      topic = Handbean.Extension.UI.topic(conv_id)
      previous_topic = Map.get(socket.assigns, :subscribed_ext_ui_topic)

      if previous_topic && previous_topic != topic do
        Phoenix.PubSub.unsubscribe(Handbean.PubSub, previous_topic)
      end

      if previous_topic != topic do
        Phoenix.PubSub.subscribe(Handbean.PubSub, topic)
      end

      assign(socket, :subscribed_ext_ui_topic, topic)
    else
      socket
    end
  end
end
