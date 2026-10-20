defmodule HandbeanWeb.WorkspaceLive.ConversationRouting do
  @moduledoc false

  use HandbeanWeb, :html

  import Phoenix.LiveView

  alias HandbeanWeb.WorkspaceLive.CliSelection
  alias HandbeanWeb.WorkspaceLive.Composer
  alias HandbeanWeb.WorkspaceLive.ConversationSwitching
  alias HandbeanWeb.WorkspaceLive.MessageSubmission
  alias HandbeanWeb.WorkspaceLive.ModelSelection
  alias HandbeanWeb.WorkspaceLive.RuntimeProjection
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
    case open_default_workspace_conversation(socket) do
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

  defp open_default_workspace_conversation(socket) do
    case default_workspace(socket) do
      %{"id" => ws_id} = ws ->
        socket = CliSelection.prepare_switch(socket)

        {socket, conv_id} =
          ConversationSwitching.new_conversation(
            socket,
            ws_id,
            ModelSelection.switching_opts()
            |> Keyword.put(:checkout_path, ws["default_checkout_path"])
          )

        socket =
          socket
          |> attach_created_conversation(ws_id)
          |> WorkspaceNavigation.close_mobile_sheets()

        {:ok, socket, ws_id, conv_id}

      nil ->
        {:error, assign(socket, :schedule_error, gettext("找不到默认工作区"))}
    end
  end

  defp default_workspace(socket) do
    Enum.find(socket.assigns.workspaces || [], &(&1["default"] == true)) ||
      case Handbean.WorkspaceStore.ensure_default!() do
        {:ok, workspace} -> workspace
        {:error, _reason} -> nil
      end
  end

  def begin_conversation_in_workspace(socket, ws_id, opts) do
    close_sheets? = Keyword.get(opts, :close_sheets?, false)

    socket = CliSelection.prepare_switch(socket)

    case ConversationSwitching.begin_new_conversation(
           socket,
           ws_id,
           ModelSelection.switching_opts()
           |> Keyword.merge(Keyword.take(opts, [:checkout_path, :source]))
         ) do
      {:picker, socket} ->
        {:noreply, CliSelection.restore_current(socket)}

      {:created, socket, conv_id} ->
        socket = attach_created_conversation(socket, ws_id)

        socket =
          if close_sheets?,
            do: WorkspaceNavigation.close_mobile_sheets(socket),
            else: socket

        {:noreply, push_patch(socket, to: "/w/#{ws_id}/c/#{conv_id}")}
    end
  end

  defp attach_created_conversation(socket, ws_id) do
    socket
    |> drop_composer_for_switch()
    |> ConversationSwitching.close_checkout_picker()
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
end
