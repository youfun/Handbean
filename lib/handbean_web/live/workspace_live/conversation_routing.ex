defmodule HandbeanWeb.WorkspaceLive.ConversationRouting do
  @moduledoc false

  use HandbeanWeb, :html

  import Phoenix.LiveView

  alias HandbeanWeb.WorkspaceLive.CliSelection
  alias HandbeanWeb.WorkspaceLive.Composer
  alias HandbeanWeb.WorkspaceLive.ConversationSwitching
  alias HandbeanWeb.WorkspaceLive.MessageSubmission
  alias HandbeanWeb.WorkspaceLive.ModelSelection
  alias HandbeanWeb.WorkspaceLive.NewConversationDraft
  alias HandbeanWeb.WorkspaceLive.RuntimeProjection
  alias HandbeanWeb.WorkspaceLive.Schedules
  alias HandbeanWeb.WorkspaceLive.WorkspaceNavigation

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
      |> assign(:pending_new_conversation_message, draft.message)

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
      |> assign(:pending_new_conversation_message, draft.message)

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
    case socket.assigns[:pending_new_conversation_message] do
      message when is_binary(message) and message != "" ->
        socket = assign(socket, :pending_new_conversation_message, nil)
        {:noreply, socket} = MessageSubmission.send_conversation_message(socket, message)
        socket

      _missing ->
        socket
    end
  end
end
