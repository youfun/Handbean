defmodule HandbeanWeb.WorkspaceLive.ConversationRouting do
  @moduledoc false

  use HandbeanWeb, :html

  import Phoenix.LiveView

  alias HandbeanWeb.WorkspaceLive.CliSelection
  alias HandbeanWeb.WorkspaceLive.Composer
  alias HandbeanWeb.WorkspaceLive.ConversationState
  alias HandbeanWeb.WorkspaceLive.ConversationSwitching
  alias HandbeanWeb.WorkspaceLive.MessageSubmission
  alias HandbeanWeb.WorkspaceLive.ModelSelection
  alias HandbeanWeb.WorkspaceLive.NewConversationDraft
  alias HandbeanWeb.WorkspaceLive.RuntimeProjection
  alias HandbeanWeb.WorkspaceLive.Schedules
  alias HandbeanWeb.WorkspaceLive.Skills
  alias HandbeanWeb.WorkspaceLive.WorkspaceNavigation

  @pending_message_source "new_conversation_draft"
  @transient_delivery_errors [
    :busy,
    :delivery_unknown,
    :no_active_run,
    :persistence_unavailable,
    :queue_full,
    :run_in_progress,
    :sealed,
    :stale_run
  ]

  def ask_schedule_in_place(socket, text) do
    conv_id =
      socket.assigns[:schedule_target_conversation_id] || socket.assigns.current_conversation_id

    ws_id = socket.assigns[:schedule_target_workspace_id] || socket.assigns.current_workspace_id

    case switch_workspace_conversation(socket, ws_id, conv_id) do
      {:ok, socket} ->
        {:noreply, socket} =
          socket
          |> assign(:schedule_in_place, false)
          |> MessageSubmission.send_schedule_request(text)

        {:noreply, push_patch(socket, to: "/w/#{ws_id}/c/#{conv_id}")}

      {:error, socket} ->
        {:noreply, socket}
    end
  end

  def ask_schedule_in_new_conversation(socket, text) do
    case open_current_workspace_conversation(socket) do
      {:ok, socket, ws_id, conv_id} ->
        {:noreply, socket} =
          socket
          |> assign(:show_schedules, false)
          |> MessageSubmission.send_schedule_request(text)

        {:noreply, push_patch(socket, to: "/w/#{ws_id}/c/#{conv_id}")}

      {:error, socket} ->
        {:noreply, socket}
    end
  end

  def switch_schedule_workspace(socket, ws_id) when is_binary(ws_id) do
    if socket.assigns.current_workspace_id == ws_id do
      {:ok, socket}
    else
      case workspace_by_id(socket, ws_id) do
        %{"id" => ^ws_id} ->
          socket = drop_composer_for_switch(socket)
          socket = WorkspaceNavigation.expand_group(socket, ws_id)
          {socket, conv_id} = ConversationSwitching.select_workspace(socket, ws_id)

          {:ok,
           socket
           |> WorkspaceNavigation.after_switch()
           |> RuntimeProjection.subscribe_session()
           |> restore_session()
           |> WorkspaceNavigation.close_mobile_sheets()
           |> assign(:show_schedules, true)
           |> Schedules.reload()
           |> push_patch(to: "/w/#{ws_id}/c/#{conv_id}")}

        _missing ->
          {:error, assign(socket, :schedule_error, gettext("找不到工作区"))}
      end
    end
  end

  def switch_schedule_workspace(socket, _ws_id) do
    {:error, assign(socket, :schedule_error, gettext("找不到工作区"))}
  end

  defp open_current_workspace_conversation(socket) do
    ws_id = socket.assigns.current_workspace_id

    case workspace_by_id(socket, ws_id) do
      %{"id" => ^ws_id} ->
        socket = CliSelection.prepare_switch(socket)

        {socket, conv_id} =
          ConversationSwitching.new_conversation(socket, ws_id, ModelSelection.switching_opts())

        socket =
          socket
          |> attach_created_conversation(ws_id)
          |> WorkspaceNavigation.close_mobile_sheets()

        {:ok, socket, ws_id, conv_id}

      _missing ->
        {:error, assign(socket, :schedule_error, gettext("找不到工作区"))}
    end
  end

  defp workspace_by_id(socket, ws_id) when is_binary(ws_id) do
    Enum.find(socket.assigns.workspaces || [], &(&1["id"] == ws_id))
  end

  defp workspace_by_id(_socket, _ws_id), do: nil

  def begin_conversation_in_workspace(socket, ws_id, opts) do
    source = Keyword.get(opts, :source, :sidebar)

    socket =
      if Keyword.get(opts, :close_sheets?, false),
        do: WorkspaceNavigation.close_mobile_sheets(socket),
        else: socket

    socket =
      NewConversationDraft.open(socket,
        workspace_id: ws_id,
        source: source
      )

    {:noreply, socket}
  end

  def submit_new_conversation(socket, params) do
    case NewConversationDraft.prepare_submit(socket, params) do
      {:error, socket} ->
        {:noreply, socket}

      {:ok, socket, draft} ->
        socket = drop_composer_for_switch(socket)

        initialize_model = fn new_socket ->
          NewConversationDraft.apply_model_selection(new_socket, draft)
        end

        if NewConversationDraft.free_draft?(draft) do
          submit_free_conversation(socket, draft, initialize_model)
        else
          submit_workspace_conversation(socket, draft, initialize_model)
        end
    end
  end

  defp submit_workspace_conversation(socket, draft, initialize_model) do
    {socket, conv_id} =
      ConversationSwitching.new_conversation(socket, draft.workspace_id,
        checkout_path: draft.checkout_path,
        permission_mode: draft.permission_mode,
        selected_model: draft.model,
        selected_reasoning_level: draft.reasoning,
        initialize_model: initialize_model,
        model_display_name: &ModelSelection.model_display_name/2
      )

    socket =
      socket
      |> attach_created_conversation(draft.workspace_id, drop_composer?: false)
      |> assign(:new_conversation_draft, nil)
      |> assign(:input_value, "")
      |> assign(:permission_mode, draft.permission_mode)
      |> stage_pending_new_conversation_message(conv_id, draft)

    {:noreply, push_patch(socket, to: "/w/#{draft.workspace_id}/c/#{conv_id}")}
  end

  defp submit_free_conversation(socket, draft, initialize_model) do
    {socket, conv_id} =
      ConversationSwitching.new_free_conversation(socket,
        permission_mode: draft.permission_mode,
        selected_model: draft.model,
        selected_reasoning_level: draft.reasoning,
        initialize_model: initialize_model
      )

    socket =
      socket
      |> NewConversationDraft.close()
      |> WorkspaceNavigation.expand_group("free")
      |> WorkspaceNavigation.enter_free_chat()
      |> WorkspaceNavigation.after_switch()
      |> RuntimeProjection.subscribe_session()
      |> assign(:new_conversation_draft, nil)
      |> assign(:input_value, "")
      |> assign(:permission_mode, draft.permission_mode)
      |> stage_pending_new_conversation_message(conv_id, draft)

    {:noreply, push_patch(socket, to: "/c/#{conv_id}")}
  end

  defp attach_created_conversation(socket, ws_id, opts \\ []) do
    socket =
      if Keyword.get(opts, :drop_composer?, true),
        do: drop_composer_for_switch(socket),
        else: socket

    socket
    |> NewConversationDraft.close()
    |> WorkspaceNavigation.expand_group(ws_id)
    |> WorkspaceNavigation.after_switch()
    |> RuntimeProjection.subscribe_session()
  end

  def switch_workspace_conversation(socket, ws_id, conv_id)
      when is_binary(ws_id) and is_binary(conv_id) do
    socket = assign(socket, :show_schedules, false)

    if socket.assigns.current_workspace_id == ws_id and
         socket.assigns.current_conversation_id == conv_id do
      {:ok, socket}
    else
      with {:ok, %{"workspace_id" => ^ws_id}} <-
             Handbean.ConversationStore.get(conv_id, include_timeline?: false) do
        socket = drop_composer_for_switch(socket, conv_id)
        {socket, _conv_id} = ConversationSwitching.select_conversation(socket, ws_id, conv_id)

        {:ok,
         socket
         |> WorkspaceNavigation.after_switch()
         |> RuntimeProjection.subscribe_session()
         |> restore_session()
         |> WorkspaceNavigation.close_mobile_sheets()}
      else
        _ -> {:error, assign(socket, :schedule_error, gettext("找不到对话"))}
      end
    end
  end

  def switch_workspace_conversation(socket, _ws_id, _conv_id) do
    {:error, assign(socket, :schedule_error, gettext("找不到对话"))}
  end

  def navigate_after_delete(socket, nil), do: socket

  def navigate_after_delete(%{assigns: %{chat_scope: :free}} = socket, conversation_id) do
    socket
    |> WorkspaceNavigation.enter_free_chat()
    |> RuntimeProjection.subscribe_session()
    |> restore_session()
    |> WorkspaceNavigation.close_mobile_sheets()
    |> push_patch(to: "/c/#{conversation_id}")
  end

  def navigate_after_delete(socket, conversation_id) do
    workspace_id = socket.assigns.current_workspace_id

    socket
    |> WorkspaceNavigation.after_switch()
    |> RuntimeProjection.subscribe_session()
    |> restore_session()
    |> WorkspaceNavigation.close_mobile_sheets()
    |> push_patch(to: "/w/#{workspace_id}/c/#{conversation_id}")
  end

  def drop_composer_for_switch(socket, next_id \\ :new) do
    socket
    |> assign(:conversation_list_boot, nil)
    |> Composer.materialize_uploads()
    |> Composer.switch_conversation(next_id)
    |> CliSelection.prepare_switch()
  end

  def restore_session(socket) do
    socket
    |> RuntimeProjection.restore_active_session()
    |> CliSelection.restore_current()
    |> WorkspaceNavigation.finish_runtime()
  end

  def flush_pending_new_conversation_message(socket) do
    current_conversation_id = socket.assigns[:current_conversation_id]

    case pending_new_conversation_message(socket) do
      %{conversation_id: ^current_conversation_id} = pending ->
        with_pending_delivery_lock(socket, pending)

      _missing ->
        socket
    end
  end

  defp stage_pending_new_conversation_message(socket, conversation_id, draft) do
    request_id = "new-conversation-message-#{draft.id}"
    message_id = request_id
    dispatch_content = Skills.expand(draft.message, socket.assigns[:available_skills] || [])

    entry = %{
      "id" => message_id,
      "content_type" => "user_msg",
      "message_type" => "user",
      "role" => "user",
      "direction" => "inbound",
      "content" => draft.message,
      "dispatch_content" => dispatch_content,
      "delivery_status" => "pending",
      "request_id" => request_id,
      "source" => @pending_message_source,
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    case Handbean.ConversationTranscriptStore.append(conversation_id, entry) do
      {:ok, persisted} ->
        assign(
          socket,
          :pending_new_conversation_message,
          pending_from_entry(conversation_id, persisted)
        )

      {:error, reason} ->
        socket
        |> Composer.prefill_text(draft.message)
        |> assign(:pending_new_conversation_message, nil)
        |> assign(:composer_error, "Message not saved: #{inspect(reason)}")
    end
  end

  defp pending_new_conversation_message(socket) do
    socket.assigns[:pending_new_conversation_message] ||
      load_pending_new_conversation_message(socket.assigns[:current_conversation_id])
  end

  defp load_pending_new_conversation_message(conversation_id) when is_binary(conversation_id) do
    case Handbean.ConversationTranscriptStore.list(conversation_id) do
      {:ok, entries} ->
        entries
        |> Enum.reverse()
        |> Enum.find(&pending_new_conversation_entry?/1)
        |> then(&if(&1, do: pending_from_entry(conversation_id, &1)))

      {:error, _reason} ->
        nil
    end
  end

  defp load_pending_new_conversation_message(_conversation_id), do: nil

  defp pending_new_conversation_entry?(entry) do
    entry["source"] == @pending_message_source and entry["delivery_status"] == "pending" and
      is_binary(entry["request_id"])
  end

  defp pending_from_entry(conversation_id, entry) do
    %{
      conversation_id: conversation_id,
      message_id: entry["id"],
      request_id: entry["request_id"],
      message: entry["content"],
      dispatch_content: entry["dispatch_content"] || entry["content"]
    }
  end

  defp with_pending_delivery_lock(socket, pending) do
    lock =
      {{__MODULE__, :pending_new_conversation_delivery, pending.conversation_id,
        pending.request_id}, self()}

    case :global.trans(lock, fn -> reload_and_deliver_pending_message(socket, pending) end) do
      :aborted ->
        put_flash(socket, :error, gettext("Message delivery is still pending"))

      %Phoenix.LiveView.Socket{} = updated_socket ->
        updated_socket
    end
  end

  defp reload_and_deliver_pending_message(socket, pending) do
    case load_pending_new_conversation_message(pending.conversation_id) do
      %{request_id: request_id} = current when request_id == pending.request_id ->
        deliver_pending_new_conversation_message(socket, current)

      _already_settled_or_replaced ->
        assign(socket, :pending_new_conversation_message, nil)
    end
  end

  defp deliver_pending_new_conversation_message(socket, pending) do
    case pending_run_opts(socket, pending) do
      {:ok, opts} ->
        case Handbean.Agent.Coordinator.add_message(
               pending.conversation_id,
               pending.dispatch_content,
               opts
             ) do
          {:ok, _ack} -> accept_pending_new_conversation_message(socket, pending)
          {:error, reason} -> handle_pending_delivery_error(socket, pending, reason)
        end

      {:error, reason} ->
        handle_pending_delivery_error(socket, pending, reason)
    end
  end

  defp pending_run_opts(socket, pending) do
    workspace_path = ConversationState.current_workspace_path(socket)
    checkout_path = ConversationState.current_checkout_path(socket)

    with {:ok, built} <-
           Handbean.Agent.RunOpts.for_selection(
             workspace_path,
             socket.assigns.selected_model,
             socket.assigns.selected_reasoning_level,
             socket.assigns.effective_settings,
             checkout_path: checkout_path
           ) do
      base =
        if ConversationState.free_chat?(socket) do
          [
            chat_scope: :free,
            tools: Handbean.Agent.free_chat_tools(),
            workspace_id: nil,
            workspace_path: nil,
            mcp: false
          ]
        else
          [
            chat_scope: :workspace,
            tools: Handbean.Agent.default_tools(),
            workspace_id: socket.assigns.current_workspace_id,
            workspace_path: workspace_path,
            working_directory: checkout_path
          ]
        end

      {:ok,
       Keyword.merge(
         built,
         base ++
           [
             source: :live_view,
             streaming: true,
             persist_inbound?: false,
             transcript_id: pending.message_id,
             message_id: pending.message_id,
             inbound_id: pending.message_id,
             request_id: pending.request_id,
             user_time_zone: socket.assigns[:user_time_zone],
             origin: %{
               "kind" => @pending_message_source,
               "request_id" => pending.request_id
             }
           ]
       )}
    end
  end

  defp accept_pending_new_conversation_message(socket, pending) do
    case Handbean.ConversationTranscriptStore.update(
           pending.conversation_id,
           pending.message_id,
           %{"delivery_status" => "accepted"}
         ) do
      {:ok, _entry} ->
        send(self(), {:schedule_auto_title, pending.conversation_id, pending.message})

        socket
        |> assign(:pending_new_conversation_message, nil)
        |> assign(:composer_error, nil)
        |> RuntimeProjection.restore_active_session()
        |> push_event("user-message-sent", %{})

      {:error, reason} ->
        socket
        |> assign(:pending_new_conversation_message, pending)
        |> assign(
          :composer_error,
          "Message accepted; acknowledgment save failed: #{inspect(reason)}"
        )
    end
  end

  defp handle_pending_delivery_error(socket, pending, reason)
       when reason in @transient_delivery_errors do
    socket
    |> assign(:pending_new_conversation_message, pending)
    |> assign(:composer_error, "Message delivery pending: #{inspect(reason)}")
  end

  defp handle_pending_delivery_error(socket, pending, reason) do
    case Handbean.ConversationTranscriptStore.delete(pending.conversation_id, pending.message_id) do
      :ok ->
        socket
        |> assign(:pending_new_conversation_message, nil)
        |> RuntimeProjection.restore_active_session()
        |> Composer.prefill_text(pending.message)
        |> assign(:composer_error, "Message not delivered: #{inspect(reason)}")

      {:error, cleanup_reason} ->
        socket
        |> assign(:pending_new_conversation_message, pending)
        |> assign(
          :composer_error,
          "Message not delivered; cleanup pending: #{inspect(cleanup_reason)}"
        )
    end
  end
end
