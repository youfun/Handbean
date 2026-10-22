defmodule HandbeanWeb.WorkspaceLive.Bootstrap do
  @moduledoc false

  use HandbeanWeb, :html

  import Phoenix.LiveView

  require Logger

  alias Handbean.Platform.FileManager
  alias HandbeanWeb.WorkspaceLive.CliSelection
  alias HandbeanWeb.WorkspaceLive.ConversationRouting
  alias HandbeanWeb.WorkspaceLive.ConversationState
  alias HandbeanWeb.WorkspaceLive.ConversationSwitching
  alias HandbeanWeb.WorkspaceLive.ModelSelection
  alias HandbeanWeb.WorkspaceLive.RuntimeProjection
  alias HandbeanWeb.WorkspaceLive.Schedules
  alias HandbeanWeb.WorkspaceLive.SessionMemory
  alias HandbeanWeb.WorkspaceLive.Skills
  alias HandbeanWeb.WorkspaceLive.WorkspaceNavigation

  def mount(params, socket, progress) do
    case Handbean.WorkspaceStore.ensure_default!() do
      {:ok, default_ws} ->
        mount_workspace(params, socket, progress, default_ws)

      {:error, reason} ->
        {:ok,
         socket
         |> assign(:page_title, gettext("Workspace configuration needs attention"))
         |> assign(:workspace_boot_error, reason)
         |> assign(:workspace_storage_path, Handbean.WorkspaceStore.storage_path())
         |> render_with(&render_error/1)}
    end
  end

  def render_error(assigns) do
    ~H"""
    <main class="p-4 max-w-2xl mx-auto text-primary" role="alert">
      <h1 class="text-lg font-semibold mb-4">{gettext("Workspace configuration needs attention")}</h1>
      <p :if={@workspace_boot_error == :workspace_format_outdated}>
        {gettext(
          "This configuration uses an older workspace format and cannot be opened by this version."
        )}
      </p>
      <p :if={@workspace_boot_error != :workspace_format_outdated}>
        {gettext(
          "Workspace initialization could not be completed. Check the configuration file and workspace access permissions."
        )}
      </p>
      <p class="mb-4 break-words">{@workspace_storage_path}</p>
      <p :if={@workspace_boot_error == :workspace_format_outdated}>
        {gettext("Your workspace configuration has not been changed.")}
      </p>
      <p>
        {gettext(
          "Back up this file and your workspace data, then restore a compatible configuration or use the Handbean version that created it. Retry after the configuration is repaired."
        )}
      </p>
      <.link href="/" class="inline-block mt-4 underline">{gettext("Retry")}</.link>
    </main>
    """
  end

  defp mount_workspace(params, socket, progress, default_ws) do
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
      |> subscribe_permission_policy()
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
      |> assign(:workspace_command_intent, nil)
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
        progress: progress
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
      |> assign(:collapsed_thread_ids, SessionMemory.collapsed_threads())
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
      |> ConversationRouting.restore_session()
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
            workspace_label: gettext("自由对话"),
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
        workspace_label: gettext("自由对话"),
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

  defp prewarm_search(workspace) do
    case Handbean.Search.prewarm(workspace) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[WorkspaceLive] search prewarm failed: #{inspect(reason)}")
    end
  end

  defp timeline_entry_id(%{"id" => id}), do: id
  defp timeline_entry_id(%{id: id}), do: id

  def load_available_skills(socket) do
    if ConversationState.free_chat?(socket) do
      assign(socket, :available_skills, [])
    else
      case ConversationState.current_checkout_path(socket) do
        path when is_binary(path) -> Skills.load(socket, path)
        _ -> assign(socket, :available_skills, [])
      end
    end
  end

  defp subscribe_to_conversation_updates(socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Handbean.PubSub, "conversation:updated")
      Handbean.Permissions.ConversationMode.subscribe()
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

  defp subscribe_permission_policy(socket) do
    if connected?(socket), do: Handbean.WorkspaceSettings.subscribe_permission_policy()
    socket
  end

  defp subscribe_workspace_import(socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Handbean.PubSub, "workspace:import")
    end

    socket
  end

  defp initial_conversation_id(conversations_by_ws, ws_id),
    do: ConversationSwitching.initial_conversation_id(conversations_by_ws, ws_id)

  def log_workspace_boot(default_ws, workspaces, conversations_by_ws) do
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

  defp stream_conversations(socket, conversations_by_ws, workspaces),
    do: ConversationSwitching.stream_conversations(socket, conversations_by_ws, workspaces)
end
