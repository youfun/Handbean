defmodule HandbeanWeb.WorkspaceLive.RuntimeProjection do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1]

  require Logger

  alias Handbean.PubSub.{AgentEvent, Projection}
  alias HandbeanWeb.WorkspaceLive.CliSelection
  alias HandbeanWeb.WorkspaceLive.RuntimeProjection.Timeline

  defdelegate timeline_insert(socket, entry, opts \\ []), to: Timeline
  defdelegate reconcile_handoffs(socket, entries), to: Timeline
  defdelegate reconcile_transcript(socket, entries), to: Timeline
  defdelegate mark_revert_confirm(socket, change_id), to: Timeline
  defdelegate refresh_file_change(socket, id), to: Timeline
  defdelegate refresh_tool_work(socket, group_id), to: Timeline
  defdelegate find_entry(timeline, id), to: Timeline
  defdelegate finalize_assistant(socket), to: Timeline
  defdelegate update_messages(socket, chunk), to: Timeline
  defdelegate update_status(socket, overrides), to: Timeline
  defdelegate maybe_update_status(socket, overrides), to: Timeline
  defdelegate usage_tokens(usage), to: Timeline
  defdelegate payload_value(payload, key, default \\ nil), to: Timeline
  defdelegate safe_status(value), to: Timeline
  defdelegate unique_id(prefix), to: Timeline
  defdelegate assistant_final?(entry, running, current_id), to: Timeline
  defdelegate assistant_streaming?(entry, running, current_id), to: Timeline

  defp hydrate_timeline_entries(socket, ids), do: Timeline.hydrate_timeline_entries(socket, ids)
  defp durable_consumed?(timeline, ids), do: Timeline.durable_consumed?(timeline, ids)
  defp refresh_history_cursor(socket, ids), do: Timeline.refresh_history_cursor(socket, ids)

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

  defp project_timeline(socket, entry, opts), do: timeline_insert(socket, entry, opts)

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

    model = model_display_from_payload(payload, socket)

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
      model: model,
      active_model: model,
      future_model:
        ModelSelection.model_display_name(
          socket.assigns.selected_model,
          socket.assigns.available_models
        ),
      pending_model: nil,
      pending_model_revision: nil,
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

      model = model_display_from_payload(payload, socket)

      socket
      |> assign(:running, true)
      |> assign(:running_conversation_id, socket.assigns.current_conversation_id)
      |> assign(:stream_suppressed, false)
      |> update_request_model_status(payload, model, %{
        status: :running,
        turns: turns
      })
    end
  end

  def handle_agent_event(%{kind: :model_switch_accepted, payload: payload}, socket) do
    update_status(socket, %{
      pending_model: model_display_from_payload(payload, socket),
      pending_model_revision: payload_value(payload, :revision),
      model_switch_status: :accepted,
      status_detail: nil
    })
  end

  def handle_agent_event(%{kind: :model_switch_applied, payload: payload}, socket) do
    model = model_display_from_payload(payload, socket)

    update_status(socket, %{
      model: model,
      active_model: model,
      pending_model: nil,
      pending_model_revision: nil,
      model_switch_status: :applied,
      status_detail: nil
    })
  end

  def handle_agent_event(%{kind: :provider_request_started, payload: payload}, socket) do
    model = model_display_from_payload(payload, socket)

    update_request_model_status(socket, payload, model, %{
      model_switch_status: :request_started
    })
  end

  def handle_agent_event(%{kind: kind, payload: payload}, socket)
      when kind in [:model_switch_cancelled, :model_switch_expired] do
    update_status(socket, %{
      pending_model: nil,
      pending_model_revision: nil,
      model_switch_status: payload_value(payload, :status, kind),
      status_detail: nil
    })
  end

  def handle_agent_event(%{kind: :model_switch_failed, payload: payload}, socket) do
    update_status(socket, %{
      pending_model: nil,
      pending_model_revision: nil,
      model_switch_status: :failed,
      status_detail: "Model switch failed: #{payload_value(payload, :error, "unknown error")}"
    })
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

  defp update_request_model_status(socket, payload, model, overrides) do
    request_revision = payload_value(payload, :config_revision)
    pending_revision = Map.get(socket.assigns.status_info, :pending_model_revision)

    base = Map.merge(overrides, %{model: model, active_model: model})

    if is_integer(pending_revision) and
         (not is_integer(request_revision) or pending_revision > request_revision) do
      update_status(socket, Map.delete(base, :model_switch_status))
    else
      update_status(
        socket,
        Map.merge(base, %{pending_model: nil, pending_model_revision: nil})
      )
    end
  end

  defp model_display_from_payload(payload, socket) do
    model = payload_value(payload, :model_ref) || payload_value(payload, :model)
    ModelSelection.model_display_name(model, socket.assigns.available_models)
  end

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
    |> project_timeline(event, persist?: false, trailing_open?: socket.assigns.running)
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
      |> project_timeline(entry, persist?: false, trailing_open?: socket.assigns.running)
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
      |> seal_tool_work()
      |> assign(:conv_tokens, usage)
      |> finalize_assistant()
      |> assign(:running, false)
      |> assign(:running_conversation_id, nil)
      |> assign(:stream_suppressed, status == :cancelled)
      |> assign(:tools_active, %{})
      |> assign(:current_assistant_entry_id, nil)
      |> update_status(
        Map.merge(
          %{
            status: status,
            status_detail: nil,
            turns: turns,
            pending_model: nil,
            pending_model_revision: nil
          },
          usage
        )
      )
      |> maybe_append_error_message(run_error, persist?: false)

    # If the send path did not name the chat, try again now. A completed run
    # must not be required for the first title.
    ConversationState.maybe_auto_title(socket, status)
  end

  def mark_run_cancelled(socket) do
    socket
    |> seal_tool_work()
    |> finalize_assistant()
    |> assign(:running, false)
    |> assign(:running_conversation_id, nil)
    |> assign(:stream_suppressed, true)
    |> assign(:tools_active, %{})
    |> assign(:current_assistant_entry_id, nil)
    |> assign(:pending_approval, nil)
    |> update_status(%{
      status: :cancelled,
      status_detail: nil,
      pending_model: nil,
      pending_model_revision: nil
    })
  end

  defp seal_tool_work(socket), do: Timeline.seal_tool_work(socket)

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

        socket = reconcile_model_status(socket, meta, running?)

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

  @doc false
  def reconcile_model_status(socket, _meta, false) do
    update_status(socket, %{pending_model: nil, pending_model_revision: nil})
  end

  def reconcile_model_status(socket, meta, true) do
    active_payload = meta[:active_model] || %{:model => meta[:model]}
    pending_payload = meta[:pending_model]
    active = model_display_from_payload(active_payload, socket)

    pending =
      if is_map(pending_payload),
        do: model_display_from_payload(pending_payload, socket),
        else: nil

    pending_revision =
      if is_map(pending_payload),
        do: payload_value(pending_payload, :revision, meta[:model_switch_revision]),
        else: nil

    overrides = %{
      pending_model: pending,
      pending_model_revision: pending_revision,
      model_switch_status: meta[:model_switch_status]
    }

    overrides =
      if is_binary(active) and active != "",
        do: Map.merge(overrides, %{model: active, active_model: active}),
        else: overrides

    update_status(socket, overrides)
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
