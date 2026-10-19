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
  alias HandbeanWeb.WorkspaceLive.ConversationState
  alias HandbeanWeb.WorkspaceLive.ConversationSwitching
  alias HandbeanWeb.WorkspaceLive.EditorProjection
  alias HandbeanWeb.WorkspaceLive.MessageSubmission
  alias HandbeanWeb.WorkspaceLive.{CliSelection, ModelSelection}
  alias HandbeanWeb.WorkspaceLive.RuntimeProjection
  alias HandbeanWeb.WorkspaceLive.Skills
  alias HandbeanWeb.WorkspaceLive.WidgetCommands
  alias HandbeanWeb.WorkspaceLive.ChatComponents
  alias HandbeanWeb.WorkspaceLive.OverlayComponents
  alias HandbeanWeb.WorkspaceLive.SidebarComponents
  alias HandbeanWeb.WorkspaceLive.ViewComponents
  alias HandbeanWeb.WorkspaceLive.WorkspaceComponents
  alias HandbeanWeb.WorkspaceLive.Schedules
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

  alias Handbean.Platform.FileManager
  alias Handbean.WorkspaceFiles

  @impl true
  def mount(params, _session, socket) do
    {:ok, default_ws} = Handbean.WorkspaceStore.ensure_default!()

    workspaces = Handbean.WorkspaceStore.list()

    conversations_by_ws = Map.new(workspaces, &{&1["id"], []}) |> Map.put(:free, [])

    boot = boot_location(params, workspaces, default_ws, conversations_by_ws)

    Handbean.Workspace.ensure_root!()
    if is_binary(boot.workspace_root), do: prewarm_search(boot.workspace_root)

    models = ModelSelection.boot(boot.model_root)
    available_models = models.available_models
    selected_model = models.selected_model
    selected_reasoning_level = models.selected_reasoning_level
    available_reasoning_levels = models.available_reasoning_levels

    # Detect mobile mode from UA on initial render (JS will correct after mount)
    mobile_mode = WorkspaceNavigation.mobile_mode_from_ua(get_connect_params(socket))

    socket =
      socket
      |> assign(:page_title, "Handbean — Workspace")
      |> assign(:chat_scope, boot.chat_scope)
      |> assign(:workspaces, workspaces)
      |> assign(:current_workspace_id, boot.workspace_id)
      |> assign(:current_conversation_id, boot.conversation_id)
      |> assign(:workspace_path, boot.workspace_path)
      |> assign(:workspace_root, boot.workspace_root)
      |> assign(:checkout_available?, boot.chat_scope == :free or is_binary(boot.workspace_root))
      |> assign(:workspace_label, boot.workspace_label)
      |> assign(:conversations_by_workspace, conversations_by_ws)
      |> assign(:conversation_list_loading, true)
      |> assign(:conversation_list_loaded, false)
      |> assign(:conversation_list_error, nil)
      |> assign(:conversation_list_revision, 0)
      |> assign(:conversation_list_task_revision, nil)
      |> assign(:conversation_list_boot, if(params["conversation_id"], do: nil, else: boot))
      |> assign(:selected_model, selected_model)
      |> assign(:available_models, available_models)
      |> assign(:selected_reasoning_level, selected_reasoning_level)
      |> assign(:available_reasoning_levels, available_reasoning_levels)
      |> assign(:status_info, %{
        model: models.status_model,
        input_tokens: 0,
        total_input_tokens: 0,
        output_tokens: 0,
        cache_read_tokens: 0,
        cache_write_tokens: 0,
        status: :idle,
        status_detail: nil,
        turns: 0
      })
      |> stream_configure(:timeline, dom_id: &timeline_entry_id/1)
      # Build conversation stream (flat list, scroll-safe)
      |> stream_conversations(conversations_by_ws, workspaces)
      # Current conversation state (mirrored from conversations for convenience)
      |> ConversationState.sync_conv_state()
      |> assign(:preview_line, nil)
      # Add project dialog
      |> assign(:show_add_project, false)
      |> assign(:add_project_form, %{
        "path" => "",
        "name" => "",
        "builtin_memory_enabled" => true,
        "error" => nil
      })
      |> assign(:show_file_browser, false)
      |> assign(:file_browser_path, nil)
      |> assign(:sandbox_workspace?, WorkspaceNavigation.sandbox_workspace?())
      |> subscribe_workspace_import()
      |> subscribe_speech()
      |> assign(:terminal_available?, Handbean.Terminal.available?())
      |> assign(
        :file_manager,
        if(FileManager.available?(), do: FileManager.kind(), else: nil)
      )
      |> assign(:show_terminal, false)
      |> assign(:right_panel_view, :files)
      |> assign(:workspace_tree, %{})
      |> assign(:expanded_workspace_dirs, MapSet.new())
      |> assign(:workspace_tree_error, nil)
      |> WorkspaceNavigation.load_workspace_tree("")
      # Thinking / reasoning display
      |> assign(:thinking_content, "")
      |> assign(:thinking_active, false)
      |> assign(:think_buffer, "")
      # Agent state
      |> assign(:input_value, "")
      |> assign(:composer_error, nil)
      |> assign(:running, false)
      |> assign(:running_conversation_id, nil)
      |> assign(:stream_suppressed, false)
      |> assign(:pending_attachments, [])
      |> assign(:composer_drafts, %{})
      |> assign(:pending_messages, %{})
      |> assign(:speech_available?, Handbean.Speech.available?())
      |> assign(
        :speech_state,
        if(Handbean.Speech.available?(), do: Handbean.Speech.status(), else: :unavailable)
      )
      |> assign(:speech_request, nil)
      |> assign(:speech_revision, 0)
      |> allow_upload(:images,
        accept: ~w(.png .jpg .jpeg .gif .webp),
        max_entries: 4,
        max_file_size: 5_000_000,
        auto_upload: true
      )
      |> allow_upload(:speech_audio,
        accept: :any,
        max_entries: 1,
        max_file_size: 3_840_000,
        auto_upload: true,
        progress: &handle_progress/3
      )
      |> ModelSelection.reload_workspace_counts()
      |> assign(:expanded_file_changes, MapSet.new())
      |> assign(:revert_confirm_change_id, nil)
      |> assign(:revert_message, nil)
      |> assign(:current_assistant_entry_id, nil)
      |> assign(:tools_active, %{})
      |> assign(:expanded_tool_groups, MapSet.new())
      |> assign(:show_archive, false)
      |> assign(:collapsed_workspace_ids, SessionMemory.collapsed_groups())
      |> assign(:collapsed_thread_ids, MapSet.new())
      |> assign(:sidebar_visible_limits, %{})
      |> assign(:remove_workspace, nil)
      |> assign(:rename_workspace, nil)
      |> assign(:conversation_menu_id, nil)
      |> assign(:checkout_picker, nil)
      |> assign(:rename_conversation, nil)
      |> assign(:delete_conversation, nil)
      |> assign(:pending_approval, nil)
      |> Schedules.defaults()
      |> assign(:show_permission_menu, false)
      |> assign(:skill_suggestions, [])
      |> assign(:ext_status_text, nil)
      |> assign(:ext_notification, nil)
      |> assign(:ext_widget_data, nil)
      |> WorkspaceNavigation.load_permission_mode_into_socket()
      |> subscribe_to_conversation_updates()
      |> subscribe_schedules()
      |> RuntimeProjection.subscribe_session()
      |> RuntimeProjection.subscribe_tasks()
      |> restore_session()
      |> Schedules.reload()
      |> ConversationSwitching.load_conversation_list()
      |> load_available_skills()
      # Mobile mode
      |> assign(:mobile_mode, mobile_mode)
      # Mobile UI overlays
      |> assign(:show_workspace_sheet, false)
      |> assign(:show_model_sheet, false)
      |> CliSelection.assign_boot()
      |> assign(:show_reasoning_sheet, false)
      |> assign(:show_settings_sheet, false)
      |> assign(:show_file_drawer, false)
      |> assign(:mobile_right_panel_open, false)
      |> assign(:right_panel_collapsed, false)
      |> assign(:browser_capture_token, nil)
      |> finish_boot_models()
      |> maybe_remember_boot(params)

    {:ok, socket}
  end

  defp boot_location(params, workspaces, default_ws, conversations_by_ws) do
    if is_binary(params["conversation_id"]) do
      explicit_boot(params, workspaces, default_ws) ||
        default_boot(default_ws, conversations_by_ws)
    else
      case SessionMemory.restore(workspaces) do
        %{scope: :free, conversation_id: id} ->
          %{
            chat_scope: :free,
            workspace_id: nil,
            conversation_id: id,
            workspace_path: nil,
            workspace_root: nil,
            workspace_label: "Chats",
            model_root: default_ws["path"]
          }

        %{scope: :workspace, workspace_id: workspace_id, conversation_id: id} ->
          ws = Enum.find(workspaces, &(&1["id"] == workspace_id)) || default_ws

          checkout_path = checkout_for_boot(id, ws)

          %{
            chat_scope: :workspace,
            workspace_id: ws["id"],
            conversation_id: id,
            workspace_path: ws["path"],
            workspace_root: checkout_path,
            workspace_label: ws["name"],
            model_root: ws["path"]
          }

        _ ->
          default_boot(default_ws, conversations_by_ws)
      end
    end
  end

  defp explicit_boot(
         %{"workspace_id" => workspace_id, "conversation_id" => conversation_id},
         workspaces,
         _default_ws
       ) do
    with %{} = workspace <- Enum.find(workspaces, &(&1["id"] == workspace_id)),
         {:ok, conversation} <-
           Handbean.ConversationStore.get(conversation_id, include_timeline?: false),
         true <- conversation["workspace_id"] == workspace_id,
         false <- Handbean.ConversationStore.free?(conversation) do
      %{
        chat_scope: :workspace,
        workspace_id: workspace_id,
        conversation_id: conversation_id,
        workspace_path: workspace["path"],
        workspace_root: checkout_for_boot(conversation_id, workspace),
        workspace_label: workspace["name"],
        model_root: workspace["path"]
      }
    else
      _ -> nil
    end
  end

  defp explicit_boot(%{"conversation_id" => conversation_id}, _workspaces, default_ws) do
    with {:ok, conversation} <-
           Handbean.ConversationStore.get(conversation_id, include_timeline?: false),
         true <- Handbean.ConversationStore.free?(conversation) do
      %{
        chat_scope: :free,
        workspace_id: nil,
        conversation_id: conversation_id,
        workspace_path: nil,
        workspace_root: nil,
        workspace_label: "Chats",
        model_root: default_ws["path"]
      }
    else
      _ -> nil
    end
  end

  defp default_boot(default_ws, conversations_by_ws) do
    %{
      chat_scope: :workspace,
      workspace_id: default_ws["id"],
      conversation_id: initial_conversation_id(conversations_by_ws, default_ws["id"]),
      workspace_path: default_ws["path"],
      workspace_root: default_ws["default_checkout_path"],
      workspace_label: default_ws["name"],
      model_root: default_ws["path"]
    }
  end

  defp checkout_for_boot(conversation_id, workspace) do
    case Handbean.ConversationStore.effective_checkout_path(conversation_id) do
      {:ok, checkout_path} ->
        checkout_path

      {:error, :checkout_path_missing} when is_nil(conversation_id) ->
        workspace["default_checkout_path"]

      {:error, _reason} ->
        nil
    end
  end

  defp finish_boot_models(socket) do
    if socket.assigns.chat_scope == :free do
      socket
      |> assign(:right_panel_collapsed, true)
      |> ModelSelection.reload_free_models()
    else
      socket
      |> ModelSelection.load_effective_settings()
      |> ModelSelection.apply_effective()
    end
  end

  defp maybe_remember_boot(socket, params) do
    if is_binary(params["conversation_id"]), do: socket, else: SessionMemory.remember(socket)
  end

  @impl true
  def handle_async(:conversation_list, {:ok, {revision, result}}, socket) do
    if revision != socket.assigns.conversation_list_revision do
      {:noreply, ConversationSwitching.load_conversation_list(socket)}
    else
      case result do
        {:ok, conversations} ->
          log_workspace_boot(
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
        |> restore_session()
        |> SessionMemory.remember()
      else
        socket
      end
    else
      socket
    end
  end

  @impl true
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
          socket = drop_composer_for_switch(socket, conv_id)
          {socket, _conv_id} = ConversationSwitching.select_free_conversation(socket, conv_id)

          socket
          |> WorkspaceNavigation.enter_free_chat()
          |> RuntimeProjection.subscribe_session()
          |> restore_session()
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
        socket = drop_composer_for_switch(socket, conv_id)
        {socket, _conv_id} = ConversationSwitching.select_conversation(socket, ws_id, conv_id)

        socket =
          socket
          |> assign(:workspace_label, ws["name"])
          |> WorkspaceNavigation.after_switch()
          |> RuntimeProjection.subscribe_session()
          |> restore_session()
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

  defp prewarm_search(workspace) do
    case Handbean.Search.prewarm(workspace) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[WorkspaceLive] search prewarm failed: #{inspect(reason)}")
    end
  end

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
  def handle_event("remove_attachment", %{"id" => id}, socket) do
    {:noreply, Composer.remove_attachment(socket, id)}
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :images, ref)}
  end

  @impl true
  def handle_event("clear_composer_error", _params, socket) do
    {:noreply, assign(socket, :composer_error, nil)}
  end

  @impl true
  def handle_event("toggle_skills_panel", _params, socket) do
    {:noreply, update(socket, :show_skills_panel, &(!&1))}
  end

  @impl true
  def handle_event("launch_skill", %{"name" => skill_name}, socket) do
    prompt = Skills.launch_prompt(socket.assigns.available_skills, skill_name)

    socket =
      socket
      |> assign(:show_skills_panel, false)
      |> assign(:input_value, prompt)

    {:noreply, socket}
  end

  @impl true
  def handle_event("composer_drop", params, socket) do
    # Form-level phx-change also fires when the model/reasoning <select>
    # changes. Ignore those params and the picker snaps back on remorph.
    socket = ModelSelection.apply_submitted(socket, params)

    {:noreply, socket}
  end

  @impl true
  def handle_event("send_message", params, socket),
    do: socket |> Composer.invalidate_speech() |> MessageSubmission.send_message(params)

  @impl true
  def handle_event("steer_message", params, socket),
    do: socket |> Composer.invalidate_speech() |> MessageSubmission.steer_message(params)

  @impl true
  def handle_event("queue_message", params, socket),
    do: socket |> Composer.invalidate_speech() |> MessageSubmission.queue_message(params)

  @impl true
  def handle_event("send_pending_now", %{"id" => id}, socket),
    do: MessageSubmission.send_pending_now(socket, id)

  @impl true
  def handle_event("cancel_pending", %{"id" => id}, socket),
    do: MessageSubmission.cancel_pending(socket, id)

  @impl true
  def handle_event("resend_pending", %{"id" => id}, socket),
    do: MessageSubmission.resend_pending(socket, id)

  @impl true
  def handle_event("delete_undelivered", %{"id" => id}, socket),
    do: MessageSubmission.delete_undelivered(socket, id)

  @impl true
  def handle_event("speech_error", %{"reason" => reason}, socket) do
    {:noreply,
     socket
     |> assign(:speech_state, :ready)
     |> assign(:composer_error, speech_error_message(reason))}
  end

  @impl true
  def handle_event("update_input", %{"value" => value}, socket) do
    suggestions = Skills.suggestions(value, socket.assigns.available_skills)

    {:noreply,
     socket
     |> assign(:input_value, value)
     |> assign(:skill_suggestions, suggestions)}
  end

  @impl true
  def handle_event("prefill_subagent_follow_up", %{"child" => child}, socket)
      when is_binary(child) and child != "" do
    {:noreply, Composer.prefill_text(socket, "@#{child} ")}
  end

  @impl true
  def handle_event("widget_command", params, socket) do
    conversation_id = socket.assigns[:current_conversation_id]
    entry = authoritative_widget_entry(conversation_id, params["entry_id"])

    case WidgetCommands.prefill_text(params, entry, conversation_id) do
      {:ok, text} ->
        {:noreply,
         socket
         |> Composer.prefill_text(text)
         |> push_widget_command_result(params, "ok")}

      {:error, reason} ->
        {:noreply, push_widget_command_result(socket, params, "error", reason)}
    end
  end

  @impl true
  def handle_event("select_skill_suggestion", %{"name" => skill_name}, socket) do
    new_value = Skills.select(socket.assigns.input_value, skill_name)

    {:noreply,
     socket
     |> assign(:input_value, new_value)
     |> assign(:skill_suggestions, nil)}
  end

  @impl true
  def handle_event("dismiss_skill_suggestions", _params, socket) do
    {:noreply, assign(socket, :skill_suggestions, nil)}
  end

  @impl true
  def handle_event("stop_run", _params, socket), do: MessageSubmission.stop(socket)

  def handle_event("approve_cli_option", %{"option" => option}, socket) do
    pending = socket.assigns.pending_approval

    if cli_approval?(pending) and is_binary(option) do
      MessageSubmission.resume_cli_approval(socket, pending, {:approve, option})
    else
      {:noreply, socket}
    end
  end

  def handle_event("approve_all_tools", params, socket) do
    resume_tool_approval(socket, :approve, Approval.remember_scope(params))
  end

  def handle_event("deny_all_tools", params, socket) do
    resume_tool_approval(socket, :deny, Approval.remember_scope(params))
  end

  @impl true
  def handle_event("select_cli", params, socket) do
    {:noreply, CliSelection.select(socket, params["cli"] || params["value"])}
  end

  def handle_event("select_model", params, socket) do
    model = params["model"] || params["value"]

    socket =
      if CliSelection.cli_selected?(socket.assigns),
        do: CliSelection.select_model(socket, model),
        else: ModelSelection.select(socket, model)

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_reasoning", %{"reasoning" => level}, socket) do
    {:noreply,
     socket |> ModelSelection.select_reasoning(level) |> CliSelection.remember_current()}
  end

  @impl true
  def handle_event("refresh_models", _params, socket) do
    {:noreply, ModelSelection.refresh(socket)}
  end

  @impl true
  def handle_event("select_file", %{"path" => path}, socket) do
    socket =
      ConversationState.select_file(
        socket,
        path,
        ConversationState.current_checkout_path(socket),
        ModelSelection.state_opts()
      )

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_workspace_file", %{"path" => relative_path}, socket) do
    {:noreply,
     socket
     |> assign(:preview_line, nil)
     |> ConversationState.select_file(
       relative_path,
       ConversationState.current_checkout_path(socket),
       ModelSelection.state_opts()
     )}
  end

  @impl true
  def handle_event("toggle_workspace_directory", %{"path" => relative_path}, socket) do
    {:noreply, WorkspaceNavigation.toggle_directory(socket, relative_path)}
  end

  @impl true
  def handle_event("select_editor_file", %{"path" => relative_path}, socket)
      when is_binary(relative_path) do
    {:noreply,
     socket
     |> assign(:preview_line, nil)
     |> ConversationState.select_editor_file(
       relative_path,
       ConversationState.current_checkout_path(socket),
       ModelSelection.state_opts()
     )}
  end

  @impl true
  def handle_event("close_editor_file", %{"path" => relative_path}, socket)
      when is_binary(relative_path) do
    root = ConversationState.current_checkout_path(socket)

    {:noreply,
     ConversationState.close_file(socket, relative_path, root, ModelSelection.state_opts())}
  end

  @impl true
  def handle_event("reveal_in_file_manager", %{"path" => relative_path}, socket)
      when is_binary(relative_path) do
    with true <- FileManager.available?(),
         root when is_binary(root) <- socket.assigns.workspace_root,
         {:ok, path} <- WorkspaceFiles.resolve_entry(root, relative_path),
         :ok <- FileManager.reveal(path) do
      {:noreply, socket}
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("select_right_panel_view", %{"view" => view}, socket)
      when view in ["changes", "files", "browser"] do
    {:noreply, WorkspaceNavigation.select_panel(socket, view)}
  end

  def handle_event("select_right_panel_view", %{"view" => "terminal"}, socket) do
    {:noreply, WorkspaceNavigation.show_terminal(socket)}
  end

  def handle_event("select_mobile_right_panel_view", %{"view" => "files"}, socket) do
    {:noreply, WorkspaceNavigation.show_files_mobile(socket)}
  end

  def handle_event("select_mobile_right_panel_view", %{"view" => "terminal"}, socket) do
    {:noreply, WorkspaceNavigation.show_terminal(socket, true)}
  end

  def handle_event("close_mobile_right_panel", _params, socket) do
    {:noreply, WorkspaceNavigation.close_mobile_panel(socket)}
  end

  def handle_event("open_file_change", %{"path" => path} = params, socket)
      when is_binary(path) do
    root = ConversationState.current_checkout_path(socket)
    requested = Path.expand(path, root)
    message_id = params["message_id"]

    entry =
      socket.assigns.timeline
      |> Enum.take_while(&(is_nil(message_id) or &1["id"] != message_id))
      |> Enum.reverse()
      |> Enum.find(fn entry ->
        file_path = HandbeanWeb.ChangeHelper.change_from_entry(entry)["file_path"]

        HandbeanWeb.FileChangeCard.change_entry?(entry) and is_binary(file_path) and
          Path.expand(file_path, root) == requested
      end)

    if entry do
      expanded = Map.get(socket.assigns, :expanded_file_changes, MapSet.new())
      socket = assign(socket, :expanded_file_changes, MapSet.put(expanded, entry["id"]))

      socket =
        if group_id = entry["work_group_id"] do
          groups = Map.get(socket.assigns, :expanded_tool_groups, MapSet.new())

          socket
          |> assign(:expanded_tool_groups, MapSet.put(groups, group_id))
          |> RuntimeProjection.refresh_tool_work(group_id)
        else
          socket
        end

      {:noreply,
       socket
       |> RuntimeProjection.refresh_file_change(entry["id"])
       |> push_event("scroll_to_file_change", %{id: "chat-file-change-#{entry["id"]}"})}
    else
      relative = Path.relative_to(requested, root)

      {:noreply,
       socket
       |> WorkspaceNavigation.reveal_files_panel()
       |> ConversationState.select_file(relative, root, ModelSelection.state_opts())
       |> assign(:preview_line, preview_line(params["line"]))}
    end
  end

  def handle_event("toggle_file_change", params, socket) do
    case params do
      %{"id" => id} when is_binary(id) ->
        expanded = Map.get(socket.assigns, :expanded_file_changes, MapSet.new())

        expanded =
          if MapSet.member?(expanded, id),
            do: MapSet.delete(expanded, id),
            else: MapSet.put(expanded, id)

        {:noreply,
         socket
         |> assign(:expanded_file_changes, expanded)
         |> assign(:right_panel_collapsed, false)
         |> RuntimeProjection.refresh_file_change(id)}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("confirm_revert_change", %{"change_id" => change_id}, socket) do
    {:noreply, RuntimeProjection.mark_revert_confirm(socket, change_id)}
  end

  @impl true
  def handle_event("cancel_revert_change", _params, socket) do
    {:noreply, RuntimeProjection.mark_revert_confirm(socket, nil)}
  end

  @impl true
  def handle_event("revert_change", %{"change_id" => change_id}, socket) do
    with %{} = change <- find_change(socket.assigns.timeline, change_id),
         {:not_running, false} <- {:not_running, running_for_current_conversation?(socket)} do
      result =
        Handbean.ChangeReverter.revert(change, ConversationState.current_checkout_path(socket))

      {:noreply,
       EditorProjection.apply_revert_result(
         socket,
         change,
         result,
         ConversationState.current_checkout_path(socket)
       )}
    else
      {:not_running, true} ->
        {:noreply,
         RuntimeProjection.mark_revert_confirm(
           assign(socket, :revert_message, %{
             "change_id" => change_id,
             "status" => "error",
             "message" => "Cannot revert while an agent run is active."
           }),
           nil
         )}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("open_preview", %{"id" => preview_id}, socket) do
    {:noreply, WorkspaceNavigation.open_preview_display(socket, preview_id, :overlay)}
  end

  @impl true
  def handle_event("open_preview_external", %{"id" => preview_id}, socket) do
    {:noreply, WorkspaceNavigation.open_preview_display(socket, preview_id, :external)}
  end

  @impl true
  def handle_event("takeover_browser", %{"session" => session_id}, socket) do
    try do
      case Handbean.Browser.WebViewSession.user_takeover(session_id) do
        :ok ->
          {:noreply, socket}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "browser takeover failed: #{inspect(reason)}")}
      end
    catch
      :exit, _ -> {:noreply, put_flash(socket, :error, "browser session is gone")}
    end
  end

  def handle_event("toggle_terminal", _params, socket) do
    {:noreply, WorkspaceNavigation.show_terminal(socket)}
  end

  # ── Workspace / Project dialog ──

  @impl true
  def handle_event("open_add_project", _params, socket) do
    {:noreply, WorkspaceNavigation.open_add_project(socket)}
  end

  @impl true
  def handle_event("cancel_add_project", _params, socket) do
    {:noreply, WorkspaceNavigation.cancel_add_project(socket)}
  end

  @impl true
  def handle_event("update_add_path", %{"value" => path}, socket) do
    {:noreply, WorkspaceNavigation.update_add_path(socket, path)}
  end

  @impl true
  def handle_event("update_add_name", %{"value" => name}, socket) do
    {:noreply, WorkspaceNavigation.update_add_name(socket, name)}
  end

  @impl true
  def handle_event("toggle_add_project_memory", _params, socket) do
    {:noreply, WorkspaceNavigation.toggle_add_project_memory(socket)}
  end

  @impl true
  def handle_event("confirm_add_project", _params, socket) do
    WorkspaceNavigation.confirm_add_event(socket)
  end

  def handle_event("browse_folder", _params, socket) do
    {:noreply, WorkspaceNavigation.browse_folder(socket)}
  end

  @impl true
  def handle_event("select_workspace", %{"id" => ws_id}, socket) do
    socket = drop_composer_for_switch(socket)
    socket = WorkspaceNavigation.expand_group(socket, ws_id)
    {socket, conv_id} = ConversationSwitching.select_workspace(socket, ws_id)

    socket =
      socket
      |> WorkspaceNavigation.after_switch()
      |> RuntimeProjection.subscribe_session()
      |> restore_session()
      |> WorkspaceNavigation.close_mobile_sheets()

    {:noreply, push_patch(socket, to: "/w/#{ws_id}/c/#{conv_id}")}
  end

  @impl true
  def handle_event("load_older_history", _params, socket) do
    {:noreply, ConversationState.load_older_history(socket)}
  end

  @impl true
  def handle_event("select_conversation", %{"id" => conv_id, "ws_id" => ws_id}, socket) do
    with {:ok, %{"workspace_id" => ^ws_id}} <-
           Handbean.ConversationStore.get(conv_id, include_timeline?: false) do
      socket = drop_composer_for_switch(socket, conv_id)
      {socket, _conv_id} = ConversationSwitching.select_conversation(socket, ws_id, conv_id)

      socket =
        socket
        |> WorkspaceNavigation.after_switch()
        |> RuntimeProjection.subscribe_session()
        |> restore_session()
        |> WorkspaceNavigation.close_mobile_sheets()

      {:noreply, push_patch(socket, to: "/w/#{ws_id}/c/#{conv_id}")}
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("select_archived_conversation", %{"id" => conv_id} = params, socket) do
    with {:ok, conv} <- Handbean.ConversationStore.get(conv_id, include_timeline?: false) do
      if Handbean.ConversationStore.free?(conv) do
        socket = drop_composer_for_switch(socket, conv_id)
        {socket, _conv_id} = ConversationSwitching.select_free_conversation(socket, conv_id)

        socket =
          socket
          |> WorkspaceNavigation.enter_free_chat()
          |> RuntimeProjection.subscribe_session()
          |> restore_session()
          |> WorkspaceNavigation.close_mobile_sheets()

        {:noreply, push_patch(socket, to: "/c/#{conv_id}")}
      else
        ws_id = params["ws"] || conv["workspace_id"]

        with true <- is_binary(ws_id),
             {:ok, %{"workspace_id" => ^ws_id}} <- {:ok, conv} do
          socket = drop_composer_for_switch(socket, conv_id)

          {socket, _conv_id} =
            ConversationSwitching.select_archived_conversation(socket, ws_id, conv_id)

          socket =
            socket
            |> WorkspaceNavigation.after_switch()
            |> RuntimeProjection.subscribe_session()
            |> restore_session()
            |> WorkspaceNavigation.close_mobile_sheets()

          {:noreply, push_patch(socket, to: "/w/#{ws_id}/c/#{conv_id}")}
        else
          _ -> {:noreply, socket}
        end
      end
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_conversation_menu", %{"id" => conv_id}, socket) do
    menu_id = if socket.assigns.conversation_menu_id == conv_id, do: nil, else: conv_id
    {:noreply, assign(socket, :conversation_menu_id, menu_id)}
  end

  def handle_event("open_conversation_context_menu", %{"id" => conv_id}, socket) do
    {:noreply, assign(socket, :conversation_menu_id, conv_id)}
  end

  def handle_event("close_conversation_menu", _params, socket) do
    {:noreply, assign(socket, :conversation_menu_id, nil)}
  end

  def handle_event("toggle_pin_conversation", %{"id" => conv_id}, socket) do
    socket = assign(socket, :conversation_menu_id, nil)

    socket =
      case Handbean.ConversationStore.get(conv_id, include_timeline?: false) do
        {:ok, conv} ->
          if Handbean.ConversationStore.internal?(conv) do
            socket
          else
            result =
              if Handbean.ConversationStore.pinned_conversation?(conv),
                do: Handbean.ConversationStore.unpin(conv_id),
                else: Handbean.ConversationStore.pin(conv_id)

            case result do
              {:ok, _} ->
                ConversationSwitching.refresh_conversation_in_sidebar(socket, conv_id)

              _ ->
                socket
            end
          end

        _ ->
          socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("open_rename_conversation", %{"id" => conv_id} = params, socket) do
    case Handbean.ConversationStore.get(conv_id, include_timeline?: false) do
      {:ok, %{"title" => title} = conv} ->
        free? = Handbean.ConversationStore.free?(conv)
        ws_id = params["ws_id"]

        if free? or conv["workspace_id"] == ws_id do
          {:noreply,
           socket
           |> assign(:conversation_menu_id, nil)
           |> assign(:rename_conversation, %{
             id: conv_id,
             workspace_id: if(free?, do: nil, else: ws_id),
             title: title || "",
             error: nil
           })}
        else
          {:noreply, assign(socket, :conversation_menu_id, nil)}
        end

      _ ->
        {:noreply, assign(socket, :conversation_menu_id, nil)}
    end
  end

  def handle_event("cancel_rename_conversation", _params, socket) do
    {:noreply, assign(socket, :rename_conversation, nil)}
  end

  def handle_event("open_delete_conversation", %{"id" => conv_id} = params, socket) do
    case Handbean.ConversationStore.delete_preview(conv_id) do
      {:ok, preview} ->
        workspace_matches? =
          preview.scope == "free" or preview.workspace_id == params["ws_id"] or
            preview.workspace_id == socket.assigns.current_workspace_id

        if workspace_matches? do
          {:noreply,
           socket
           |> assign(:conversation_menu_id, nil)
           |> assign(:rename_conversation, nil)
           |> assign(:show_settings_sheet, false)
           |> assign(:delete_conversation, Map.put(preview, :error, nil))}
        else
          {:noreply, assign(socket, :conversation_menu_id, nil)}
        end

      {:error, :not_found} ->
        {:noreply, assign(socket, :conversation_menu_id, nil)}
    end
  end

  def handle_event("cancel_delete_conversation", _params, socket) do
    {:noreply, assign(socket, :delete_conversation, nil)}
  end

  def handle_event("confirm_delete_conversation", _params, socket) do
    case socket.assigns.delete_conversation do
      %{id: conv_id} = pending ->
        case Handbean.ConversationStore.request_delete(conv_id) do
          {:ok, ids} ->
            {socket, next_id} =
              ConversationSwitching.conversations_pending_delete(
                socket,
                ids,
                ModelSelection.state_opts()
              )

            socket =
              socket
              |> assign(:delete_conversation, nil)
              |> navigate_after_delete(next_id)

            {:noreply, socket}

          {:error, :not_found} ->
            {:noreply, assign(socket, :delete_conversation, nil)}

          {:error, _reason} ->
            {:noreply,
             assign(socket, :delete_conversation, %{
               pending
               | error: gettext("删除请求失败，请重试")
             })}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("confirm_rename_conversation", %{"title" => title}, socket) do
    case socket.assigns.rename_conversation do
      %{id: conv_id} = rename ->
        case Handbean.ConversationStore.rename(conv_id, title) do
          {:ok, meta} ->
            {:noreply,
             socket
             |> ConversationSwitching.refresh_conversation_in_sidebar(conv_id)
             |> ConversationState.maybe_patch_page_title(conv_id, meta["title"])
             |> assign(:rename_conversation, nil)}

          {:error, :empty} ->
            {:noreply,
             assign(socket, :rename_conversation, %{
               rename
               | title: title,
                 error: gettext("名称不能为空")
             })}

          {:error, :too_long} ->
            {:noreply,
             assign(socket, :rename_conversation, %{
               rename
               | title: title,
                 error: gettext("名称不能超过 80 个字符")
             })}

          {:error, _reason} ->
            {:noreply,
             assign(socket, :rename_conversation, %{
               rename
               | title: title,
                 error: gettext("重命名失败")
             })}
        end

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("archive_conversation", %{"id" => conv_id} = params, socket) do
    socket =
      socket
      |> assign(:conversation_menu_id, nil)
      |> assign(:rename_conversation, nil)

    with {:ok, conv} <- Handbean.ConversationStore.get(conv_id, include_timeline?: false) do
      free? = Handbean.ConversationStore.free?(conv)
      ws_id = conv["workspace_id"] || params["ws_id"] || socket.assigns.current_workspace_id

      {socket, next_conv_id} =
        ConversationSwitching.archive_conversation(
          socket,
          conv_id,
          ws_id,
          ModelSelection.state_opts()
        )

      socket =
        cond do
          next_conv_id && free? ->
            socket
            |> WorkspaceNavigation.enter_free_chat()
            |> RuntimeProjection.subscribe_session()
            |> push_patch(to: "/c/#{next_conv_id}")

          next_conv_id && is_binary(ws_id) ->
            socket
            |> WorkspaceNavigation.after_switch()
            |> RuntimeProjection.subscribe_session()
            |> push_patch(to: "/w/#{ws_id}/c/#{next_conv_id}")

          true ->
            socket
        end

      {:noreply, socket}
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("unarchive_conversation", %{"id" => conv_id}, socket) do
    {:noreply, ConversationSwitching.unarchive_conversation(socket, conv_id)}
  end

  # ── Archive toggle ──

  @impl true
  def handle_event("toggle_archive", _params, socket) do
    {:noreply, update(socket, :show_archive, &(!&1))}
  end

  @impl true
  def handle_event("toggle_workspace_group", %{"id" => id}, socket)
      when is_binary(id) do
    {:noreply, WorkspaceNavigation.toggle_group(socket, id)}
  end

  @impl true
  def handle_event("toggle_thread", %{"id" => id}, socket) when is_binary(id) do
    {:noreply, ConversationSwitching.toggle_thread(socket, id)}
  end

  @impl true
  def handle_event("show_more_conversations", %{"bucket" => bucket}, socket)
      when is_binary(bucket) do
    {:noreply, ConversationSwitching.show_more_conversations(socket, bucket)}
  end

  def handle_event("open_rename_workspace", %{"id" => ws_id}, socket) do
    case Handbean.WorkspaceStore.get(ws_id) do
      {:ok, ws} ->
        {:noreply,
         assign(socket, :rename_workspace, %{
           id: ws["id"],
           name: ws["name"] || "",
           error: nil
         })}

      {:error, :not_found} ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_rename_workspace", _params, socket) do
    {:noreply, assign(socket, :rename_workspace, nil)}
  end

  def handle_event("confirm_rename_workspace", %{"name" => name}, socket) do
    case socket.assigns.rename_workspace do
      %{id: ws_id} = rename ->
        case Handbean.WorkspaceStore.rename(ws_id, name) do
          {:ok, ws} ->
            socket =
              socket
              |> assign(:workspaces, Handbean.WorkspaceStore.list())
              |> assign(:rename_workspace, nil)

            socket =
              if socket.assigns.current_workspace_id == ws_id,
                do: assign(socket, :workspace_label, ws["name"]),
                else: socket

            {:noreply, socket}

          {:error, :empty} ->
            {:noreply,
             assign(socket, :rename_workspace, %{rename | name: name, error: gettext("名称不能为空")})}

          {:error, :too_long} ->
            {:noreply,
             assign(socket, :rename_workspace, %{
               rename
               | name: name,
                 error: gettext("名称不能超过 80 个字符")
             })}

          {:error, _reason} ->
            {:noreply,
             assign(socket, :rename_workspace, %{rename | name: name, error: gettext("重命名失败")})}
        end

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("open_remove_workspace", %{"id" => ws_id}, socket) do
    {:noreply, WorkspaceNavigation.open_remove_workspace(socket, ws_id)}
  end

  def handle_event("cancel_remove_workspace", _params, socket) do
    {:noreply, WorkspaceNavigation.cancel_remove_workspace(socket)}
  end

  @impl true
  def handle_event("confirm_remove_workspace", _params, socket) do
    case socket.assigns.remove_workspace do
      %{id: ws_id} ->
        case ConversationSwitching.remove_workspace(socket, ws_id) do
          {:ok, socket, _removed} ->
            socket =
              if socket.assigns.current_workspace_id == ws_id do
                WorkspaceNavigation.switch_away_from_removed_workspace(socket)
              else
                socket
              end

            {:noreply, socket}

          {:error, :default_workspace} ->
            {:noreply,
             socket
             |> assign(:remove_workspace, nil)
             |> put_flash(:error, gettext("默认工作区不能移除"))}

          {:error, _reason} ->
            {:noreply,
             socket
             |> assign(:remove_workspace, nil)
             |> put_flash(:error, gettext("移除工作区失败"))}
        end

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("retry_conversation_list", _params, socket) do
    {:noreply, ConversationSwitching.load_conversation_list(socket)}
  end

  def handle_event("new_conversation", _params, socket) do
    begin_conversation_in_workspace(socket, socket.assigns.current_workspace_id,
      source: :sidebar,
      close_sheets?: false
    )
  end

  def handle_event("toggle_new_conversation_picker", _params, socket) do
    {:noreply, ConversationSwitching.toggle_new_conversation_picker(socket)}
  end

  @impl true
  def handle_event("new_free_conversation", _params, socket) do
    socket = drop_composer_for_switch(socket)

    {socket, conv_id} =
      ConversationSwitching.new_free_conversation(socket, ModelSelection.switching_opts())

    socket =
      socket
      |> WorkspaceNavigation.expand_group("free")
      |> WorkspaceNavigation.enter_free_chat()
      |> RuntimeProjection.subscribe_session()
      |> WorkspaceNavigation.close_mobile_sheets()

    {:noreply, push_patch(socket, to: "/c/#{conv_id}")}
  end

  @impl true
  def handle_event("select_free_conversation", %{"id" => conv_id}, socket) do
    with {:ok, conv} <- Handbean.ConversationStore.get(conv_id, include_timeline?: false),
         true <- Handbean.ConversationStore.free?(conv) do
      socket = drop_composer_for_switch(socket, conv_id)
      {socket, _conv_id} = ConversationSwitching.select_free_conversation(socket, conv_id)

      socket =
        socket
        |> WorkspaceNavigation.enter_free_chat()
        |> RuntimeProjection.subscribe_session()
        |> restore_session()
        |> WorkspaceNavigation.close_mobile_sheets()

      {:noreply, push_patch(socket, to: "/c/#{conv_id}")}
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("new_conversation_in_workspace", %{"ws_id" => ws_id} = params, socket) do
    source = if params["source"] == "header", do: :header, else: :sidebar
    begin_conversation_in_workspace(socket, ws_id, source: source, close_sheets?: false)
  end

  @impl true
  def handle_event("mobile_new_conversation_in_workspace", %{"ws_id" => ws_id}, socket) do
    begin_conversation_in_workspace(socket, ws_id, source: :mobile, close_sheets?: true)
  end

  def handle_event("new_conversation_on_checkout", %{"ws_id" => ws_id, "path" => path}, socket) do
    begin_conversation_in_workspace(socket, ws_id,
      checkout_path: path,
      close_sheets?: get_in(socket.assigns, [:checkout_picker, :source]) == :mobile
    )
  end

  def handle_event("close_checkout_picker", _params, socket) do
    {:noreply, ConversationSwitching.close_checkout_picker(socket)}
  end

  @impl true
  def handle_event("open_settings", _, socket) do
    {:noreply,
     push_navigate(socket,
       to:
         settings_href(
           socket.assigns.current_workspace_id,
           socket.assigns.current_conversation_id
         )
     )}
  end

  @impl true
  def handle_event("open_sheet", %{"type" => type}, socket) do
    {:noreply, WorkspaceNavigation.open_sheet(socket, type)}
  end

  @impl true
  def handle_event("close_sheets", _params, socket) do
    {:noreply, WorkspaceNavigation.close_sheet_panels(socket)}
  end

  @impl true
  def handle_event("select_model_from_sheet", %{"model" => model}, socket) do
    {:noreply, ModelSelection.select_from_sheet(socket, model)}
  end

  @impl true
  def handle_event("select_reasoning_from_sheet", %{"level" => level}, socket) do
    {:noreply,
     socket
     |> ModelSelection.select_reasoning_from_sheet(level)
     |> CliSelection.remember_current()}
  end

  @impl true
  def handle_event("toggle_file_drawer", _params, socket) do
    {:noreply, WorkspaceNavigation.toggle_file_drawer(socket)}
  end

  @impl true
  def handle_event("toggle_right_panel", _params, socket) do
    {:noreply, WorkspaceNavigation.toggle_right_panel(socket)}
  end

  @impl true
  def handle_event("set_right_panel_collapsed", %{"collapsed" => collapsed}, socket) do
    {:noreply, WorkspaceNavigation.set_right_panel_collapsed(socket, collapsed)}
  end

  def handle_event("toggle_tool_work", %{"group" => group_id}, socket)
      when is_binary(group_id) and group_id != "" do
    expanded = Map.get(socket.assigns, :expanded_tool_groups, MapSet.new())

    expanded =
      if MapSet.member?(expanded, group_id) do
        MapSet.delete(expanded, group_id)
      else
        MapSet.put(expanded, group_id)
      end

    {:noreply,
     socket
     |> assign(:expanded_tool_groups, expanded)
     |> RuntimeProjection.refresh_tool_work(group_id)}
  end

  def handle_event("toggle_tool_work", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_permission_menu", _params, socket) do
    {:noreply, update(socket, :show_permission_menu, &(!&1))}
  end

  @impl true
  def handle_event("select_permission_mode", %{"mode" => mode_str}, socket)
      when mode_str in ["prompt", "auto_review", "yolo"] do
    mode = String.to_existing_atom(mode_str)
    workspace_root = ConversationState.current_workspace_path(socket)

    case Handbean.WorkspaceSettings.update_permission_mode(workspace_root, mode) do
      :ok ->
        {:noreply,
         socket
         |> assign(:permission_mode, mode)
         |> assign(:show_permission_menu, false)}

      {:error, reason} ->
        Logger.error("[WorkspaceLive] Failed to update permission mode: #{inspect(reason)}")

        {:noreply,
         socket
         |> assign(:show_permission_menu, false)
         |> put_flash(:error, gettext("Failed to update permission mode"))}
    end
  end

  def handle_event("select_permission_mode", _params, socket) do
    {:noreply, assign(socket, :show_permission_menu, false)}
  end

  @impl true
  def handle_event("scroll_to_bottom", _params, socket) do
    {:noreply, push_event(socket, "scroll_chat_to_bottom", %{})}
  end

  def handle_event("toggle_schedules", _params, socket) do
    {:noreply,
     socket
     |> Schedules.toggle()
     |> WorkspaceNavigation.close_sheet_panels()}
  end

  def handle_event("schedule_request", %{"request" => request}, socket) do
    {:noreply, Schedules.remember_request(socket, request)}
  end

  def handle_event("schedule_ask", %{"request" => request}, socket) do
    case Schedules.prepare_ask(socket, request) do
      {:ok, socket, text} ->
        if socket.assigns.schedule_in_place do
          ask_schedule_in_place(socket, text)
        else
          ask_schedule_in_new_conversation(socket, text)
        end

      {:error, socket} ->
        {:noreply, socket}
    end
  end

  def handle_event("schedule_select", %{"id" => id}, socket) do
    {:noreply, Schedules.select(socket, id)}
  end

  def handle_event("schedule_filter", %{"filter" => filter}, socket) do
    {:noreply, Schedules.set_filter(socket, filter)}
  end

  def handle_event("schedule_search", params, socket) do
    {:noreply,
     Schedules.set_query(socket, Map.get(params, "query", Map.get(params, "value", "")))}
  end

  def handle_event("schedule_close_detail", _params, socket) do
    {:noreply, Schedules.close_detail(socket)}
  end

  def handle_event("schedule_instruction_toggle", _params, socket) do
    {:noreply, Schedules.toggle_instruction(socket)}
  end

  def handle_event("schedule_pause", %{"id" => id}, socket) do
    {:noreply, Schedules.pause(socket, id)}
  end

  def handle_event("schedule_resume", %{"id" => id}, socket) do
    {:noreply, Schedules.resume(socket, id)}
  end

  def handle_event("schedule_delete", %{"id" => id}, socket) do
    {:noreply, Schedules.delete(socket, id)}
  end

  def handle_event("schedule_run_now", %{"id" => id}, socket) do
    {:noreply, Schedules.run_now(socket, id)}
  end

  def handle_event("schedule_revise", %{"id" => id}, socket) do
    {:noreply, Schedules.revise(socket, id)}
  end

  def handle_event("open_schedule_conversation", %{"id" => conv_id, "ws_id" => ws_id}, socket) do
    case switch_workspace_conversation(socket, ws_id, conv_id) do
      {:ok, socket} -> {:noreply, push_patch(socket, to: "/w/#{ws_id}/c/#{conv_id}")}
      {:error, socket} -> {:noreply, socket}
    end
  end

  defp ask_schedule_in_place(socket, text) do
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

  defp ask_schedule_in_new_conversation(socket, text) do
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

  defp begin_conversation_in_workspace(socket, ws_id, opts) do
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

  defp switch_workspace_conversation(socket, ws_id, conv_id)
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

  defp switch_workspace_conversation(socket, _ws_id, _conv_id) do
    {:error, assign(socket, :schedule_error, gettext("找不到对话"))}
  end

  # ── Agent events ──

  @impl true
  def handle_info({:file_browser_closed}, socket) do
    {:noreply, WorkspaceNavigation.close_file_browser(socket)}
  end

  @impl true
  def handle_info({:folder_selected_from_browser, path}, socket) do
    {:noreply, WorkspaceNavigation.folder_selected(socket, path)}
  end

  def handle_info({:workspace_imported, item}, socket) when is_map(item) do
    {:noreply, WorkspaceNavigation.import_workspace(socket, item)}
  end

  @impl true
  def handle_info({:speech_enabled, false}, socket) do
    {:noreply,
     socket
     |> assign(:speech_available?, false)
     |> Composer.invalidate_speech()
     |> assign(:speech_state, :disabled)}
  end

  def handle_info({:speech_enabled, true}, socket) do
    status = Handbean.Speech.status()

    {:noreply,
     socket
     |> assign(:speech_available?, Handbean.Speech.available?())
     |> assign(:speech_state, status)}
  end

  def handle_info({:speech_status, status}, socket) do
    active_request? = not is_nil(socket.assigns.speech_request)

    available? =
      Handbean.Speech.enabled?() and Handbean.Speech.supported?() and
        (status in [:ready, :transcribing] or active_request?)

    {:noreply,
     socket
     |> assign(:speech_available?, available?)
     |> assign(:speech_state, status)}
  end

  def handle_info({:agent_event, event}, socket) do
    {:noreply, project_event(socket, event)}
  end

  def handle_info(%Handbean.PubSub.AgentEvent{} = event, socket) do
    {:noreply, project_event(socket, event)}
  end

  def handle_info({:runtime_tasks, snapshot}, socket) do
    {:noreply, assign(socket, :runtime_tasks, snapshot)}
  end

  def handle_info({:in_app_ended, task, reason}, socket) do
    if task.conversation_id == socket.assigns.current_conversation_id do
      {:noreply, socket}
    else
      {:noreply, put_flash(socket, :info, in_app_ended_flash(task, reason))}
    end
  end

  def handle_info({:conversations_pending_delete, ids}, socket) when is_list(ids) do
    {socket, next_id} =
      ConversationSwitching.conversations_pending_delete(
        socket,
        ids,
        ModelSelection.state_opts()
      )

    {:noreply,
     socket
     |> assign(:delete_conversation, nil)
     |> navigate_after_delete(next_id)}
  end

  def handle_info({:conversation_updated, conv_id}, socket) do
    socket =
      socket
      |> refresh_conversation_in_sidebar(conv_id)
      |> ConversationState.maybe_patch_current_page_title(conv_id)

    if socket.assigns.current_conversation_id == conv_id do
      send(self(), {:conversation_handoffs, conv_id})
    end

    {:noreply, socket}
  end

  def handle_info({:conversation_title_ready, conv_id, title}, socket)
      when is_binary(conv_id) and is_binary(title) do
    {:noreply,
     socket
     |> apply_sidebar_title(conv_id, title)
     |> ConversationState.maybe_patch_page_title(conv_id, title)}
  end

  def handle_info({:schedule_auto_title, conv_id, message}, socket)
      when is_binary(conv_id) and is_binary(message) do
    if socket.assigns.current_conversation_id == conv_id do
      {:noreply, ConversationState.schedule_auto_title(socket, message)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:conversation_handoffs, conv_id}, socket) do
    socket =
      if socket.assigns.current_conversation_id == conv_id do
        case Handbean.ConversationTranscriptStore.list(conv_id) do
          {:ok, entries} ->
            RuntimeProjection.reconcile_handoffs(socket, entries)

          _ ->
            socket
        end
      else
        socket
      end

    {:noreply, socket}
  end

  # Ghostty LiveTerminal.Component sends terminal_ready to parent LiveView.
  # Forward it so the session PTY matches the fitted viewport.
  def handle_info({:terminal_ready, id, cols, rows}, socket) do
    if socket.assigns[:show_terminal] do
      send_update(HandbeanWeb.Live.TerminalPanel,
        id: "terminal-panel",
        action: {:terminal_ready, id, cols, rows}
      )
    end

    {:noreply, socket}
  end

  # Forward terminal PubSub events to TerminalPanel component.
  # TerminalPanel is a LiveComponent sharing this LiveView process,
  # so its PubSub subscriptions arrive here.
  def handle_info({:terminal_refresh, ws_id, checkout_key, term_name}, socket) do
    if terminal_scope?(socket, ws_id, checkout_key) do
      send_update(HandbeanWeb.Live.TerminalPanel,
        id: "terminal-panel",
        action: {:terminal_refresh, term_name}
      )
    end

    {:noreply, socket}
  end

  def handle_info({:terminal_refresh, ws_id, term_name}, socket) do
    if ws_id == socket.assigns.current_workspace_id do
      send_update(HandbeanWeb.Live.TerminalPanel,
        id: "terminal-panel",
        action: {:terminal_refresh, term_name}
      )
    end

    {:noreply, socket}
  end

  def handle_info({:terminal_exited, ws_id, checkout_key, term_name, status}, socket) do
    if terminal_scope?(socket, ws_id, checkout_key) do
      send_update(HandbeanWeb.Live.TerminalPanel,
        id: "terminal-panel",
        action: {:terminal_exited, term_name, status}
      )
    end

    {:noreply, socket}
  end

  def handle_info({:terminal_exited, ws_id, term_name, status}, socket) do
    if ws_id == socket.assigns.current_workspace_id do
      send_update(HandbeanWeb.Live.TerminalPanel,
        id: "terminal-panel",
        action: {:terminal_exited, term_name, status}
      )
    end

    {:noreply, socket}
  end

  # Catch-all for unknown pubsub messages
  def handle_info({:ext_ui, %{event: "status", text: text}}, socket) do
    {:noreply, assign(socket, :ext_status_text, text)}
  end

  def handle_info({:ext_ui, %{event: "notify", type: type, text: text}}, socket) do
    {:noreply,
     socket
     |> put_flash(String.to_atom(type), text)
     |> assign(:ext_notification, %{type: type, text: text})}
  end

  def handle_info({:ext_ui, %{event: event, data: data}}, socket) do
    {:noreply, assign(socket, :ext_widget_data, %{event: event, data: data})}
  end

  def handle_info({:schedule_changed, _conv_id}, socket) do
    {:noreply, Schedules.reload(socket)}
  end

  def handle_info({:schedule_notice, conv_id, entry}, socket) do
    socket =
      if socket.assigns.current_conversation_id == conv_id do
        RuntimeProjection.timeline_insert(socket, entry)
      else
        socket
      end

    {:noreply, Schedules.reload(socket)}
  end

  def handle_info({:arm_browser_capture, token}, socket) do
    {:noreply, assign(socket, :browser_capture_token, token)}
  end

  def handle_info({:browser_surface_state, conversation_id, summary}, socket) do
    if browser_panel_current?(socket, conversation_id) do
      send_update(HandbeanWeb.WorkspaceLive.BrowserPanel,
        id: "browser-panel",
        surface: summary
      )
    end

    {:noreply, socket}
  end

  def handle_info({:browser_markers, conversation_id, markers}, socket) do
    if browser_panel_current?(socket, conversation_id) do
      {:noreply, push_event(socket, "browser_markers", %{annotations: markers})}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:browser_frame, conversation_id, frame}, socket) do
    if browser_panel_current?(socket, conversation_id) do
      {:noreply, push_event(socket, "browser_frame", frame)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:browser_annotation_ready, conversation_id, token, payload, path}, socket) do
    if socket.assigns.current_conversation_id == conversation_id and
         socket.assigns.browser_capture_token == token do
      {:noreply, deliver_browser_annotation(socket, payload, path)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(msg, socket) do
    Logger.debug("[WorkspaceLive] unhandled message: #{inspect(msg)}")
    {:noreply, socket}
  end

  defp navigate_after_delete(socket, nil), do: socket

  defp navigate_after_delete(%{assigns: %{chat_scope: :free}} = socket, conversation_id) do
    socket
    |> WorkspaceNavigation.enter_free_chat()
    |> RuntimeProjection.subscribe_session()
    |> restore_session()
    |> WorkspaceNavigation.close_mobile_sheets()
    |> push_patch(to: "/c/#{conversation_id}")
  end

  defp navigate_after_delete(socket, conversation_id) do
    workspace_id = socket.assigns.current_workspace_id

    socket
    |> WorkspaceNavigation.after_switch()
    |> RuntimeProjection.subscribe_session()
    |> restore_session()
    |> WorkspaceNavigation.close_mobile_sheets()
    |> push_patch(to: "/w/#{workspace_id}/c/#{conversation_id}")
  end

  defp terminal_scope?(socket, workspace_id, checkout_key) do
    current_key =
      case socket.assigns[:workspace_root] do
        path when is_binary(path) -> Handbean.CheckoutScope.key(path)
        _ -> nil
      end

    workspace_id == socket.assigns.current_workspace_id and checkout_key == current_key
  end

  defp browser_panel_current?(socket, conversation_id) do
    socket.assigns.current_conversation_id == conversation_id and
      socket.assigns.right_panel_view == :browser
  end

  defp deliver_browser_annotation(socket, payload, path) do
    {payload, attachments} = browser_screenshot(socket, payload, path)
    prompt = Handbean.BrowserAnnotation.format_prompt(payload)
    Composer.restore_draft(socket, %{content: prompt, attachments: attachments})
  end

  defp browser_screenshot(socket, payload, path) do
    too_many? = length(socket.assigns.pending_attachments) >= 4

    cond do
      too_many? or not is_binary(path) ->
        {%{payload | screenshot: false}, []}

      true ->
        case Composer.import_image_file(socket, path) do
          {:ok, attachment} ->
            {%{payload | screenshot: true}, [attachment]}

          {:error, _} ->
            {%{payload | screenshot: false}, []}
        end
    end
  end

  defp project_event(socket, event) do
    socket = RuntimeProjection.apply(socket, event)
    socket = maybe_refresh_workspace_identity(socket, event)

    socket =
      if schedule_tool_finished?(event) do
        Schedules.reload(socket)
      else
        socket
      end

    WorkspaceNavigation.finish_runtime(socket)
  end

  defp maybe_refresh_workspace_identity(socket, %{kind: kind})
       when kind in [:run_end, "run_end"] do
    case socket.assigns[:current_workspace_id] do
      workspace_id when is_binary(workspace_id) ->
        with {:ok, workspace} <- Handbean.WorkspaceStore.get(workspace_id),
             true <- workspace["kind"] == "directory",
             true <- File.exists?(Path.join(workspace["path"], ".git")),
             {:ok, refreshed} <- Handbean.WorkspaceStore.refresh_identity(workspace_id) do
          socket
          |> assign(:workspaces, Handbean.WorkspaceStore.list())
          |> assign(:workspace_path, refreshed["path"])
        else
          _ -> socket
        end

      _ ->
        socket
    end
  end

  defp maybe_refresh_workspace_identity(socket, _event), do: socket

  defp schedule_tool_finished?(%{kind: kind, payload: payload})
       when kind in [:tool_end, "tool_end"] do
    to_string(Handbean.Utils.SafeMap.get_any(payload, [:tool, "tool"]) || "") == "schedule"
  end

  defp schedule_tool_finished?(_event), do: false

  defp drop_composer_for_switch(socket, next_id \\ :new) do
    socket
    |> assign(:conversation_list_boot, nil)
    |> Composer.materialize_uploads()
    |> Composer.switch_conversation(next_id)
    |> CliSelection.prepare_switch()
  end

  defp restore_session(socket) do
    socket
    |> RuntimeProjection.restore_active_session()
    |> CliSelection.restore_current()
    |> WorkspaceNavigation.finish_runtime()
  end

  # ── Agent event dispatch ──

  # ── Auto-title generation (Qwen Code pattern) ──
  #
  # Start as soon as the user sends the first message. Waiting for :completed
  # leaves the sidebar on "New chat" for the whole agent run.

  # ── Conversation state helpers ──

  defp refresh_conversation_in_sidebar(socket, conv_id),
    do: ConversationSwitching.refresh_conversation_in_sidebar(socket, conv_id)

  defp apply_sidebar_title(socket, conv_id, title, source \\ "auto"),
    do: ConversationSwitching.apply_sidebar_title(socket, conv_id, title, source)

  defp running_for_current_conversation?(socket),
    do: ConversationState.running_for_current_conversation?(socket)

  # ── Tool event helpers ──

  # `@<subagent_type or child id> text` goes to a subagent of this conversation.
  # Anything else, including `@path` mentions, stays a normal message.

  defdelegate attachment_url(attachment), to: Composer
  defdelegate attachment_filename(attachment), to: Composer
  defdelegate image_attachment?(attachment), to: Composer

  defp timeline_entry_id(%{"id" => id}), do: id
  defp timeline_entry_id(%{id: id}), do: id

  defp find_change(timeline, change_id),
    do: HandbeanWeb.ChangeHelper.find_change(timeline, change_id)

  # ── Status helpers ──

  # ── Conversation token helpers ──

  # ── <think> tag stripping ──────────────────────────────────────────

  # ── Model resolution ──

  # Reload workspace models when switching workspaces.
  # Preserves the current selected_model only if still allowed in the new workspace.

  defp load_available_skills(socket) do
    if ConversationState.free_chat?(socket) do
      assign(socket, :available_skills, [])
    else
      case ConversationState.current_checkout_path(socket) do
        path when is_binary(path) -> Skills.load(socket, path)
        _ -> assign(socket, :available_skills, [])
      end
    end
  end

  # Resolve a composite model id to a human-readable display name.

  # Same display names stay distinguishable. Cursor stores one name for a base
  # model and its fast variant; the id is what actually differs.

  # ── /model command parser ──

  defp preview_line(line) when is_integer(line) and line > 0, do: line

  defp preview_line(line) when is_binary(line) do
    case Integer.parse(line) do
      {value, ""} when value > 0 -> value
      _ -> nil
    end
  end

  defp preview_line(_line), do: nil

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

  defp authoritative_widget_entry(conversation_id, entry_id)
       when is_binary(conversation_id) and is_binary(entry_id) do
    case Handbean.ConversationTranscriptStore.list(conversation_id) do
      {:ok, entries} -> Enum.find(entries, &(&1["id"] == entry_id))
      {:error, _reason} -> nil
    end
  end

  defp authoritative_widget_entry(_conversation_id, _entry_id), do: nil

  defp push_widget_command_result(socket, params, status, reason \\ nil) do
    result = %{
      request_id: widget_request_id(params),
      status: status
    }

    result = if reason, do: Map.put(result, :reason, Atom.to_string(reason)), else: result
    push_event(socket, "widget-command-result", result)
  end

  defp widget_request_id(%{"request_id" => request_id}) when is_binary(request_id),
    do: request_id

  defp widget_request_id(_params), do: ""

  defp speech_error_message("permission_denied"),
    do: gettext("Microphone access was denied. Allow it in system settings and try again.")

  defp speech_error_message("microphone_missing"),
    do: gettext("No microphone was found.")

  defp speech_error_message("microphone_busy"),
    do: gettext("The microphone is being used by another app.")

  defp speech_error_message("unsupported"),
    do: gettext("Voice recording is not supported by this browser.")

  defp speech_error_message("empty_recording"),
    do: gettext("No audio was recorded.")

  defp speech_error_message(_reason),
    do: gettext("Could not record audio. Please try again.")

  # ── PubSub subscription ──

  defp subscribe_to_conversation_updates(socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Handbean.PubSub, "conversation:updated")
    end

    socket
  end

  defp subscribe_speech(socket) do
    if connected?(socket) do
      Handbean.Speech.subscribe()
    end

    socket
  end

  defp subscribe_schedules(socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Handbean.PubSub, "runtime:schedules")
    end

    socket
  end

  defp subscribe_workspace_import(socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Handbean.PubSub, "workspace:import")
    end

    socket
  end

  # The native host (if any) owns the picker; a missing host is a no-op.

  defp in_app_ended_flash(task, reason) do
    %{
      body: in_app_ended_message(task, reason),
      navigate: in_app_ended_path(task),
      navigate_with: :patch
    }
  end

  defp in_app_ended_path(%{conversation_id: conv_id, workspace_id: ws_id})
       when is_binary(conv_id) and is_binary(ws_id) and conv_id != "" and ws_id != "" do
    "/w/#{ws_id}/c/#{conv_id}"
  end

  defp in_app_ended_path(_task), do: nil

  defp in_app_ended_message(task, reason) do
    title = task[:title] || gettext("conversation")

    case reason do
      :cancelled -> gettext("Agent stopped in %{title}.", title: title)
      :failed -> gettext("This run ended in %{title}.", title: title)
      _ -> gettext("Agent replied in %{title}.", title: title)
    end
  end

  # ── Conversation construction ──

  defp initial_conversation_id(conversations_by_ws, ws_id),
    do: ConversationSwitching.initial_conversation_id(conversations_by_ws, ws_id)

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

  defp log_workspace_boot(default_ws, workspaces, conversations_by_ws) do
    dev_log(
      "[WorkspaceLive] boot default_workspace=#{inspect(default_ws)} " <>
        "workspaces_file=#{Handbean.WorkspaceStore.storage_path()} " <>
        "workspaces=#{inspect(Enum.map(workspaces, &Map.take(&1, ["id", "name", "path", "default"])))} " <>
        "conversation_counts=#{inspect(Map.new(conversations_by_ws, fn {id, convs} -> {id, length(convs)} end))}"
    )
  end

  defp dev_log(message) do
    if dev_env?(), do: Logger.debug(message)
  end

  defp dev_env? do
    function_exported?(Mix, :env, 0) and Mix.env() == :dev
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

  defp resume_tool_approval(socket, action, remember) when action in [:approve, :deny] do
    pending = socket.assigns.pending_approval

    if cli_approval?(pending) do
      MessageSubmission.resume_cli_approval(socket, pending, action)
    else
      resume_handbean_approval(socket, action, remember)
    end
  end

  defp cli_approval?(pending) when is_map(pending) do
    Handbean.Utils.SafeMap.get_any(pending, :kind, "kind") in [:cli_agent, "cli_agent"]
  end

  defp cli_approval?(_pending), do: false

  defp resume_handbean_approval(socket, action, remember) when action in [:approve, :deny] do
    conv_id = socket.assigns.current_conversation_id
    pending = socket.assigns.pending_approval

    if is_binary(conv_id) and not is_nil(pending) do
      workspace_root = ConversationState.current_workspace_path(socket)

      case Approval.resume(conv_id, pending, action, remember, workspace_root) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("[WorkspaceLive] #{action} tools resume failed: #{inspect(reason)}")
      end

      {:noreply, assign(socket, :pending_approval, nil)}
    else
      {:noreply, socket}
    end
  end

  # ── Conversation stream helpers ──

  defp stream_conversations(socket, conversations_by_ws, workspaces),
    do: ConversationSwitching.stream_conversations(socket, conversations_by_ws, workspaces)

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
end
