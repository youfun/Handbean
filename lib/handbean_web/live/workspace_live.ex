defmodule HandbeanWeb.WorkspaceLive do
  @moduledoc """
  Main workspace LiveView — three-column layout with workspace/project sidebar.

  Layout:
  ┌──────────┬───────────────────┬───────────────────┐
  │ Projects │   Chat / AI Panel │   Workspace       │
  │ (Left)   │   (Center)        │   (Right)         │
  └──────────┴───────────────────┴───────────────────┘
                 StatusBar (bottom)

  Left sidebar shows workspaces (projects) with conversations grouped
  underneath. Each conversation is bound to a workspace, and the Agent
  working_directory is always the current conversation's workspace path.
  """

  use HandbeanWeb, :live_view

  require Logger

  alias HandbeanWeb.WorkspaceLive.Approval
  alias HandbeanWeb.WorkspaceLive.Composer
  alias HandbeanWeb.WorkspaceLive.ConversationSwitching
  alias HandbeanWeb.WorkspaceLive.{CliSelection, ModelSelection}
  alias HandbeanWeb.WorkspaceLive.RuntimeProjection
  alias HandbeanWeb.WorkspaceLive.Skills
  alias HandbeanWeb.WorkspaceLive.ChatComponents
  alias HandbeanWeb.WorkspaceLive.OverlayComponents
  alias HandbeanWeb.WorkspaceLive.SidebarComponents
  alias HandbeanWeb.WorkspaceLive.ViewComponents
  alias HandbeanWeb.WorkspaceLive.WorkspaceComponents
  alias HandbeanWeb.WorkspaceLive.WorkspaceNavigation
  alias HandbeanWeb.WorkspaceLive.SessionMemory

  import SidebarComponents,
    only: [mobile_header: 1, projects_sidebar: 1, checkout_picker_dialog: 1]

  import ChatComponents, only: [chat_panel: 1]
  import WorkspaceComponents, only: [workspace_panel: 1]

  import OverlayComponents,
    only: [
      mobile_sheets: 1,
      delete_conversation_dialog: 1,
      approval_overlay: 1,
      status_bar: 1
    ]

  alias HandbeanWeb.WorkspaceLive.Bootstrap
  alias HandbeanWeb.WorkspaceLive.ConversationEvents
  alias HandbeanWeb.WorkspaceLive.ConversationRouting
  alias HandbeanWeb.WorkspaceLive.InfoEvents
  alias HandbeanWeb.WorkspaceLive.InputEvents
  alias HandbeanWeb.WorkspaceLive.ScheduleEvents

  @impl true
  def mount(params, _session, socket), do: Bootstrap.mount(params, socket, &handle_progress/3)

  @impl true
  def handle_async(:conversation_list, {:ok, {revision, result}}, socket) do
    if revision != socket.assigns.conversation_list_revision do
      {:noreply, ConversationSwitching.load_conversation_list(socket)}
    else
      case result do
        {:ok, conversations} ->
          Bootstrap.log_workspace_boot(
            socket.assigns.current_workspace_id,
            socket.assigns.workspaces,
            conversations
          )

          socket =
            socket
            |> assign(:conversations_by_workspace, conversations)
            |> assign(:conversation_list_loading, false)
            |> assign(:conversation_list_loaded, true)
            |> assign(:conversation_list_error, nil)
            |> stream_conversations(conversations, socket.assigns.workspaces)
            |> finish_conversation_list_boot()

          {:noreply, socket}

        {:error, reason} ->
          {:noreply, conversation_list_failed(socket, reason)}
      end
    end
  end

  def handle_async(:conversation_list, {:exit, reason}, socket) do
    if socket.assigns.conversation_list_task_revision !=
         socket.assigns.conversation_list_revision do
      {:noreply, ConversationSwitching.load_conversation_list(socket)}
    else
      {:noreply, conversation_list_failed(socket, reason)}
    end
  end

  def handle_async({:cli_models, cli, revision}, {:ok, result}, socket) do
    {:noreply, CliSelection.finish_model_load(socket, cli, revision, result)}
  end

  def handle_async({:cli_models, cli, revision}, {:exit, reason}, socket) do
    {:noreply, CliSelection.finish_model_load(socket, cli, revision, {:error, {:exit, reason}})}
  end

  def handle_async(
        {:speech_transcription, request_id},
        {:ok, {request, {:ok, transcription}}},
        socket
      ) do
    cond do
      not current_speech_request?(socket, request_id, request) ->
        {:noreply, socket}

      transcription == "" ->
        {:noreply, speech_failed(socket, gettext("No speech was detected."))}

      true ->
        value = Handbean.Speech.append_to_draft(socket.assigns.input_value, transcription)

        {:noreply,
         socket
         |> assign(:input_value, value)
         |> assign(:skill_suggestions, Skills.suggestions(value, socket.assigns.available_skills))
         |> assign(:speech_request, nil)
         |> assign(:speech_state, :ready)
         |> push_event("speech-transcription", %{value: value})}
    end
  end

  def handle_async(
        {:speech_transcription, request_id},
        {:ok, {request, {:error, reason}}},
        socket
      ) do
    if current_speech_request?(socket, request_id, request) do
      Logger.warning("[WorkspaceLive] speech transcription failed: #{inspect(reason)}")
      {:noreply, speech_failed(socket, transcription_error_message(reason))}
    else
      {:noreply, socket}
    end
  end

  def handle_async({:speech_transcription, request_id}, {:exit, reason}, socket) do
    if socket.assigns.speech_request && socket.assigns.speech_request.id == request_id do
      Logger.warning("[WorkspaceLive] speech transcription task exited: #{inspect(reason)}")
      {:noreply, speech_failed(socket, gettext("Voice transcription failed. Please try again."))}
    else
      {:noreply, socket}
    end
  end

  defp conversation_list_failed(socket, reason) do
    Logger.warning("Conversation list failed to load: #{inspect(reason)}")

    socket
    |> assign(:conversation_list_loading, false)
    |> assign(:conversation_list_error, "Could not load conversations.")
  end

  defp finish_conversation_list_boot(socket) do
    boot = socket.assigns.conversation_list_boot
    socket = assign(socket, :conversation_list_boot, nil)

    if boot && is_nil(boot.conversation_id) &&
         is_nil(socket.assigns.current_conversation_id) &&
         socket.assigns.chat_scope == boot.chat_scope &&
         socket.assigns.current_workspace_id == boot.workspace_id do
      key = if boot.chat_scope == :free, do: :free, else: boot.workspace_id
      id = initial_conversation_id(socket.assigns.conversations_by_workspace, key)

      if id do
        {socket, _id} =
          if boot.chat_scope == :free do
            ConversationSwitching.select_free_conversation(socket, id)
          else
            ConversationSwitching.select_conversation(socket, boot.workspace_id, id)
          end

        socket =
          if boot.chat_scope == :free,
            do: WorkspaceNavigation.enter_free_chat(socket),
            else: WorkspaceNavigation.after_switch(socket)

        socket
        |> RuntimeProjection.subscribe_session()
        |> ConversationRouting.restore_session()
        |> SessionMemory.remember()
      else
        socket
      end
    else
      socket
    end
  end

  @impl true
  def handle_params(_params, _uri, %{assigns: %{workspace_boot_error: _reason}} = socket),
    do: {:noreply, socket}

  def handle_params(
        %{"conversation_id" => conv_id},
        _uri,
        %{assigns: %{live_action: :free}} = socket
      ) do
    with {:ok, conv} <- Handbean.ConversationStore.get(conv_id, include_timeline?: false),
         true <- Handbean.ConversationStore.free?(conv) do
      socket =
        if socket.assigns.current_conversation_id == conv_id and
             socket.assigns.chat_scope == :free do
          socket
        else
          socket = ConversationRouting.drop_composer_for_switch(socket, conv_id)
          {socket, _conv_id} = ConversationSwitching.select_free_conversation(socket, conv_id)

          socket
          |> WorkspaceNavigation.enter_free_chat()
          |> RuntimeProjection.subscribe_session()
          |> ConversationRouting.restore_session()
          |> WorkspaceNavigation.close_mobile_sheets()
        end

      {:noreply, socket}
    else
      _ -> {:noreply, push_patch(socket, to: "/")}
    end
  end

  def handle_params(
        %{"workspace_id" => ws_id, "conversation_id" => conv_id} = _params,
        _uri,
        socket
      ) do
    if socket.assigns.current_workspace_id != ws_id or
         socket.assigns.current_conversation_id != conv_id do
      with {:ok, ws} <- Handbean.WorkspaceStore.get(ws_id),
           {:ok, conv} <- Handbean.ConversationStore.get(conv_id, include_timeline?: false),
           true <- conv["workspace_id"] == ws_id do
        socket = ConversationRouting.drop_composer_for_switch(socket, conv_id)
        {socket, _conv_id} = ConversationSwitching.select_conversation(socket, ws_id, conv_id)

        socket =
          socket
          |> assign(:workspace_label, ws["name"])
          |> WorkspaceNavigation.after_switch()
          |> RuntimeProjection.subscribe_session()
          |> ConversationRouting.restore_session()
          |> WorkspaceNavigation.close_mobile_sheets()

        {:noreply, socket}
      else
        _ -> {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  def handle_progress(:speech_audio, entry, socket) do
    errors = upload_errors(socket.assigns.uploads.speech_audio, entry)

    cond do
      errors != [] ->
        message =
          if :too_large in errors,
            do: gettext("Voice recording is too long. The limit is 60 seconds."),
            else: gettext("Could not read the voice recording.")

        {:noreply,
         socket
         |> cancel_upload(:speech_audio, entry.ref)
         |> assign(:speech_state, :ready)
         |> assign(:composer_error, message)
         |> push_event("speech-transcription-failed", %{})}

      entry.done? and not socket.assigns.speech_available? ->
        _dropped =
          consume_uploaded_entry(socket, entry, fn _meta ->
            {:ok, :dropped}
          end)

        {:noreply, assign(socket, :speech_state, :unavailable)}

      entry.done? ->
        pcm =
          consume_uploaded_entry(socket, entry, fn %{path: path} ->
            {:ok, File.read!(path)}
          end)

        request = %{
          id: Ecto.UUID.generate(),
          conversation_id: socket.assigns.current_conversation_id,
          revision: socket.assigns.speech_revision
        }

        socket =
          socket
          |> assign(:speech_request, request)
          |> assign(:speech_state, :processing)
          |> assign(:composer_error, nil)
          |> start_async({:speech_transcription, request.id}, fn ->
            {request, Handbean.Speech.transcribe(pcm, language: "auto")}
          end)

        {:noreply, socket}

      true ->
        {:noreply, socket}
    end
  end

  def handle_progress(:images, entry, socket) do
    errors =
      entry.errors
      |> Enum.map(&Composer.upload_error/1)
      |> Enum.reject(&(&1 in [nil, ""]))

    socket =
      if errors != [] do
        assign(socket, :composer_error, Enum.join(errors, "; "))
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("remove_attachment", params, socket),
    do: InputEvents.handle("remove_attachment", params, socket)

  def handle_event("cancel_upload", params, socket),
    do: InputEvents.handle("cancel_upload", params, socket)

  def handle_event("clear_composer_error", params, socket),
    do: InputEvents.handle("clear_composer_error", params, socket)

  def handle_event("toggle_skills_panel", params, socket),
    do: InputEvents.handle("toggle_skills_panel", params, socket)

  def handle_event("launch_skill", params, socket),
    do: InputEvents.handle("launch_skill", params, socket)

  def handle_event("composer_drop", params, socket),
    do: InputEvents.handle("composer_drop", params, socket)

  def handle_event("send_message", params, socket),
    do: InputEvents.handle("send_message", params, socket)

  def handle_event("steer_message", params, socket),
    do: InputEvents.handle("steer_message", params, socket)

  def handle_event("queue_message", params, socket),
    do: InputEvents.handle("queue_message", params, socket)

  def handle_event("send_pending_now", params, socket),
    do: InputEvents.handle("send_pending_now", params, socket)

  def handle_event("cancel_pending", params, socket),
    do: InputEvents.handle("cancel_pending", params, socket)

  def handle_event("resend_pending", params, socket),
    do: InputEvents.handle("resend_pending", params, socket)

  def handle_event("delete_undelivered", params, socket),
    do: InputEvents.handle("delete_undelivered", params, socket)

  def handle_event("speech_error", params, socket),
    do: InputEvents.handle("speech_error", params, socket)

  def handle_event("update_input", params, socket),
    do: InputEvents.handle("update_input", params, socket)

  def handle_event("prefill_subagent_follow_up", params, socket),
    do: InputEvents.handle("prefill_subagent_follow_up", params, socket)

  def handle_event("widget_command", params, socket),
    do: InputEvents.handle("widget_command", params, socket)

  def handle_event("select_skill_suggestion", params, socket),
    do: InputEvents.handle("select_skill_suggestion", params, socket)

  def handle_event("dismiss_skill_suggestions", params, socket),
    do: InputEvents.handle("dismiss_skill_suggestions", params, socket)

  def handle_event("stop_run", params, socket),
    do: InputEvents.handle("stop_run", params, socket)

  def handle_event("approve_cli_option", params, socket),
    do: InputEvents.handle("approve_cli_option", params, socket)

  def handle_event("approve_all_tools", params, socket),
    do: InputEvents.handle("approve_all_tools", params, socket)

  def handle_event("deny_all_tools", params, socket),
    do: InputEvents.handle("deny_all_tools", params, socket)

  def handle_event("select_cli", params, socket),
    do: InputEvents.handle("select_cli", params, socket)

  def handle_event("select_model", params, socket),
    do: InputEvents.handle("select_model", params, socket)

  def handle_event("select_reasoning", params, socket),
    do: InputEvents.handle("select_reasoning", params, socket)

  def handle_event("refresh_models", params, socket),
    do: InputEvents.handle("refresh_models", params, socket)

  def handle_event("select_file", params, socket),
    do: InputEvents.handle("select_file", params, socket)

  def handle_event("select_workspace_file", params, socket),
    do: InputEvents.handle("select_workspace_file", params, socket)

  def handle_event("toggle_workspace_directory", params, socket),
    do: InputEvents.handle("toggle_workspace_directory", params, socket)

  def handle_event("select_editor_file", params, socket),
    do: InputEvents.handle("select_editor_file", params, socket)

  def handle_event("close_editor_file", params, socket),
    do: InputEvents.handle("close_editor_file", params, socket)

  def handle_event("reveal_in_file_manager", params, socket),
    do: InputEvents.handle("reveal_in_file_manager", params, socket)

  def handle_event("select_right_panel_view", params, socket),
    do: InputEvents.handle("select_right_panel_view", params, socket)

  def handle_event("select_mobile_right_panel_view", params, socket),
    do: InputEvents.handle("select_mobile_right_panel_view", params, socket)

  def handle_event("close_mobile_right_panel", params, socket),
    do: InputEvents.handle("close_mobile_right_panel", params, socket)

  def handle_event("open_file_change", params, socket),
    do: InputEvents.handle("open_file_change", params, socket)

  def handle_event("toggle_file_change", params, socket),
    do: InputEvents.handle("toggle_file_change", params, socket)

  def handle_event("confirm_revert_change", params, socket),
    do: InputEvents.handle("confirm_revert_change", params, socket)

  def handle_event("cancel_revert_change", params, socket),
    do: InputEvents.handle("cancel_revert_change", params, socket)

  def handle_event("revert_change", params, socket),
    do: InputEvents.handle("revert_change", params, socket)

  def handle_event("open_preview", params, socket),
    do: InputEvents.handle("open_preview", params, socket)

  def handle_event("open_preview_external", params, socket),
    do: InputEvents.handle("open_preview_external", params, socket)

  def handle_event("takeover_browser", params, socket),
    do: InputEvents.handle("takeover_browser", params, socket)

  def handle_event("toggle_terminal", params, socket),
    do: InputEvents.handle("toggle_terminal", params, socket)

  def handle_event("open_add_project", params, socket),
    do: ConversationEvents.handle("open_add_project", params, socket)

  def handle_event("cancel_add_project", params, socket),
    do: ConversationEvents.handle("cancel_add_project", params, socket)

  def handle_event("update_add_path", params, socket),
    do: ConversationEvents.handle("update_add_path", params, socket)

  def handle_event("update_add_name", params, socket),
    do: ConversationEvents.handle("update_add_name", params, socket)

  def handle_event("toggle_add_project_memory", params, socket),
    do: ConversationEvents.handle("toggle_add_project_memory", params, socket)

  def handle_event("confirm_add_project", params, socket),
    do: ConversationEvents.handle("confirm_add_project", params, socket)

  def handle_event("browse_folder", params, socket),
    do: ConversationEvents.handle("browse_folder", params, socket)

  def handle_event("select_workspace", params, socket),
    do: ConversationEvents.handle("select_workspace", params, socket)

  def handle_event("load_older_history", params, socket),
    do: ConversationEvents.handle("load_older_history", params, socket)

  def handle_event("select_conversation", params, socket),
    do: ConversationEvents.handle("select_conversation", params, socket)

  def handle_event("select_archived_conversation", params, socket),
    do: ConversationEvents.handle("select_archived_conversation", params, socket)

  def handle_event("toggle_conversation_menu", params, socket),
    do: ConversationEvents.handle("toggle_conversation_menu", params, socket)

  def handle_event("open_conversation_context_menu", params, socket),
    do: ConversationEvents.handle("open_conversation_context_menu", params, socket)

  def handle_event("close_conversation_menu", params, socket),
    do: ConversationEvents.handle("close_conversation_menu", params, socket)

  def handle_event("toggle_pin_conversation", params, socket),
    do: ConversationEvents.handle("toggle_pin_conversation", params, socket)

  def handle_event("open_rename_conversation", params, socket),
    do: ConversationEvents.handle("open_rename_conversation", params, socket)

  def handle_event("cancel_rename_conversation", params, socket),
    do: ConversationEvents.handle("cancel_rename_conversation", params, socket)

  def handle_event("open_delete_conversation", params, socket),
    do: ConversationEvents.handle("open_delete_conversation", params, socket)

  def handle_event("cancel_delete_conversation", params, socket),
    do: ConversationEvents.handle("cancel_delete_conversation", params, socket)

  def handle_event("confirm_delete_conversation", params, socket),
    do: ConversationEvents.handle("confirm_delete_conversation", params, socket)

  def handle_event("confirm_rename_conversation", params, socket),
    do: ConversationEvents.handle("confirm_rename_conversation", params, socket)

  def handle_event("archive_conversation", params, socket),
    do: ConversationEvents.handle("archive_conversation", params, socket)

  def handle_event("unarchive_conversation", params, socket),
    do: ConversationEvents.handle("unarchive_conversation", params, socket)

  def handle_event("toggle_archive", params, socket),
    do: ConversationEvents.handle("toggle_archive", params, socket)

  def handle_event("toggle_workspace_group", params, socket),
    do: ConversationEvents.handle("toggle_workspace_group", params, socket)

  def handle_event("toggle_thread", params, socket),
    do: ConversationEvents.handle("toggle_thread", params, socket)

  def handle_event("show_more_conversations", params, socket),
    do: ConversationEvents.handle("show_more_conversations", params, socket)

  def handle_event("open_rename_workspace", params, socket),
    do: ConversationEvents.handle("open_rename_workspace", params, socket)

  def handle_event("cancel_rename_workspace", params, socket),
    do: ConversationEvents.handle("cancel_rename_workspace", params, socket)

  def handle_event("confirm_rename_workspace", params, socket),
    do: ConversationEvents.handle("confirm_rename_workspace", params, socket)

  def handle_event("open_remove_workspace", params, socket),
    do: ConversationEvents.handle("open_remove_workspace", params, socket)

  def handle_event("cancel_remove_workspace", params, socket),
    do: ConversationEvents.handle("cancel_remove_workspace", params, socket)

  def handle_event("confirm_remove_workspace", params, socket),
    do: ConversationEvents.handle("confirm_remove_workspace", params, socket)

  def handle_event("retry_conversation_list", params, socket),
    do: ConversationEvents.handle("retry_conversation_list", params, socket)

  def handle_event("new_conversation", params, socket),
    do: ConversationEvents.handle("new_conversation", params, socket)

  def handle_event("toggle_new_conversation_picker", params, socket),
    do: ConversationEvents.handle("toggle_new_conversation_picker", params, socket)

  def handle_event("new_free_conversation", params, socket),
    do: ConversationEvents.handle("new_free_conversation", params, socket)

  def handle_event("select_free_conversation", params, socket),
    do: ConversationEvents.handle("select_free_conversation", params, socket)

  def handle_event("new_conversation_in_workspace", params, socket),
    do: ConversationEvents.handle("new_conversation_in_workspace", params, socket)

  def handle_event("mobile_new_conversation_in_workspace", params, socket),
    do: ConversationEvents.handle("mobile_new_conversation_in_workspace", params, socket)

  def handle_event("new_conversation_on_checkout", params, socket),
    do: ConversationEvents.handle("new_conversation_on_checkout", params, socket)

  def handle_event("close_checkout_picker", params, socket),
    do: ConversationEvents.handle("close_checkout_picker", params, socket)

  def handle_event("open_settings", params, socket),
    do: ConversationEvents.handle("open_settings", params, socket)

  def handle_event("open_sheet", params, socket),
    do: ConversationEvents.handle("open_sheet", params, socket)

  def handle_event("close_sheets", params, socket),
    do: ConversationEvents.handle("close_sheets", params, socket)

  def handle_event("select_model_from_sheet", params, socket),
    do: ConversationEvents.handle("select_model_from_sheet", params, socket)

  def handle_event("select_reasoning_from_sheet", params, socket),
    do: ConversationEvents.handle("select_reasoning_from_sheet", params, socket)

  def handle_event("toggle_file_drawer", params, socket),
    do: ConversationEvents.handle("toggle_file_drawer", params, socket)

  def handle_event("toggle_right_panel", params, socket),
    do: ConversationEvents.handle("toggle_right_panel", params, socket)

  def handle_event("set_right_panel_collapsed", params, socket),
    do: ConversationEvents.handle("set_right_panel_collapsed", params, socket)

  def handle_event("toggle_tool_work", params, socket),
    do: ConversationEvents.handle("toggle_tool_work", params, socket)

  def handle_event("toggle_permission_menu", params, socket),
    do: ConversationEvents.handle("toggle_permission_menu", params, socket)

  def handle_event("select_permission_mode", params, socket),
    do: ConversationEvents.handle("select_permission_mode", params, socket)

  def handle_event("scroll_to_bottom", params, socket),
    do: ConversationEvents.handle("scroll_to_bottom", params, socket)

  def handle_event("toggle_schedules", params, socket),
    do: ScheduleEvents.handle("toggle_schedules", params, socket)

  def handle_event("schedule_request", params, socket),
    do: ScheduleEvents.handle("schedule_request", params, socket)

  def handle_event("schedule_ask", params, socket),
    do: ScheduleEvents.handle("schedule_ask", params, socket)

  def handle_event("schedule_select", params, socket),
    do: ScheduleEvents.handle("schedule_select", params, socket)

  def handle_event("schedule_filter", params, socket),
    do: ScheduleEvents.handle("schedule_filter", params, socket)

  def handle_event("schedule_search", params, socket),
    do: ScheduleEvents.handle("schedule_search", params, socket)

  def handle_event("schedule_close_detail", params, socket),
    do: ScheduleEvents.handle("schedule_close_detail", params, socket)

  def handle_event("schedule_instruction_toggle", params, socket),
    do: ScheduleEvents.handle("schedule_instruction_toggle", params, socket)

  def handle_event("schedule_pause", params, socket),
    do: ScheduleEvents.handle("schedule_pause", params, socket)

  def handle_event("schedule_resume", params, socket),
    do: ScheduleEvents.handle("schedule_resume", params, socket)

  def handle_event("schedule_delete", params, socket),
    do: ScheduleEvents.handle("schedule_delete", params, socket)

  def handle_event("schedule_run_now", params, socket),
    do: ScheduleEvents.handle("schedule_run_now", params, socket)

  def handle_event("schedule_revise", params, socket),
    do: ScheduleEvents.handle("schedule_revise", params, socket)

  def handle_event("open_schedule_conversation", params, socket),
    do: ScheduleEvents.handle("open_schedule_conversation", params, socket)

  # ── Agent events ──

  @impl true
  def handle_info({:file_browser_closed} = message, socket),
    do: InfoEvents.handle(message, socket)

  def handle_info({:folder_selected_from_browser, _} = message, socket),
    do: InfoEvents.handle(message, socket)

  def handle_info({:workspace_imported, _} = message, socket),
    do: InfoEvents.handle(message, socket)

  def handle_info({:conversation_permission_mode_changed, _, _, _, _} = message, socket),
    do: InfoEvents.handle(message, socket)

  def handle_info({:conversation_permission_mode_changed, _, _, _} = message, socket),
    do: InfoEvents.handle(message, socket)

  def handle_info({:workspace_permission_policy_changed, _} = message, socket),
    do: InfoEvents.handle(message, socket)

  def handle_info({:speech_enabled, _} = message, socket), do: InfoEvents.handle(message, socket)
  def handle_info({:speech_status, _} = message, socket), do: InfoEvents.handle(message, socket)
  def handle_info({:agent_event, _} = message, socket), do: InfoEvents.handle(message, socket)

  def handle_info(%Handbean.PubSub.AgentEvent{} = message, socket),
    do: InfoEvents.handle(message, socket)

  def handle_info({:runtime_tasks, _} = message, socket), do: InfoEvents.handle(message, socket)
  def handle_info({:in_app_ended, _, _} = message, socket), do: InfoEvents.handle(message, socket)

  def handle_info({:conversations_pending_delete, _} = message, socket),
    do: InfoEvents.handle(message, socket)

  def handle_info({:conversation_updated, _} = message, socket),
    do: InfoEvents.handle(message, socket)

  def handle_info({:conversation_title_ready, _, _} = message, socket),
    do: InfoEvents.handle(message, socket)

  def handle_info({:schedule_auto_title, _, _} = message, socket),
    do: InfoEvents.handle(message, socket)

  def handle_info({:conversation_handoffs, _} = message, socket),
    do: InfoEvents.handle(message, socket)

  def handle_info({:terminal_ready, _, _, _} = message, socket),
    do: InfoEvents.handle(message, socket)

  def handle_info({:terminal_refresh, _, _, _} = message, socket),
    do: InfoEvents.handle(message, socket)

  def handle_info({:terminal_refresh, _, _} = message, socket),
    do: InfoEvents.handle(message, socket)

  def handle_info({:terminal_exited, _, _, _, _} = message, socket),
    do: InfoEvents.handle(message, socket)

  def handle_info({:terminal_exited, _, _, _} = message, socket),
    do: InfoEvents.handle(message, socket)

  def handle_info({:ext_ui, _} = message, socket), do: InfoEvents.handle(message, socket)

  def handle_info({:schedule_changed, _} = message, socket),
    do: InfoEvents.handle(message, socket)

  def handle_info({:schedule_notice, _, _} = message, socket),
    do: InfoEvents.handle(message, socket)

  def handle_info({:arm_browser_capture, _} = message, socket),
    do: InfoEvents.handle(message, socket)

  def handle_info({:browser_surface_state, _, _} = message, socket),
    do: InfoEvents.handle(message, socket)

  def handle_info({:browser_markers, _, _} = message, socket),
    do: InfoEvents.handle(message, socket)

  def handle_info({:browser_frame, _, _} = message, socket),
    do: InfoEvents.handle(message, socket)

  def handle_info({:browser_annotation_ready, _, _, _, _} = message, socket),
    do: InfoEvents.handle(message, socket)

  def handle_info(message, socket), do: InfoEvents.handle(message, socket)

  # ── Tool event helpers ──

  # `@<subagent_type or child id> text` goes to a subagent of this conversation.
  # Anything else, including `@path` mentions, stays a normal message.

  defdelegate attachment_url(attachment), to: Composer
  defdelegate attachment_filename(attachment), to: Composer
  defdelegate image_attachment?(attachment), to: Composer

  # ── Status helpers ──

  # ── Conversation token helpers ──

  # ── <think> tag stripping ──────────────────────────────────────────

  # ── Model resolution ──

  # Reload workspace models when switching workspaces.
  # Preserves the current selected_model only if still allowed in the new workspace.

  # Resolve a composite model id to a human-readable display name.

  # Same display names stay distinguishable. Cursor stores one name for a base
  # model and its fast variant; the id is what actually differs.

  # ── /model command parser ──

  defp current_speech_request?(socket, request_id, request) do
    current = socket.assigns.speech_request

    not is_nil(current) and current.id == request_id and request.id == request_id and
      request.conversation_id == socket.assigns.current_conversation_id and
      request.revision == socket.assigns.speech_revision
  end

  defp speech_failed(socket, message) do
    socket
    |> assign(:speech_request, nil)
    |> assign(:speech_state, :ready)
    |> assign(:composer_error, message)
    |> push_event("speech-transcription-failed", %{})
  end

  defp transcription_error_message(:too_short),
    do: gettext("Record a little longer and try again.")

  defp transcription_error_message(:too_long),
    do: gettext("Voice recording is too long. The limit is 60 seconds.")

  defp transcription_error_message(:unavailable),
    do: gettext("Local voice transcription is unavailable on this device.")

  defp transcription_error_message(_reason),
    do: gettext("Voice transcription failed. Please try again.")

  # ── PubSub subscription ──

  # The native host (if any) owns the picker; a missing host is a no-op.

  # ── Conversation construction ──

  def archived_conversations(workspaces, conversations_by_workspace),
    do: ConversationSwitching.archived_conversations(workspaces, conversations_by_workspace)

  def free_conversations(conversations_by_workspace),
    do: ConversationSwitching.free_conversations(conversations_by_workspace)

  def workspace_conversations(conversations_by_workspace, ws_id, workspaces),
    do:
      ConversationSwitching.workspace_conversations(conversations_by_workspace, ws_id, workspaces)

  def workspace_group_collapsed?(collapsed, id) when is_struct(collapsed, MapSet) do
    MapSet.member?(collapsed, to_string(id))
  end

  def workspace_group_collapsed?(_, _), do: false

  def active_conversation_count(conversations_by_workspace, ws_id, workspaces) do
    conversations_by_workspace
    |> workspace_conversations(ws_id, workspaces)
    |> length()
  end

  def free_conversation_count(conversations_by_workspace) do
    conversations_by_workspace
    |> free_conversations()
    |> length()
  end

  def scoped_conversation_count(conversations_by_workspace, :free, _ws_id, _workspaces) do
    free_conversation_count(conversations_by_workspace)
  end

  def scoped_conversation_count(conversations_by_workspace, _scope, ws_id, workspaces) do
    active_conversation_count(conversations_by_workspace, ws_id, workspaces)
  end

  # ── Mobile helpers ──

  # ── Helpers for mobile bottom sheets ──

  # ── Mobile sheet helpers ──

  # ── Public helpers for templates (delegated to HandbeanWeb.WorkspaceHelper) ──

  defdelegate status_dot_class(status), to: HandbeanWeb.WorkspaceHelper
  defdelegate tool_status_icon(status), to: HandbeanWeb.WorkspaceHelper
  defdelegate tool_status_class(status), to: HandbeanWeb.WorkspaceHelper
  defdelegate tool_border_class(status), to: HandbeanWeb.WorkspaceHelper
  defdelegate render_tool_status(status), to: HandbeanWeb.WorkspaceHelper
  defdelegate tool_entry_count(entries), to: HandbeanWeb.WorkspaceHelper
  defdelegate timeline_summary(entries), to: HandbeanWeb.WorkspaceHelper
  defdelegate user_message_nav_items(entries), to: HandbeanWeb.WorkspaceHelper
  defdelegate format_duration(ms), to: HandbeanWeb.WorkspaceHelper
  defdelegate format_bytes(bytes), to: HandbeanWeb.WorkspaceHelper
  defdelegate format_tokens(tokens), to: HandbeanWeb.WorkspaceHelper
  defdelegate format_cache_hit_rate(status), to: HandbeanWeb.WorkspaceHelper
  defdelegate diff_prefix(type), to: HandbeanWeb.WorkspaceHelper
  defdelegate file_value(file, key, default), to: HandbeanWeb.WorkspaceHelper
  defdelegate archived_stream_count(entries), to: HandbeanWeb.WorkspaceHelper
  defdelegate browser_install_prompt(entry), to: HandbeanWeb.WorkspaceHelper
  defdelegate preview_card(entry), to: HandbeanWeb.WorkspaceHelper
  defdelegate browser_takeover_prompt(entry), to: HandbeanWeb.WorkspaceHelper
  defdelegate tool_entry_name(entry), to: Handbean.TranscriptEntry, as: :tool_name
  defdelegate tool_entry_status(entry), to: Handbean.TranscriptEntry, as: :tool_status
  defdelegate tool_entry_duration(entry), to: Handbean.TranscriptEntry, as: :duration_ms
  defdelegate tool_entry_error(entry), to: Handbean.TranscriptEntry, as: :error
  defdelegate tool_entry_input_summary(entry), to: Handbean.TranscriptEntry, as: :input_summary

  defdelegate render_file_preview(path, workspace_root \\ Handbean.Workspace.root()),
    to: HandbeanWeb.WorkspaceHelper

  # ── Tool approval helpers ──

  defdelegate approval_action_requests(pending), to: Approval, as: :action_requests
  defdelegate format_arguments(arguments), to: Approval

  # ── Conversation stream helpers ──

  # ── Settings helpers ──

  defdelegate model_option_label(model, models \\ []), to: ModelSelection
  defdelegate parse_model_command(message), to: ModelSelection
  defdelegate strip_think_tags(buffer, chunk), to: Handbean.Agent.ThinkingFilter, as: :strip
  defdelegate has_cache_tokens?(status), to: ViewComponents
  defdelegate reasoning_label(level), to: ViewComponents
  defdelegate relative_time(conv), to: ViewComponents

  defdelegate any_sheet_open?(show_workspace, show_model, show_reasoning, show_settings),
    to: ViewComponents

  defdelegate settings_href(workspace_id, conversation_id), to: ViewComponents
  defdelegate permission_label(mode), to: ViewComponents
  def handle_workspace_switch(socket), do: WorkspaceNavigation.after_switch(socket)

  defp initial_conversation_id(conversations_by_ws, ws_id),
    do: ConversationSwitching.initial_conversation_id(conversations_by_ws, ws_id)

  defp stream_conversations(socket, conversations_by_ws, workspaces),
    do: ConversationSwitching.stream_conversations(socket, conversations_by_ws, workspaces)
end
