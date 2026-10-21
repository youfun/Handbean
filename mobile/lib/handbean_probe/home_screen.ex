defmodule HandbeanProbe.HomeScreen do
  @moduledoc """
  Native Mob chat shell. No LiveView or WebView in the product UI.

  This module only mounts, dispatches and renders. `socket.assigns` is a
  `HandbeanProbe.HomeScreen.State`; each message is routed to the domain that
  owns it (`Chat`, `Nav`, `Share`, `Platform`, `Delivery`, `FileNav`,
  `Settings`), and every domain `handle/2` is `socket -> socket`.

  Every message first passes `HandbeanProbe.Bridge.Inbound.decode/1`: host
  shapes (`engine_result`, `notification`, `files picked`) become structs,
  everything else passes through. Off-screen work started under
  `HandbeanProbe.TaskSupervisor` comes back as `{ref, {tag, generation, result}}`
  (see `HandbeanProbe.HomeScreen.Async`) and is correlated through
  `HandbeanProbe.HomeScreen.Requests` before it is routed by `tag`; stale or
  mismatched replies are dropped and the matching `:DOWN` is ignored.
  `{:pending_request_timeout, ref}` expires a request whose deadline passed.
  """

  use Mob.Screen
  use Gettext, backend: HandbeanProbe.Gettext

  require Logger

  alias HandbeanProbe.HomeScreen.{
    AppSettings,
    Async,
    Chat,
    Delivery,
    FileNav,
    GitSettings,
    MCPSettings,
    Nav,
    Notice,
    Platform,
    Render,
    Requests,
    Settings,
    Share,
    State,
    WorkspaceMemory
  }

  alias HandbeanProbe.{
    Bridge.Inbound,
    NativeApproval,
    NativeChanges,
    NativeWorkspaceTree,
    NativeWorkspaces,
    PendingRequests,
    ShareCopy
  }

  alias Handbean.Agent.Delegation
  alias Handbean.WorkspaceStore

  @toggles [
    :toggle_tool_work,
    :toggle_work_segment,
    :toggle_tool_output,
    :toggle_file_diff
  ]
  @chat_taps [
    :send,
    :stop,
    :new_chat,
    :new_free_chat,
    :dismiss_approval,
    :review_approval,
    :toggle_deliver_mode,
    :toggle_composer_mode,
    :generate_review
  ]
  @viewer_taps [:close_file_viewer, :file_viewer_open_external, :file_viewer_share]

  @workspace_taps [
    :open_create,
    :create_workspace,
    :workspace_list,
    :open_browse,
    :start_import,
    :cancel_import
  ]

  @timeout_message PendingRequests.timeout_message()

  # ── mount ──

  def mount(_params, _session, socket) do
    # Process-global so the shared Handbean.Gettext backend (e.g. Intent outcomes) follows too.
    Gettext.put_locale(HandbeanProbe.Gettext.locale())

    case WorkspaceStore.ensure_default!() do
      {:ok, default} ->
        Phoenix.PubSub.subscribe(Handbean.PubSub, "models:updated")
        {workspace, conversation} = NativeWorkspaces.restore(default)

        socket =
          socket
          |> put_state(
            workspace: workspace,
            permission_mode: NativeApproval.mode(workspace),
            conversations: Nav.conversations(workspace),
            workspaces: NativeWorkspaces.load(workspace)
          )
          |> Settings.load_models()

        socket = if conversation, do: Nav.open(socket, conversation), else: socket

        # Boot reconcile of interrupted copies runs in the same task as the first
        # listing so the review FIFO cannot be listed before it.
        {:ok, Share.refresh(socket, before: fn -> ShareCopy.reconcile(abandon_all: true) end)}

      _ ->
        {:ok,
         put_state(socket,
           workspace: nil,
           notice: Notice.error(gettext("Workspace initialization failed"))
         )}
    end
  end

  # Keys Mob placed in assigns before mount (e.g. safe area) survive on the struct.
  defp put_state(socket, overrides),
    do: %{socket | assigns: Map.merge(State.new(overrides), socket.assigns)}

  # ── dispatch ──

  def handle_info(message, socket) do
    case Inbound.decode(message) do
      {:ok, decoded} ->
        {:noreply, dispatch(decoded, socket)}

      {:error, reason} ->
        Inbound.drop(message, reason)
        {:noreply, socket}
    end
  end

  # async task replies (Task.Supervisor.async_nolink) and their :DOWN
  defp dispatch({ref, {tag, generation, result}}, socket)
       when is_reference(ref) and is_atom(tag) do
    Process.demonitor(ref, [:flush])
    task_result(socket, ref, tag, generation, result)
  end

  defp dispatch({ref, {tag, generation, target, result}}, socket)
       when is_reference(ref) and is_atom(tag) do
    Process.demonitor(ref, [:flush])
    task_result(socket, ref, tag, generation, {target, result})
  end

  defp dispatch({:DOWN, _ref, :process, _pid, _reason}, socket), do: socket

  defp dispatch({@timeout_message, ref}, socket) do
    case Requests.expire(socket, ref) do
      {:ok, %PendingRequests.Entry{kind: :subscription_poll_due, ctx: ctx} = entry, socket} ->
        if Requests.current?(socket, entry.scope, entry.generation),
          do: Settings.poll_due(socket, ctx),
          else: socket

      {:ok, entry, socket} ->
        Platform.handle_timeout(socket, entry)

      :error ->
        socket
    end
  end

  # chat
  defp dispatch({:change, :draft, _} = msg, socket), do: Chat.handle(msg, socket)
  defp dispatch({:change, :review_place, _} = msg, socket), do: Chat.handle(msg, socket)
  defp dispatch({:change, :review_feeling, _} = msg, socket), do: Chat.handle(msg, socket)
  defp dispatch({:submit, :send} = msg, socket), do: Chat.handle(msg, socket)
  defp dispatch({:top_reached, :load_older_history} = msg, socket), do: Chat.handle(msg, socket)

  defp dispatch({:tap, {:toggle_conversation_handoff, handoff_id}}, socket)
       when is_binary(handoff_id) do
    expanded = socket.assigns.expanded_handoffs || MapSet.new()

    expanded =
      if MapSet.member?(expanded, handoff_id),
        do: MapSet.delete(expanded, handoff_id),
        else: MapSet.put(expanded, handoff_id)

    Mob.Socket.assign(socket, :expanded_handoffs, expanded)
  end

  defp dispatch({:tap, {:prefill_subagent_message, agent_id}}, socket)
       when is_binary(agent_id) do
    socket
    |> Mob.Socket.assign(:page, :chat)
    |> Mob.Socket.assign(:draft, "@#{agent_id} ")
    |> Notice.clear()
  end

  defp dispatch({:tap, {:open_subagent_conversation, conversation_id, agent_id}}, socket) do
    case resolve_subagent_conversation(socket, conversation_id, agent_id) do
      {:ok, child_id} ->
        parent_id = Nav.current_conversation_id(socket)
        stack = socket.assigns.conversation_stack || []
        next = Nav.handle({:tap, {:conversation, child_id}}, socket)

        if Nav.current_conversation_id(next) == child_id and is_binary(parent_id) do
          Mob.Socket.assign(next, :conversation_stack, [parent_id | stack])
        else
          next
        end

      {:error, reason} ->
        Notice.put_error(socket, reason)
    end
  end

  defp dispatch({:tap, :close_subagent_conversation}, socket) do
    case socket.assigns.conversation_stack || [] do
      [parent_id | rest] ->
        socket = Nav.handle({:tap, {:conversation, parent_id}}, socket)
        Mob.Socket.assign(socket, :conversation_stack, rest)

      [] ->
        socket
    end
  end

  defp dispatch({:tap, {:workspace_panel_tab, tab}}, socket) when tab in [:changes, :files] do
    Mob.Socket.assign(socket, :workspace_panel_tab, tab)
  end

  defp dispatch({:tap, {:toggle_change, change_id}}, socket) when is_binary(change_id) do
    state = NativeChanges.toggle(socket.assigns, change_id)
    Mob.Socket.assign(socket, :changes_ui, state.changes_ui)
  end

  defp dispatch({:tap, {:confirm_revert_change, change_id}}, socket)
       when is_binary(change_id) do
    state = NativeChanges.confirm(socket.assigns, change_id)
    Mob.Socket.assign(socket, :changes_ui, state.changes_ui)
  end

  defp dispatch({:tap, :cancel_revert_change}, socket) do
    state = NativeChanges.cancel_confirm(socket.assigns)
    Mob.Socket.assign(socket, :changes_ui, state.changes_ui)
  end

  defp dispatch({:tap, {:revert_change, change_id}}, socket) when is_binary(change_id) do
    with {:ok, change} <- NativeChanges.find_change(socket.assigns, change_id),
         root when is_binary(root) <- workspace_path(socket.assigns.workspace) do
      state = NativeChanges.mark_reverting(socket.assigns, change_id)

      socket
      |> Mob.Socket.assign(:changes_ui, state.changes_ui)
      |> Async.run(:change_reverted, fn ->
        {change_id, NativeChanges.revert(change, root)}
      end)
    else
      _ ->
        state = NativeChanges.apply_revert_result(socket.assigns, change_id, {:error, :not_found})
        Mob.Socket.assign(socket, :changes_ui, state.changes_ui)
    end
  end

  defp dispatch({:tap, tap} = msg, socket) when tap in @chat_taps, do: Chat.handle(msg, socket)

  defp dispatch({:tap, {toggle, _}} = msg, socket) when toggle in @toggles,
    do: Chat.handle(msg, socket)

  defp dispatch({:tap, {:copy_relative_path, _}} = msg, socket), do: Chat.handle(msg, socket)

  defp dispatch({:tap, {:cancel_pending, _}} = msg, socket), do: Chat.handle(msg, socket)
  defp dispatch({:tap, {:resend_pending, _}} = msg, socket), do: Chat.handle(msg, socket)

  defp dispatch({:tap, {:tool_action, _, _, _}} = msg, socket), do: Chat.handle(msg, socket)
  defp dispatch({:tool_action_result, _, _} = msg, socket), do: Chat.handle(msg, socket)
  defp dispatch({:tap, {:composer_select, _}} = msg, socket), do: Chat.handle(msg, socket)
  defp dispatch({:tap, {:permission_mode, _}} = msg, socket), do: Chat.handle(msg, socket)
  defp dispatch({:tap, {:approval, _, _, _, _}} = msg, socket), do: Chat.handle(msg, socket)
  defp dispatch({:agent_event, _} = msg, socket), do: Chat.handle(msg, socket)
  defp dispatch({:reload_transcript, _} = msg, socket), do: Chat.handle(msg, socket)
  defp dispatch({:alert, :cancel_all_runs} = msg, socket), do: Chat.handle(msg, socket)

  # navigation
  defp dispatch({kind, :dismiss_input_warning}, socket) when kind in [:tap, :dismiss],
    do: Mob.Socket.assign(socket, :input_warning, nil)

  defp dispatch({:tap, :toggle_inactive_history} = msg, socket), do: Nav.handle(msg, socket)
  defp dispatch({:tap, {:conversation, _}} = msg, socket), do: Nav.handle(msg, socket)
  defp dispatch({:tap, {:page, _}} = msg, socket), do: Nav.handle(msg, socket)
  defp dispatch({:tap, {:workspace, _}} = msg, socket), do: Nav.handle(msg, socket)
  defp dispatch({:tap, {:toggle_conversation_menu, _}} = msg, socket), do: Nav.handle(msg, socket)
  defp dispatch({:tap, {:toggle_pin_conversation, _}} = msg, socket), do: Nav.handle(msg, socket)
  defp dispatch({:tap, {:rename_conversation, _}} = msg, socket), do: Nav.handle(msg, socket)
  defp dispatch({:tap, {:archive_conversation, _}} = msg, socket), do: Nav.handle(msg, socket)
  defp dispatch({:tap, {:toggle_history_group, _}} = msg, socket), do: Nav.handle(msg, socket)

  defp dispatch({:tap, {:new_workspace_conversation, _}} = msg, socket),
    do: Nav.handle(msg, socket)

  defp dispatch({:tap, {:confirm_rename_conversation, _}} = msg, socket),
    do: Nav.handle(msg, socket)

  defp dispatch({:tap, {:submit_rename, _, _}} = msg, socket), do: Nav.handle(msg, socket)
  defp dispatch({:tap, :cancel_rename_conversation} = msg, socket), do: Nav.handle(msg, socket)

  defp dispatch({:change, {:rename_conversation_title, _}, _} = msg, socket),
    do: Nav.handle(msg, socket)

  defp dispatch({:notification, _} = msg, socket), do: Nav.handle(msg, socket)

  # share intake
  defp dispatch({:share_intake_ready, _, _} = msg, socket), do: Share.handle(msg, socket)
  defp dispatch({:share_workspace_result, _} = msg, socket), do: Share.handle(msg, socket)
  defp dispatch({:share_rollback, _, _} = msg, socket), do: Share.handle(msg, socket)
  defp dispatch({:share_cleanup, _, _} = msg, socket), do: Share.handle(msg, socket)

  defp dispatch({:tap, {share, _}} = msg, socket)
       when share in [:share_confirm, :share_confirm_new, :share_discard],
       do: Share.handle(msg, socket)

  # platform requests, attachments, image cards
  defp dispatch({:change, field, _} = msg, socket)
       when field in [:artifact_path, :open_url_draft],
       do: Platform.handle(msg, socket)

  defp dispatch({:tap, {:platform, :begin, _}} = msg, socket), do: Platform.handle(msg, socket)
  defp dispatch({:platform, _, _} = msg, socket), do: Platform.handle(msg, socket)
  defp dispatch({:platform, _, _, _} = msg, socket), do: Platform.handle(msg, socket)

  defp dispatch(
         {:engine_result, %Inbound.EngineResult{request_id: request_id}} = msg,
         %{assigns: %{page: :app}} = socket
       ) do
    if Requests.ctx(socket, request_id)[:kind] == :app_settings do
      AppSettings.handle(msg, socket)
    else
      Platform.handle(msg, socket)
    end
  end

  defp dispatch({:engine_result, %Inbound.EngineResult{}} = msg, socket),
    do: Platform.handle(msg, socket)

  defp dispatch({:tap, {:remove_attachment, _}} = msg, socket), do: Platform.handle(msg, socket)
  defp dispatch({:tap, {:open_draft_image, _}} = msg, socket), do: Platform.handle(msg, socket)
  defp dispatch({:tap, {:open_sent_image, _, _}} = msg, socket), do: Platform.handle(msg, socket)

  defp dispatch({:tap, tap} = msg, socket) when tap in [:close_draft_image, :close_sent_image],
    do: Platform.handle(msg, socket)

  # system delivery
  defp dispatch({:tap, {:delivery, _}} = msg, socket), do: Delivery.handle(msg, socket)
  defp dispatch({:tap, {:delivery, _, _}} = msg, socket), do: Delivery.handle(msg, socket)

  # files, workspace page, directory picker
  defp dispatch({:tap, {:workspace_open, :view, _}} = msg, socket),
    do: FileNav.handle(msg, socket)

  defp dispatch({:workspace_open_ready, _, _} = msg, socket), do: FileNav.handle(msg, socket)

  defp dispatch({:tap, tap} = msg, socket) when tap in @viewer_taps,
    do: FileNav.handle(msg, socket)

  defp dispatch({:tap, {:file_tree, _}} = msg, socket), do: FileNav.handle(msg, socket)
  defp dispatch({:file_tree_listed, _} = msg, socket), do: FileNav.handle(msg, socket)
  defp dispatch({:change, :workspace_name, _} = msg, socket), do: FileNav.handle(msg, socket)

  defp dispatch({:tap, tap} = msg, socket) when tap in @workspace_taps,
    do: FileNav.handle(msg, socket)

  defp dispatch({:tap, {:browse, _}} = msg, socket), do: FileNav.handle(msg, socket)
  defp dispatch({:tap, {:toggle_path, _}} = msg, socket), do: FileNav.handle(msg, socket)
  defp dispatch({:files, _} = msg, socket), do: FileNav.handle(msg, socket)
  defp dispatch({:files, _, _} = msg, socket), do: FileNav.handle(msg, socket)
  defp dispatch({:directory_picker, _} = msg, socket), do: FileNav.handle(msg, socket)

  # workspace memory settings
  defp dispatch({:change, field, _} = msg, %{assigns: %{page: :memory}} = socket)
       when field in [:memory_query, :memory_edit_content],
       do: WorkspaceMemory.handle(msg, socket)

  defp dispatch({:dismiss, :memory_dismiss_confirm} = msg, %{assigns: %{page: :memory}} = socket),
    do: WorkspaceMemory.handle(msg, socket)

  defp dispatch({:tap, action} = msg, %{assigns: %{page: :memory}} = socket)
       when action in [
              :memory_save_edit,
              :memory_cancel_edit,
              :memory_delete,
              :memory_dismiss_confirm
            ],
       do: WorkspaceMemory.handle(msg, socket)

  defp dispatch({:tap, {action, _}} = msg, %{assigns: %{page: :memory}} = socket)
       when action in [
              :memory_builtin,
              :memory_scope,
              :memory_lifecycle,
              :memory_kind,
              :memory_related,
              :memory_edit_kind,
              :memory_promote,
              :memory_edit,
              :memory_ask_delete
            ],
       do: WorkspaceMemory.handle(msg, socket)

  defp dispatch({:tap, {:memory_copy, _, _}} = msg, %{assigns: %{page: :memory}} = socket),
    do: WorkspaceMemory.handle(msg, socket)

  # model / AI settings
  defp dispatch({:change, {:git_identity, _}, _} = msg, socket),
    do: GitSettings.handle(msg, socket)

  defp dispatch({:change, {:git_field, _}, _} = msg, socket), do: GitSettings.handle(msg, socket)

  defp dispatch({:dismiss, :git_dismiss_confirm} = msg, socket),
    do: GitSettings.handle(msg, socket)

  defp dispatch({:tap, action} = msg, %{assigns: %{page: :git}} = socket)
       when action in [
              :git_add,
              :git_save,
              :git_save_identity,
              :git_cancel,
              :git_ask_delete,
              :git_delete,
              :git_discard,
              :git_dismiss_confirm
            ],
       do: GitSettings.handle(msg, socket)

  defp dispatch({:tap, {action, _}} = msg, %{assigns: %{page: :git}} = socket)
       when action in [:git_edit, :git_default],
       do: GitSettings.handle(msg, socket)

  defp dispatch({:tap, action} = msg, %{assigns: %{page: :app}} = socket)
       when action in [:request_calendar, :open_app_settings],
       do: AppSettings.handle(msg, socket)

  defp dispatch({:change, {:mcp_field, _}, _} = msg, socket), do: MCPSettings.handle(msg, socket)

  defp dispatch({:dismiss, :mcp_dismiss_confirm} = msg, socket),
    do: MCPSettings.handle(msg, socket)

  defp dispatch({:tap, action} = msg, %{assigns: %{page: :mcp}} = socket)
       when action in [
              :mcp_add,
              :mcp_toggle_disabled,
              :mcp_test,
              :mcp_save,
              :mcp_cancel,
              :mcp_ask_delete,
              :mcp_delete,
              :mcp_discard,
              :mcp_dismiss_confirm
            ],
       do: MCPSettings.handle(msg, socket)

  defp dispatch({:tap, {action, _}} = msg, %{assigns: %{page: :mcp}} = socket)
       when action in [:mcp_edit, :mcp_auth, :mcp_access, :mcp_workspace],
       do: MCPSettings.handle(msg, socket)

  defp dispatch({:tap, {:composer_setting, field, _}} = msg, %{assigns: %{page: :chat}} = socket)
       when field in [:default_model, :reasoning],
       do: Settings.handle(msg, socket)

  defp dispatch({:change, {:model_field, _}, _} = msg, socket), do: Settings.handle(msg, socket)

  defp dispatch({:change, {:toggle_model_enabled, _, _, _}, _} = msg, socket),
    do: Settings.handle(msg, socket)

  defp dispatch({:dismiss, :cancel_confirm} = msg, socket), do: Settings.handle(msg, socket)

  defp dispatch({:dismiss, :cancel_subscription_login} = msg, socket),
    do: Settings.handle(msg, socket)

  defp dispatch({:models_updated} = msg, socket), do: Settings.handle(msg, socket)

  defp dispatch({:tap, _} = msg, %{assigns: %{page: page}} = socket) do
    if Settings.settings_page?(page), do: Settings.handle(msg, socket), else: socket
  end

  defp dispatch(:conversation_bean_frame, socket), do: Nav.advance_bean(socket)

  defp dispatch(_message, socket), do: socket

  # A tracked reply is routed only when `PendingRequests.take/3` accepts it:
  # the ref is registered, the wire generation equals the registered one and
  # the scope has not moved on. Untracked (`Async.fire/2`) replies are unknown
  # to the table and ignored; stale ones are logged and dropped.
  defp task_result(socket, ref, tag, generation, result) do
    case Requests.take(socket, ref, generation) do
      {:ok, %PendingRequests.Entry{kind: ^tag}, socket} ->
        async_result(tag, result, socket)

      {:ok, entry, socket} ->
        Logger.warning("[home] task reply #{tag} for #{entry.kind} entry dropped")
        socket

      {:error, :unknown, socket} ->
        socket

      {:error, reason, socket} ->
        Logger.debug("[home] stale task reply #{tag} dropped: #{inspect(reason)}")
        socket
    end
  end

  defp async_result(:share_intakes_ready, result, socket),
    do: Share.handle_ready(socket, result)

  defp async_result(:share_send_marked, result, socket) do
    case Share.handle_send_marked(socket, result) do
      {:send, socket, inbound_id, deliver_as, composer_mode} ->
        Chat.send_after_intake_pending(socket, inbound_id, deliver_as, composer_mode)

      {:noop, socket} ->
        socket
    end
  end

  defp async_result(:folder_listed, result, socket),
    do: FileNav.handle_folder_listed(socket, result)

  defp async_result(:model_settings_loaded, result, socket),
    do: Settings.handle_loaded(socket, result)

  defp async_result(:workspace_memory_loaded, result, socket),
    do: WorkspaceMemory.result(result, socket)

  defp async_result(:workspace_memory_mutated, result, socket),
    do: WorkspaceMemory.mutation_result(result, socket)

  defp async_result(:models_fetched, result, socket),
    do: Settings.handle_subscription(:models_fetched, result, socket)

  defp async_result(:model_settings_refs, {target, result}, socket),
    do: Settings.handle_refs(socket, target, result)

  defp async_result(kind, result, socket)
       when kind in [
              :subscription_started,
              :subscription_polled,
              :subscription_authorized,
              :subscription_discovered
            ],
       do: Settings.handle_subscription(kind, result, socket)

  defp async_result(kind, result, socket)
       when kind in [:mcp_loaded, :mcp_edited, :mcp_saved, :mcp_tested, :mcp_deleted],
       do: MCPSettings.result(kind, result, socket)

  defp async_result(kind, result, socket)
       when kind in [
              :git_loaded,
              :git_edited,
              :git_saved,
              :git_identity_saved,
              :git_deleted,
              :git_default_saved
            ],
       do: GitSettings.result(kind, result, socket)

  defp async_result(:change_reverted, {change_id, result}, socket) do
    state = NativeChanges.apply_revert_result(socket.assigns, change_id, result)

    socket
    |> Mob.Socket.assign(:changes_ui, state.changes_ui)
    |> refresh_workspace_tree_after_revert(result)
  end

  defp async_result(_kind, _result, socket), do: socket

  defp resolve_subagent_conversation(_socket, conversation_id, _agent_id)
       when is_binary(conversation_id) and conversation_id != "",
       do: {:ok, conversation_id}

  defp resolve_subagent_conversation(socket, _conversation_id, child_ref)
       when is_binary(child_ref) do
    parent_id = Nav.current_conversation_id(socket)

    with true <- is_binary(parent_id),
         {:ok, children} <- Delegation.status(parent_id, :list),
         child when not is_nil(child) <-
           Enum.find(children, &(child_ref in [&1.child_conversation_id, &1.subagent_type])) do
      {:ok, child.child_conversation_id}
    else
      _ -> {:error, "Subagent conversation is no longer available."}
    end
  end

  defp resolve_subagent_conversation(_socket, _conversation_id, _agent_id),
    do: {:error, "Subagent conversation is unavailable."}

  defp workspace_path(%{"path" => path}) when is_binary(path), do: path
  defp workspace_path(%{path: path}) when is_binary(path), do: path
  defp workspace_path(_workspace), do: nil

  defp refresh_workspace_tree_after_revert(socket, {:ok, _info}) do
    tree = socket.assigns.workspace_tree

    if is_map(tree) do
      tree = %{tree | dirs: %{}, expanded: MapSet.new(), error: nil}
      socket |> Mob.Socket.assign(:workspace_tree, tree) |> NativeWorkspaceTree.ensure()
    else
      socket
    end
  end

  defp refresh_workspace_tree_after_revert(socket, _result), do: socket

  # ── render ──

  def render(a), do: Render.render(a)
end
