defmodule HandbeanProbe.HomeScreen.Nav do
  @moduledoc """
  Where the user is: page, workspace, conversation. Owns the transitions
  between them (`open/3`, `apply_workspace/3`, `blank/1`) and the composer
  reset that every context switch implies. Other domains call back here when
  a transition is the outcome of their work.
  """

  use Gettext, backend: HandbeanProbe.Gettext
  import Mob.Socket, only: [assign: 2, assign: 3]

  alias HandbeanProbe.Bridge.Inbound

  alias HandbeanProbe.HomeScreen.{
    AppSettings,
    GitSettings,
    MCPSettings,
    Notice,
    Platform,
    Requests,
    Schedules,
    Settings,
    Share,
    State,
    WorkspaceMemory
  }

  alias HandbeanProbe.{
    NativeApproval,
    NativeArtifactDelivery,
    NativeChat,
    NativeClipboard,
    NativeFileViewer,
    NativeWorkspaces,
    NativeWorkspaceTree,
    ShareIntake
  }

  alias Handbean.{ConversationStore, WorkspaceStore}

  # ── dispatch ──

  def handle({:tap, {:conversation, id}}, socket) do
    case ConversationStore.get(id) do
      {:ok, conversation} ->
        if ConversationStore.free?(conversation) do
          open_free(socket, conversation)
        else
          open_workspace_conversation(socket, conversation)
        end

      _ ->
        Notice.put_error(socket, gettext("Conversation not found"))
    end
  end

  def handle({:tap, :toggle_inactive_history}, socket) do
    assign(socket, :inactive_history_open, not socket.assigns.inactive_history_open)
  end

  def handle({:tap, {:page, page}}, socket) do
    socket = socket |> assign(:page, page) |> Notice.clear()
    workspace = socket.assigns.workspace

    socket =
      cond do
        is_nil(workspace) ->
          socket

        page == :history ->
          reload_history(socket)

        page == :settings ->
          load_settings_hub(socket)

        page == :mcp ->
          MCPSettings.load(socket)

        page == :memory ->
          WorkspaceMemory.load(socket)

        page == :git ->
          GitSettings.load(socket)

        page == :app ->
          AppSettings.load(socket)

        page == :schedules ->
          Schedules.load(socket)

        Settings.settings_page?(page) ->
          Settings.load_models(socket)

        page == :workspace ->
          assign(socket, :workspaces, NativeWorkspaces.load(workspace))

        page == :files and free_chat?(socket) ->
          assign(socket, page: :chat)

        page == :files ->
          NativeWorkspaceTree.ensure(socket)

        true ->
          socket
      end

    sync_bean_clock(socket)
  end

  def handle({:tap, {:toggle_conversation_menu, id}}, socket) do
    menu_id = if socket.assigns.conversation_menu_id == id, do: nil, else: id
    assign(socket, :conversation_menu_id, menu_id)
  end

  def handle({:tap, :close_conversation_menu}, socket) do
    assign(socket, :conversation_menu_id, nil)
  end

  def handle({:tap, {:toggle_pin_conversation, id}}, socket) when is_binary(id) do
    socket = assign(socket, :conversation_menu_id, nil)

    case ConversationStore.get(id) do
      {:ok, conversation} ->
        result =
          if ConversationStore.pinned_conversation?(conversation),
            do: ConversationStore.unpin(id),
            else: ConversationStore.pin(id)

        case result do
          {:ok, _} -> reload_history(socket)
          _ -> Notice.put_error(socket, gettext("Conversation not found"))
        end

      _ ->
        Notice.put_error(socket, gettext("Conversation not found"))
    end
  end

  def handle({:tap, {:rename_conversation, id}}, socket) when is_binary(id) do
    case ConversationStore.get(id) do
      {:ok, conversation} ->
        socket
        |> assign(:conversation_menu_id, nil)
        |> assign(:rename_conversation, %{
          id: id,
          title: conversation["title"] || "",
          error: nil
        })

      _ ->
        assign(socket, :conversation_menu_id, nil)
    end
  end

  def handle({:tap, {:archive_conversation, id}}, socket) when is_binary(id) do
    socket = assign(socket, conversation_menu_id: nil, rename_conversation: nil)

    case ConversationStore.archive(id) do
      {:ok, _} -> reload_history(socket)
      _ -> Notice.put_error(socket, gettext("Conversation not found"))
    end
  end

  def handle({:tap, {:copy_conversation_id, id}}, socket) when is_binary(id) do
    socket = assign(socket, :conversation_menu_id, nil)

    socket
    |> NativeClipboard.put(id)
    |> Notice.put_info(gettext("Conversation ID copied"))
  end

  def handle({:tap, {:confirm_rename_conversation, title}}, socket) when is_binary(title) do
    confirm_rename(socket, title)
  end

  def handle({:tap, {:submit_rename, id, title}}, socket)
      when is_binary(id) and is_binary(title) do
    socket =
      case socket.assigns.rename_conversation do
        %{id: ^id} -> socket
        _ -> assign(socket, :rename_conversation, %{id: id, title: title, error: nil})
      end

    confirm_rename(socket, title)
  end

  def handle({:tap, :cancel_rename_conversation}, socket) do
    assign(socket, :rename_conversation, nil)
  end

  def handle({:change, {:rename_conversation_title, id}, title}, socket) when is_binary(id) do
    title = if is_binary(title), do: title, else: ""

    rename =
      case socket.assigns.rename_conversation do
        %{id: ^id} = pending -> %{pending | title: title, error: nil}
        _ -> %{id: id, title: title, error: nil}
      end

    assign(socket, :rename_conversation, rename)
  end

  def handle({:tap, {:toggle_history_group, id}}, socket) do
    groups = socket.assigns.collapsed_history_groups

    groups =
      if MapSet.member?(groups, id), do: MapSet.delete(groups, id), else: MapSet.put(groups, id)

    assign(socket, :collapsed_history_groups, groups)
  end

  def handle({:tap, {:new_workspace_conversation, workspace_id}}, socket)
      when is_binary(workspace_id) do
    case ConversationStore.create(workspace_id,
           title: gettext("New conversation"),
           inherit_from: inherit_from(socket, workspace_id)
         ) do
      {:ok, conversation} ->
        socket
        |> reload_history()
        |> open_workspace_conversation(conversation)

      _ ->
        Notice.put_error(
          socket,
          gettext("Could not create the conversation. Check available storage.")
        )
    end
  end

  def handle({:tap, {:workspace, id}}, socket) do
    case WorkspaceStore.get(id) do
      {:ok, workspace} ->
        apply_workspace(socket, workspace, NativeWorkspaces.resolve_conversation(workspace))

      _ ->
        Notice.put_error(socket, gettext("That workspace is no longer available"))
    end
  end

  def handle({:notification, %Inbound.Notification{} = notification}, socket) do
    %{conversation_id: id, workspace_id: workspace_id} = notification

    with true <- is_binary(id),
         {:ok, conversation} <- ConversationStore.get(id) do
      open_notification(socket, conversation, workspace_id)
    else
      _ ->
        unavailable_notification(socket)
    end
  end

  # ── transitions ──

  defp load_settings_hub(socket) do
    workspace = socket.assigns.workspace

    socket
    |> assign(:workspaces, NativeWorkspaces.load(workspace))
    |> Settings.load_models()
    |> WorkspaceMemory.load()
    |> MCPSettings.load()
    |> GitSettings.load()
    |> AppSettings.load()
  end

  defp confirm_rename(socket, title) do
    case socket.assigns.rename_conversation do
      %{id: id} = rename when is_binary(id) ->
        case ConversationStore.rename(id, title) do
          {:ok, meta} ->
            socket
            |> assign(:rename_conversation, nil)
            |> assign(:conversation_menu_id, nil)
            |> patch_open_title(id, meta["title"])
            |> reload_history()

          {:error, :empty} ->
            assign(socket, :rename_conversation, %{
              rename
              | title: title,
                error: gettext("Name cannot be empty")
            })

          {:error, :too_long} ->
            assign(socket, :rename_conversation, %{
              rename
              | title: title,
                error: gettext("Name cannot exceed 80 characters")
            })

          {:error, _} ->
            assign(socket, :rename_conversation, %{
              rename
              | title: title,
                error: gettext("Could not rename the conversation")
            })
        end

      _ ->
        socket
    end
  end

  defp patch_open_title(socket, id, title) when is_binary(title) do
    case socket.assigns.chat do
      %{conversation: %{"id" => ^id} = conversation} = chat ->
        assign(socket, :chat, %{chat | conversation: %{conversation | "title" => title}})

      _ ->
        socket
    end
  end

  defp patch_open_title(socket, _id, _title), do: socket

  defp reload_history(socket) do
    assign(socket,
      history: HandbeanProbe.NativeHistory.load(),
      conversation_activity: conversation_activity()
    )
    |> sync_bean_clock()
  end

  @doc false
  def advance_bean(socket) do
    socket = assign(socket, :bean_timer, nil)

    if bean_animating?(socket) do
      socket
      |> assign(:bean_frame, socket.assigns.bean_frame + 1)
      |> sync_bean_clock()
    else
      socket
    end
  end

  defp conversation_activity do
    Handbean.Runtime.TaskTracker.snapshot().tasks
    |> Enum.reduce(%{}, fn task, acc ->
      case activity_entry(task) do
        {id, status} -> Map.put(acc, id, status)
        nil -> acc
      end
    end)
  end

  defp activity_entry(%{status: status, conversation_id: id}) when is_binary(id) do
    case activity_status(status) do
      nil -> nil
      activity -> {id, activity}
    end
  end

  defp activity_entry(_task), do: nil

  defp activity_status(status) when status in [:running, "running"], do: :running

  defp activity_status(status)
       when status in [:waiting, :waiting_confirmation, "waiting", "waiting_confirmation"],
       do: :waiting

  defp activity_status(_status), do: nil

  defp sync_bean_clock(socket) do
    cond do
      not bean_animating?(socket) ->
        cancel_bean_clock(socket)

      socket.assigns.bean_timer ->
        socket

      true ->
        assign(socket, :bean_timer, Process.send_after(self(), :conversation_bean_frame, 125))
    end
  end

  defp cancel_bean_clock(socket) do
    if is_reference(socket.assigns.bean_timer),
      do: Process.cancel_timer(socket.assigns.bean_timer)

    assign(socket, :bean_timer, nil)
  end

  defp bean_animating?(socket) do
    socket.assigns.page == :history and
      Enum.any?(socket.assigns.conversation_activity, &match?({_id, :running}, &1))
  end

  defp open_workspace_conversation(socket, conversation) do
    case WorkspaceStore.get(conversation["workspace_id"]) do
      {:ok, workspace} ->
        if same_workspace?(socket, workspace) and not free_chat?(socket),
          do: open(socket, conversation),
          else: apply_workspace(socket, workspace, conversation)

      _ ->
        Notice.put_error(socket, gettext("Conversation not found"))
    end
  end

  defp same_workspace?(socket, workspace) do
    socket.assigns.workspace && socket.assigns.workspace["id"] == workspace["id"]
  end

  defp open_notification(socket, conversation, workspace_id) do
    cond do
      ConversationStore.free?(conversation) and not is_binary(workspace_id) ->
        open_free(socket, conversation)

      is_binary(workspace_id) and conversation["workspace_id"] == workspace_id ->
        case WorkspaceStore.get(workspace_id) do
          {:ok, workspace} -> apply_workspace(socket, workspace, conversation)
          _ -> unavailable_notification(socket)
        end

      true ->
        unavailable_notification(socket)
    end
  end

  defp unavailable_notification(socket) do
    Notice.put_error(socket, gettext("The conversation in the notification is unavailable"))
  end

  @doc "Show `conversation` in the current workspace. `keep_draft?` is the send path."
  def open(socket, conversation, keep_draft? \\ false) do
    a = socket.assigns
    drafts = NativeWorkspaces.put_draft(a.drafts, draft_workspace(socket), a.chat, a.draft)
    socket = assign(socket, :free_draft, false)

    unsubscribe(a.chat)
    Handbean.PubSub.Session.subscribe(conversation["id"])
    NativeWorkspaces.persist(a.workspace, conversation)

    draft =
      if keep_draft?,
        do: a.draft,
        else: NativeWorkspaces.get_draft(drafts, a.workspace, conversation)

    socket = if keep_draft?, do: socket, else: reset_composer(socket)

    drafts =
      if keep_draft?,
        do: NativeWorkspaces.clear_draft(drafts, a.workspace, nil),
        else: drafts

    socket
    |> assign(
      [
        chat: NativeChat.load(conversation),
        permission_mode: NativeApproval.mode(conversation),
        draft: draft,
        drafts: drafts,
        file_viewer: NativeFileViewer.new()
      ] ++ State.chat_reset()
    )
    |> NativeArtifactDelivery.reconcile_approval_exports()
    |> bump_workspace_open()
    |> Settings.load_models()
    |> sync_bean_clock()
  end

  @doc "Switch to `workspace`, showing `conversation` (or an empty chat)."
  def apply_workspace(socket, workspace, conversation) do
    a = socket.assigns
    drafts = NativeWorkspaces.put_draft(a.drafts, draft_workspace(socket), a.chat, a.draft)
    {_generation, socket} = Requests.bump(socket, :mcp_settings)
    {_generation, socket} = Requests.bump(socket, :git_settings)
    {_generation, socket} = Requests.bump(socket, :workspace_memory)

    unsubscribe(a.chat)
    socket = reset_composer(socket)
    selected = NativeWorkspaces.selection(workspace, conversation)
    NativeWorkspaces.persist(selected.workspace, conversation)

    socket =
      socket
      |> assign(:free_draft, false)
      |> assign(
        [
          workspace: selected.workspace,
          conversations: selected.conversations,
          permission_mode: selected.permission_mode,
          workspace_memory: HandbeanProbe.WorkspaceMemory.new(),
          mcp: HandbeanProbe.MCPSettings.empty(),
          git: HandbeanProbe.GitSettings.empty(),
          drafts: drafts,
          workspace_tree: NativeWorkspaceTree.for_workspace(selected.workspace, a.workspace_tree),
          file_viewer: NativeFileViewer.new()
        ] ++ State.chat_reset()
      )
      |> bump_workspace_open()
      |> Settings.load_models()

    case conversation do
      nil ->
        assign(socket,
          chat: nil,
          permission_mode: :prompt,
          draft: NativeWorkspaces.get_draft(drafts, selected.workspace, nil)
        )

      conversation ->
        Handbean.PubSub.Session.subscribe(conversation["id"])

        assign(socket,
          chat: NativeChat.load(conversation),
          permission_mode: NativeApproval.mode(conversation),
          draft: NativeWorkspaces.get_draft(drafts, selected.workspace, conversation)
        )
    end
    |> NativeArtifactDelivery.reconcile_approval_exports()
    |> sync_bean_clock()
  end

  @doc "Show a workspace-independent chat without switching the current workspace."
  def open_free(socket, conversation, keep_draft? \\ false) do
    a = socket.assigns
    drafts = NativeWorkspaces.put_draft(a.drafts, draft_workspace(socket), a.chat, a.draft)

    unsubscribe(a.chat)
    Handbean.PubSub.Session.subscribe(conversation["id"])

    draft =
      if keep_draft?,
        do: a.draft,
        else: NativeWorkspaces.get_draft(drafts, nil, conversation)

    socket = if keep_draft?, do: socket, else: reset_composer(socket)

    drafts =
      if keep_draft?,
        do: NativeWorkspaces.clear_draft(drafts, nil, nil),
        else: drafts

    socket
    |> assign(
      [
        chat: NativeChat.load(conversation),
        permission_mode: :prompt,
        draft: draft,
        drafts: drafts,
        free_draft: false,
        page: :chat,
        file_viewer: NativeFileViewer.new(),
        workspace_tree: NativeWorkspaceTree.idle()
      ] ++ State.chat_reset()
    )
    |> bump_workspace_open()
    |> Settings.load_models()
    |> sync_bean_clock()
  end

  @doc "Leave the current conversation for an empty chat without touching the composer."
  def blank(socket) do
    a = socket.assigns
    drafts = NativeWorkspaces.put_draft(a.drafts, draft_workspace(socket), a.chat, a.draft)

    unsubscribe(a.chat)
    if a.workspace && not free_chat?(socket), do: NativeWorkspaces.persist(a.workspace, nil)

    socket
    |> assign([chat: nil, drafts: drafts, draft: ""] ++ State.chat_reset())
    |> sync_bean_clock()
  end

  @doc "Create the conversation for a first send when none is open."
  def ensure_conversation(%{assigns: %{chat: nil, free_draft: true}} = socket) do
    case ConversationStore.create_free(title: conversation_title(socket)) do
      {:ok, conversation} -> {:ok, open_free(socket, conversation, true)}
      error -> error
    end
  end

  def ensure_conversation(%{assigns: %{chat: nil}} = socket) do
    workspace_id = socket.assigns.workspace["id"]

    case ConversationStore.create(workspace_id,
           title: conversation_title(socket),
           inherit_from: socket.assigns[:permission_inherit_from]
         ) do
      {:ok, conversation} ->
        {:ok, open(assign(socket, :permission_inherit_from, nil), conversation, true)}

      error ->
        error
    end
  end

  def ensure_conversation(socket), do: {:ok, socket}

  def current_conversation_id(socket) do
    case socket.assigns.chat do
      %{conversation: %{"id" => id}} -> id
      _ -> nil
    end
  end

  defp inherit_from(socket, workspace_id) do
    case socket.assigns.chat do
      %{conversation: %{"id" => id, "workspace_id" => ^workspace_id}} -> id
      _ -> socket.assigns[:permission_inherit_from]
    end
  end

  @doc """
  Drop draft attachments, in-flight platform requests, delivery bindings and
  merged share intakes (returned to review) when the chat context changes.
  """
  def reset_composer(socket) do
    a = socket.assigns
    Platform.cleanup_draft_files(a.pending_attachments)
    returning = MapSet.to_list(a.merged_intake_ids)

    socket
    |> cancel_composer_requests()
    |> NativeArtifactDelivery.cleanup_bindings()
    |> assign(
      pending_attachments: [],
      input_warning: nil,
      composer_open_id: nil,
      composer_select: nil,
      timeline_open: nil,
      merged_intake_ids: MapSet.new(),
      share_send: nil,
      approval_snapshots: %{},
      approval_export_inflight: MapSet.new(),
      deliver_mode: :steer,
      composer_mode: :chat,
      review_place: "",
      review_feeling: ""
    )
    |> then(&Notice.put(&1, Notice.clear_kind(&1.assigns.notice, :info)))
    |> Share.refresh(before: fn -> Enum.each(returning, &ShareIntake.return_to_review/1) end)
  end

  def unsubscribe(nil), do: :ok

  def unsubscribe(chat) do
    if ref = chat.reload_timer, do: Process.cancel_timer(ref)
    Handbean.PubSub.Session.unsubscribe(chat.conversation["id"])
  end

  def conversations(workspace), do: ConversationStore.list_for_workspace(workspace["id"])

  defp draft_workspace(socket) do
    if free_chat?(socket), do: nil, else: socket.assigns.workspace
  end

  def free_chat?(%{assigns: assigns}), do: free_chat?(assigns)

  def free_chat?(assigns) when is_map(assigns) do
    case assigns[:chat] do
      %{conversation: conversation} -> ConversationStore.free?(conversation)
      _ -> assigns[:free_draft] == true
    end
  end

  # Every in-flight request bound to the composer (platform requests keyed by
  # request id, `:share_send_marked` tasks) is dropped from the table and the
  # host side is told to cancel; then the scope moves on so late replies are
  # superseded.
  defp cancel_composer_requests(socket) do
    {entries, socket} = Requests.drop_scope(socket, :composer)

    Enum.each(entries, fn entry ->
      if is_binary(entry.ref),
        do: HandbeanProbe.Platform.cancel(self(), entry.ref, entry.generation)
    end)

    {_generation, socket} = Requests.bump(socket, :composer)
    socket
  end

  defp bump_workspace_open(socket) do
    {_generation, socket} = Requests.bump(socket, :workspace_open)
    socket
  end

  defp conversation_title(socket) do
    text = String.trim(socket.assigns.draft)

    cond do
      text != "" ->
        String.slice(text, 0, 40)

      match?([_ | _], socket.assigns.pending_attachments) ->
        # Draft attachments are string-keyed (`Platform.add_attachment/2`).
        att = hd(socket.assigns.pending_attachments)
        att["filename"] || gettext("Attachment")

      true ->
        gettext("New conversation")
    end
  end
end
