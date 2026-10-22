defmodule HandbeanWeb.WorkspaceLive.ConversationSwitching do
  @moduledoc false

  use Gettext, backend: Handbean.Gettext

  import Phoenix.Component, only: [assign: 3, update: 3]
  import Phoenix.LiveView, only: [start_async: 3, stream: 4]

  alias HandbeanWeb.WorkspaceLive.ConversationState
  alias HandbeanWeb.WorkspaceLive.ConversationSwitching.CheckoutMetadata
  alias HandbeanWeb.WorkspaceLive.ConversationSwitching.ListProjection
  alias HandbeanWeb.WorkspaceLive.SessionMemory
  alias HandbeanWeb.WorkspaceLive.Schedules

  @free_key :free
  @sidebar_page_size 10

  defdelegate sidebar_limit(limits, bucket), to: ListProjection

  defp put_conversation(socket, conversation_id) do
    token =
      if socket.assigns[:current_conversation_id] == conversation_id do
        socket.assigns[:browser_capture_token]
      end

    changed? = socket.assigns[:current_conversation_id] != conversation_id

    socket =
      socket
      |> assign(:current_conversation_id, conversation_id)
      |> assign(:browser_capture_token, token)

    if changed? do
      socket
      |> Schedules.reset()
      |> Schedules.reload()
    else
      socket
    end
  end

  def assign_current(socket, ws, conversation_id) do
    checkout_path = checkout_path_for_assignment(ws, conversation_id)
    socket = update_terminal_subscription(socket, ws["id"], checkout_path)
    if is_binary(checkout_path), do: Handbean.Search.prewarm(checkout_path)

    socket
    |> assign(:chat_scope, :workspace)
    |> assign(:current_workspace_id, ws["id"])
    |> put_conversation(conversation_id)
    |> assign(:conversation_menu_id, nil)
    |> assign(:rename_conversation, nil)
    |> assign(:workspace_path, ws["path"])
    |> assign(:workspace_root, checkout_path)
    |> assign(:checkout_available?, is_binary(checkout_path))
    |> assign(:workspace_label, ws["name"])
    |> assign(:expanded_tool_groups, MapSet.new())
    |> assign(:pending_messages, %{})
    |> assign(:history_before, nil)
    |> assign(:history_has_more?, false)
    |> SessionMemory.remember()
  end

  defp update_terminal_subscription(socket, workspace_id, checkout_path) do
    if Phoenix.LiveView.connected?(socket) and socket.assigns[:show_terminal] do
      old_topic =
        terminal_topic(socket.assigns[:current_workspace_id], socket.assigns[:workspace_root])

      new_topic = terminal_topic(workspace_id, checkout_path)

      if is_binary(old_topic) and old_topic != new_topic,
        do: Phoenix.PubSub.unsubscribe(Handbean.PubSub, old_topic)

      if is_binary(new_topic), do: Phoenix.PubSub.subscribe(Handbean.PubSub, new_topic)
    end

    socket
  end

  defp terminal_topic(workspace_id, checkout_path)
       when is_binary(workspace_id) and is_binary(checkout_path) do
    Handbean.CheckoutScope.terminal_topic(workspace_id, Handbean.CheckoutScope.key(checkout_path))
  end

  defp terminal_topic(_workspace_id, _checkout_path), do: nil

  defp checkout_path_for_assignment(ws, nil), do: ws["default_checkout_path"]

  defp checkout_path_for_assignment(_ws, conversation_id) do
    case Handbean.ConversationStore.effective_checkout_path(conversation_id) do
      {:ok, checkout_path} -> checkout_path
      {:error, _reason} -> nil
    end
  end

  def select_workspace(socket, ws_id) do
    {:ok, ws} = refreshed_workspace(ws_id)
    Handbean.WorkspaceStore.touch(ws_id)

    {socket, conv} = ensure_active_conversation(socket, ws_id)
    socket = assign_current(socket, ws, ConversationState.conversation_id(conv))
    {socket, ConversationState.conversation_id(conv)}
  end

  def select_conversation(socket, ws_id, conv_id) do
    with {:ok, ws} <- refreshed_workspace(ws_id),
         {:ok, conversation} <-
           Handbean.ConversationStore.get(conv_id, include_timeline?: false),
         true <- conversation["workspace_id"] == ws_id do
      Handbean.WorkspaceStore.touch(ws_id)
      {assign_current(socket, ws, conv_id), conv_id}
    else
      _ -> {socket, nil}
    end
  end

  def select_archived_conversation(socket, ws_id, conv_id) do
    {:ok, ws} = refreshed_workspace(ws_id)
    {assign_current(socket, ws, conv_id), conv_id}
  end

  def select_new_workspace_without_conversation(
        socket,
        new_ws,
        workspaces,
        checkout_path \\ nil
      ) do
    conversations_by_ws =
      workspaces
      |> build_conversations_by_workspace(include_archived?: true)
      |> Map.put_new(new_ws["id"], [])

    conversations = Map.get(conversations_by_ws, new_ws["id"], [])
    checkout_path = checkout_path || new_ws["default_checkout_path"]

    conversation =
      existing_checkout_conversation(new_ws["id"], checkout_path) ||
        build_conversation(new_ws["id"], length(conversations) + 1, checkout_path)

    conversations_by_ws =
      Map.put(
        conversations_by_ws,
        new_ws["id"],
        ListProjection.insert_sidebar_conversation(conversations, conversation)
      )

    socket
    |> assign(:workspaces, workspaces)
    |> assign(:conversations_by_workspace, conversations_by_ws)
    |> reload_conversation_stream()
    |> assign_current(new_ws, ConversationState.conversation_id(conversation))
  end

  def ensure_current_conversation(socket, opts \\ []) do
    if current_conversation_present?(socket) do
      socket
    else
      if socket.assigns[:chat_scope] == :free do
        ensure_current_free_conversation(socket, opts)
      else
        ensure_current_workspace_conversation(socket, opts)
      end
    end
  end

  defp ensure_current_free_conversation(socket, opts) do
    conversations_by_ws =
      Map.put(
        socket.assigns.conversations_by_workspace,
        @free_key,
        load_free_conversations(include_archived?: true)
      )

    socket =
      socket
      |> assign(:conversations_by_workspace, conversations_by_ws)
      |> reload_conversation_stream()

    conversations = Map.get(socket.assigns.conversations_by_workspace, @free_key, [])

    {socket, conv} =
      case Enum.find(conversations, &(not archived_conversation?(&1))) do
        nil ->
          conversation = build_free_conversation(length(conversations) + 1)

          socket =
            update(socket, :conversations_by_workspace, fn conversations_by_workspace ->
              Map.put(
                conversations_by_workspace,
                @free_key,
                ListProjection.insert_sidebar_conversation(conversations, conversation)
              )
            end)

          {socket, conversation}

        conversation ->
          {socket, conversation}
      end

    socket
    |> assign_free(ConversationState.conversation_id(conv))
    |> reload_conversation_stream()
    |> ConversationState.sync_conv_state(opts)
  end

  defp ensure_current_workspace_conversation(socket, opts) do
    ws_id = socket.assigns.current_workspace_id

    conversations_by_ws =
      build_conversations_by_workspace(socket.assigns.workspaces, include_archived?: true)

    socket =
      socket
      |> assign(:conversations_by_workspace, conversations_by_ws)
      |> reload_conversation_stream()

    {socket, conv} = ensure_active_conversation(socket, ws_id)
    {:ok, workspace} = refreshed_workspace(ws_id)

    socket
    |> assign_current(workspace, ConversationState.conversation_id(conv))
    |> reload_conversation_stream()
    |> ConversationState.sync_conv_state(opts)
  end

  def refresh_after_archive(socket, archived_ids, free?, ws_id, opts \\ []) do
    if free? do
      refresh_free_after_archive(socket, archived_ids, opts)
    else
      refresh_workspace_after_archive(socket, archived_ids, ws_id, opts)
    end
  end

  def unarchive_conversation(socket, conv_id) do
    conversations_by_ws =
      case Handbean.ConversationStore.unarchive(conv_id) do
        {:ok, conv} ->
          if Handbean.ConversationStore.free?(conv) do
            Map.put(
              socket.assigns.conversations_by_workspace,
              @free_key,
              load_free_conversations(include_archived?: true)
            )
          else
            reload_workspace_conversations(socket)
          end

        _ ->
          socket.assigns.conversations_by_workspace
      end

    socket
    |> assign(:conversations_by_workspace, conversations_by_ws)
    |> reload_conversation_stream()
  end

  def conversations_pending_delete(socket, ids, opts \\ []) when is_list(ids) do
    conversations_by_ws =
      socket.assigns.workspaces
      |> build_conversations_by_workspace(include_archived?: true)
      |> Map.put(@free_key, load_free_conversations(include_archived?: true))

    socket =
      socket
      |> assign(:conversations_by_workspace, conversations_by_ws)
      |> assign(:conversation_menu_id, nil)
      |> assign(:rename_conversation, nil)
      |> reload_conversation_stream()

    if socket.assigns.current_conversation_id in ids do
      select_after_delete(socket, opts)
    else
      {socket, nil}
    end
  end

  defp select_after_delete(%{assigns: %{chat_scope: :free}} = socket, opts) do
    {socket, next} = ensure_active_free_conversation(socket)
    next_id = ConversationState.conversation_id(next)

    socket =
      socket
      |> assign_free(next_id)
      |> reload_conversation_stream()
      |> ConversationState.sync_conv_state(opts)
      |> ConversationState.sync_conv_to()

    {socket, next_id}
  end

  defp select_after_delete(socket, opts) do
    workspace_id = socket.assigns.current_workspace_id
    {socket, next} = ensure_active_conversation(socket, workspace_id)
    next_id = ConversationState.conversation_id(next)
    {:ok, workspace} = refreshed_workspace(workspace_id)

    socket =
      socket
      |> assign_current(workspace, next_id)
      |> reload_conversation_stream()
      |> ConversationState.sync_conv_state(opts)
      |> ConversationState.sync_conv_to()

    {socket, next_id}
  end

  def remove_workspace(socket, ws_id) do
    with {:ok, removed} <- Handbean.WorkspaceStore.remove(ws_id),
         {:ok, _archived} <- Handbean.ConversationStore.archive_for_workspace(ws_id) do
      workspaces = Handbean.WorkspaceStore.list()

      conversations_by_ws =
        workspaces
        |> build_conversations_by_workspace(include_archived?: true)
        |> Map.put(@free_key, load_free_conversations(include_archived?: true))
        |> Map.put(ws_id, orphaned_archived_conversations(ws_id))

      socket =
        socket
        |> assign(:workspaces, workspaces)
        |> assign(:conversations_by_workspace, conversations_by_ws)
        |> assign(:remove_workspace, nil)
        |> assign(:show_archive, true)
        |> reload_conversation_stream()

      {:ok, socket, removed}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp refresh_free_after_archive(socket, archived_ids, opts) do
    conversations_by_ws =
      Map.put(
        socket.assigns.conversations_by_workspace,
        @free_key,
        load_free_conversations(include_archived?: true)
      )

    socket =
      socket
      |> assign(:conversations_by_workspace, conversations_by_ws)
      |> reload_conversation_stream()

    if socket.assigns.chat_scope == :free and
         socket.assigns.current_conversation_id in archived_ids do
      {socket, next} = ensure_active_free_conversation(socket)
      next_id = ConversationState.conversation_id(next)

      socket =
        socket
        |> assign_free(next_id)
        |> reload_conversation_stream()
        |> ConversationState.sync_conv_state(opts)
        |> ConversationState.sync_conv_to()

      {socket, next_id}
    else
      {socket, nil}
    end
  end

  defp refresh_workspace_after_archive(socket, archived_ids, ws_id, opts) do
    socket =
      socket
      |> assign(:conversations_by_workspace, reload_workspace_conversations(socket))
      |> reload_conversation_stream()

    if socket.assigns.current_conversation_id in archived_ids do
      {socket, next} = ensure_active_conversation(socket, ws_id)
      next_id = ConversationState.conversation_id(next)
      {:ok, workspace} = refreshed_workspace(ws_id)

      socket =
        socket
        |> assign_current(workspace, next_id)
        |> reload_conversation_stream()
        |> ConversationState.sync_conv_state(opts)
        |> ConversationState.sync_conv_to()

      {socket, next_id}
    else
      {socket, nil}
    end
  end

  defp reload_workspace_conversations(socket) do
    free = Map.get(socket.assigns.conversations_by_workspace, @free_key, [])

    socket.assigns.workspaces
    |> build_conversations_by_workspace(include_archived?: true)
    |> Map.put(@free_key, free)
  end

  defp ensure_active_free_conversation(socket) do
    conversations = Map.get(socket.assigns.conversations_by_workspace, @free_key, [])

    case Enum.find(conversations, &(not archived_conversation?(&1))) do
      nil ->
        conversation = build_free_conversation(length(conversations) + 1)

        socket =
          update(socket, :conversations_by_workspace, fn conversations_by_workspace ->
            Map.put(
              conversations_by_workspace,
              @free_key,
              ListProjection.insert_sidebar_conversation(conversations, conversation)
            )
          end)

        {socket, conversation}

      conversation ->
        {socket, conversation}
    end
  end

  defp orphaned_archived_conversations(ws_id) do
    Handbean.ConversationStore.list_for_workspace(ws_id,
      include_archived?: true,
      include_timeline?: false
    )
    |> Enum.filter(&archived_conversation?/1)
  end

  def free_key, do: @free_key

  defdelegate load_free_conversations(opts \\ []), to: ListProjection

  def new_free_conversation(socket, opts \\ []) do
    conversations = Map.get(socket.assigns.conversations_by_workspace, @free_key, [])
    conversation = build_free_conversation(length(conversations) + 1)

    conversations_by_ws =
      Map.put(
        socket.assigns.conversations_by_workspace,
        @free_key,
        ListProjection.insert_sidebar_conversation(conversations, conversation)
      )

    socket =
      socket
      |> assign(:conversations_by_workspace, conversations_by_ws)
      |> reload_conversation_stream()
      |> assign_free(ConversationState.conversation_id(conversation))
      |> then(
        Keyword.get(
          opts,
          :initialize_model,
          &HandbeanWeb.WorkspaceLive.ModelSelection.initialize_conversation_model/1
        )
      )
      |> reset_new_conversation_projection(opts)
      |> ConversationState.sync_conv_to()

    {socket, ConversationState.conversation_id(conversation)}
  end

  def select_free_conversation(socket, conv_id) do
    {assign_free(socket, conv_id), conv_id}
  end

  def assign_free(socket, conversation_id) do
    socket = update_terminal_subscription(socket, nil, nil)

    socket
    |> assign(:chat_scope, :free)
    |> assign(:current_workspace_id, nil)
    |> put_conversation(conversation_id)
    |> assign(:conversation_menu_id, nil)
    |> assign(:rename_conversation, nil)
    |> assign(:workspace_path, nil)
    |> assign(:workspace_root, nil)
    |> assign(:checkout_available?, false)
    |> assign(:workspace_label, gettext("自由对话"))
    |> assign(:permission_mode, :deny)
    |> assign(:show_permission_menu, false)
    |> assign(:expanded_tool_groups, MapSet.new())
    |> assign(:pending_messages, %{})
    |> assign(:history_before, nil)
    |> assign(:history_has_more?, false)
    |> SessionMemory.remember()
  end

  defp refreshed_workspace(workspace_id) do
    case Handbean.WorkspaceStore.refresh_identity(workspace_id) do
      {:ok, workspace} -> {:ok, workspace}
      {:error, _reason} -> Handbean.WorkspaceStore.get(workspace_id)
    end
  end

  defp existing_checkout_conversation(workspace_id, checkout_path) do
    Handbean.ConversationStore.list_for_workspace(workspace_id,
      include_archived?: true,
      include_timeline?: false
    )
    |> Enum.find(fn conversation ->
      conversation["checkout_path"] == checkout_path and not archived_conversation?(conversation)
    end)
  end

  def begin_new_conversation(socket, workspace_id, opts \\ []) do
    {:ok, ws} = refreshed_workspace(workspace_id)
    checkouts = checkouts_for(ws)
    requested = Keyword.get(opts, :checkout_path)

    cond do
      is_binary(requested) and requested != "" ->
        {socket, conv_id} = new_conversation(socket, workspace_id, opts)
        {:created, socket, conv_id}

      match?(%{workspace_id: ^workspace_id}, socket.assigns[:checkout_picker]) ->
        {:picker, close_checkout_picker(socket)}

      length(checkouts) > 1 ->
        {:picker,
         assign(socket, :checkout_picker, %{
           workspace_id: workspace_id,
           checkouts: checkouts,
           source: Keyword.get(opts, :source, :sidebar)
         })}

      true ->
        {socket, conv_id} = new_conversation(socket, workspace_id, opts)
        {:created, socket, conv_id}
    end
  end

  def toggle_new_conversation_picker(socket) do
    case socket.assigns[:checkout_picker] do
      %{source: :header} ->
        close_checkout_picker(socket)

      _other ->
        assign(socket, :checkout_picker, %{
          workspace_id: nil,
          checkouts: [],
          source: :header,
          projects: new_conversation_projects(socket.assigns.workspaces)
        })
    end
  end

  defdelegate new_conversation_projects(workspaces), to: CheckoutMetadata

  def toggle_thread(socket, conversation_id) when is_binary(conversation_id) do
    socket
    |> update(:collapsed_thread_ids, fn collapsed ->
      collapsed = collapsed || MapSet.new()

      if MapSet.member?(collapsed, conversation_id),
        do: MapSet.delete(collapsed, conversation_id),
        else: MapSet.put(collapsed, conversation_id)
    end)
    |> SessionMemory.persist_collapsed_thread(conversation_id)
  end

  def show_more_conversations(socket, bucket) when is_binary(bucket) do
    if valid_sidebar_bucket?(socket, bucket) do
      slice = sidebar_slice(socket, bucket)
      limits = Map.get(socket.assigns, :sidebar_visible_limits, %{})

      assign(
        socket,
        :sidebar_visible_limits,
        Map.put(limits, bucket, slice.visible_limit + @sidebar_page_size)
      )
    else
      socket
    end
  end

  def show_more_conversations(socket, _bucket), do: socket

  defp valid_sidebar_bucket?(_socket, "free"), do: true

  defp valid_sidebar_bucket?(socket, bucket) do
    Enum.any?(socket.assigns.workspaces, &(&1["id"] == bucket))
  end

  defp sidebar_slice(socket, "free") do
    free_conversation_slice(
      socket.assigns.conversations_by_workspace,
      sidebar_limit(socket.assigns[:sidebar_visible_limits], "free"),
      socket.assigns.current_conversation_id
    )
  end

  defp sidebar_slice(socket, workspace_id) do
    workspace_conversation_slice(
      socket.assigns.conversations_by_workspace,
      workspace_id,
      socket.assigns.workspaces,
      socket.assigns[:collapsed_thread_ids],
      sidebar_limit(socket.assigns[:sidebar_visible_limits], workspace_id),
      socket.assigns.current_conversation_id
    )
  end

  def close_checkout_picker(socket), do: assign(socket, :checkout_picker, nil)

  defdelegate checkout_picker_open?(picker, workspace_id, source \\ :sidebar),
    to: CheckoutMetadata

  defp checkouts_for(ws), do: CheckoutMetadata.checkouts_for(ws)

  def new_conversation(socket, workspace_id, opts \\ []) do
    {:ok, ws} = refreshed_workspace(workspace_id)
    Handbean.WorkspaceStore.touch(workspace_id)

    conversations = Map.get(socket.assigns.conversations_by_workspace, workspace_id, [])
    checkout_path = Keyword.get(opts, :checkout_path) || inherited_checkout_path(socket, ws)

    inherit_from =
      if socket.assigns[:current_workspace_id] == workspace_id,
        do: socket.assigns[:current_conversation_id]

    conversation =
      build_conversation(workspace_id, length(conversations) + 1, checkout_path,
        inherit_from: inherit_from
      )

    conversations_by_ws =
      Map.put(
        socket.assigns.conversations_by_workspace,
        workspace_id,
        ListProjection.insert_sidebar_conversation(conversations, conversation)
      )

    socket =
      socket
      |> assign(:conversations_by_workspace, conversations_by_ws)
      |> reload_conversation_stream()
      |> assign_current(ws, ConversationState.conversation_id(conversation))
      |> then(
        Keyword.get(
          opts,
          :initialize_model,
          &HandbeanWeb.WorkspaceLive.ModelSelection.initialize_conversation_model/1
        )
      )
      |> reset_new_conversation_projection(opts)
      |> ConversationState.sync_conv_to()

    {socket, ConversationState.conversation_id(conversation)}
  end

  defp inherited_checkout_path(socket, ws) do
    if socket.assigns[:current_workspace_id] == ws["id"] and
         is_binary(socket.assigns[:current_conversation_id]) do
      case Handbean.ConversationStore.effective_checkout_path(
             socket.assigns.current_conversation_id
           ) do
        {:ok, checkout_path} -> checkout_path
        {:error, _reason} -> ws["default_checkout_path"]
      end
    else
      ws["default_checkout_path"]
    end
  end

  def refresh_conversation_in_sidebar(socket, conv_id) do
    case Handbean.ConversationStore.get(conv_id, include_timeline?: false) do
      {:ok, updated_conv} ->
        ws_id =
          if Handbean.ConversationStore.free?(updated_conv),
            do: @free_key,
            else: ConversationState.conv_value(updated_conv, "workspace_id", nil)

        convs = socket.assigns.conversations_by_workspace
        bucket = sidebar_bucket(convs, conv_id) || ws_id
        current_convs = Map.get(convs, bucket, [])

        updated_convs =
          if Enum.any?(current_convs, &(ConversationState.conversation_id(&1) == conv_id)) do
            current_convs
            |> Enum.map(fn existing ->
              if ConversationState.conversation_id(existing) == conv_id do
                merge_refreshed_title(existing, updated_conv)
              else
                existing
              end
            end)
            |> ListProjection.sort_sidebar_conversations()
          else
            ListProjection.insert_sidebar_conversation(current_convs, updated_conv)
          end

        socket
        |> assign(:conversations_by_workspace, Map.put(convs, bucket, updated_convs))
        |> reload_conversation_stream()

      {:error, :not_found} ->
        socket
    end
  end

  def apply_sidebar_title(socket, conv_id, title, source \\ "auto")
      when is_binary(conv_id) and is_binary(title) and is_binary(source) do
    convs = socket.assigns.conversations_by_workspace

    updated =
      Map.new(convs, fn {bucket, list} ->
        {bucket,
         Enum.map(list, fn conv ->
           if ConversationState.conversation_id(conv) == conv_id do
             conv
             |> ConversationState.put_conversation_value("title", title)
             |> ConversationState.put_conversation_value("title_source", source)
           else
             conv
           end
         end)}
      end)

    socket
    |> assign(:conversations_by_workspace, updated)
    |> reload_conversation_stream()
  end

  defp sidebar_bucket(convs, conv_id) do
    Enum.find_value(convs, fn {bucket, list} ->
      if Enum.any?(list, &(ConversationState.conversation_id(&1) == conv_id)), do: bucket
    end)
  end

  # A store read can still show "New chat" if it races the title write. Do not
  # replace a title the sidebar already received.
  defp merge_refreshed_title(existing, updated) do
    existing_title = ConversationState.conv_value(existing, "title", "")
    updated_title = ConversationState.conv_value(updated, "title", "")

    if String.starts_with?(to_string(updated_title), "New chat") and
         not String.starts_with?(to_string(existing_title), "New chat") do
      updated
      |> ConversationState.put_conversation_value("title", existing_title)
      |> ConversationState.put_conversation_value(
        "title_source",
        ConversationState.conv_value(existing, "title_source", "auto")
      )
    else
      updated
    end
  end

  defdelegate fetch_conversations(workspaces), to: ListProjection

  def load_conversation_list(socket) do
    workspaces = Enum.map(socket.assigns.workspaces, &Map.take(&1, ["id", "path"]))
    revision = Map.get(socket.assigns, :conversation_list_revision, 0) + 1

    socket
    |> assign(:conversation_list_revision, revision)
    |> assign(:conversation_list_task_revision, revision)
    |> assign(:conversation_list_loading, true)
    |> assign(:conversation_list_error, nil)
    |> start_async(:conversation_list, fn ->
      {revision, fetch_conversations(workspaces)}
    end)
  end

  defdelegate initial_conversation_id(conversations_by_ws, ws_id), to: ListProjection

  def build_conversation(workspace_id, num, checkout_path \\ nil, opts \\ []) do
    title = conversation_title(num)

    create_opts =
      [title: title]
      |> then(fn create_opts ->
        if is_binary(checkout_path),
          do: Keyword.put(create_opts, :checkout_path, checkout_path),
          else: create_opts
      end)
      |> then(fn create_opts ->
        case Keyword.get(opts, :inherit_from) do
          id when is_binary(id) and id != "" ->
            Keyword.put(create_opts, :inherit_from, id)

          _missing ->
            create_opts
        end
      end)

    {:ok, conversation} = Handbean.ConversationStore.create(workspace_id, create_opts)
    conversation
  end

  def build_free_conversation(num) do
    title = conversation_title(num)
    {:ok, conversation} = Handbean.ConversationStore.create_free(title: title)
    conversation
  end

  defdelegate build_conversations_by_workspace(workspaces, opts), to: ListProjection

  def ensure_active_conversation(socket, workspace_id) do
    conversations = Map.get(socket.assigns.conversations_by_workspace, workspace_id, [])

    case ListProjection.first_active_conversation(conversations) do
      nil ->
        {:ok, workspace} = refreshed_workspace(workspace_id)

        conversation =
          build_conversation(
            workspace_id,
            length(conversations) + 1,
            workspace["default_checkout_path"]
          )

        socket =
          update(socket, :conversations_by_workspace, fn conversations_by_workspace ->
            Map.put(
              conversations_by_workspace,
              workspace_id,
              ListProjection.insert_sidebar_conversation(conversations, conversation)
            )
          end)

        {socket, conversation}

      conversation ->
        {socket, conversation}
    end
  end

  def stream_conversations(socket, conversations_by_ws, workspaces) do
    items = ListProjection.stream_items(conversations_by_ws, workspaces)
    stream(socket, :conversations, items, reset: true)
  end

  def reload_conversation_stream(socket) do
    socket =
      assign(
        socket,
        :conversation_list_revision,
        Map.get(socket.assigns, :conversation_list_revision, 0) + 1
      )

    stream_conversations(
      socket,
      socket.assigns.conversations_by_workspace,
      socket.assigns.workspaces
    )
  end

  defdelegate archived_conversations(workspaces, conversations_by_workspace),
    to: ListProjection

  defdelegate free_conversations(conversations_by_workspace), to: ListProjection

  defdelegate free_conversation_slice(conversations_by_workspace, limit, current_conversation_id),
    to: ListProjection

  defdelegate workspace_conversations(conversations_by_workspace, ws_id, workspaces),
    to: ListProjection

  defdelegate visible_workspace_conversations(
                conversations_by_workspace,
                ws_id,
                workspaces,
                collapsed_thread_ids
              ),
              to: ListProjection

  defdelegate workspace_conversation_slice(
                conversations_by_workspace,
                ws_id,
                workspaces,
                collapsed_thread_ids,
                limit,
                current_conversation_id
              ),
              to: ListProjection

  defdelegate pinned_conversations(workspaces, conversations_by_workspace),
    to: ListProjection

  defdelegate archived_stream_count(stream_entries), to: ListProjection
  defdelegate archived_conversation?(conversation), to: ListProjection
  defdelegate pinned_conversation?(conversation), to: ListProjection

  defdelegate hover_context(conversation), to: CheckoutMetadata
  defdelegate repo_name(path), to: CheckoutMetadata

  defp reset_new_conversation_projection(socket, opts) do
    socket
    |> assign(:input_value, "")
    |> assign(:running, false)
    |> assign(:running_conversation_id, nil)
    |> assign(:tools_active, %{})
    |> assign(:editor_files, [])
    |> assign(:active_file, nil)
    |> assign(:file_preview, nil)
    |> assign(:file_preview_error, nil)
    |> assign(:preview_line, nil)
    |> assign(:revert_confirm_change_id, nil)
    |> assign(:revert_message, nil)
    |> assign(:timeline, [])
    |> assign(:expanded_tool_groups, MapSet.new())
    |> stream(:timeline, [], reset: true)
    |> assign(:current_assistant_entry_id, nil)
    |> assign(:thinking_content, "")
    |> assign(:think_buffer, "")
    |> update_status_for_new_conversation(opts)
  end

  defp update_status_for_new_conversation(socket, opts) do
    available_models = Map.get(socket.assigns, :available_models, [])
    selected_model = Map.get(socket.assigns, :selected_model)
    display_name = model_display_name(selected_model, available_models, opts)

    overrides = %{
      model: display_name,
      status: :idle,
      input_tokens: 0,
      output_tokens: 0,
      cache_read_tokens: 0,
      cache_write_tokens: 0,
      turns: 0
    }

    case Keyword.get(opts, :update_status) do
      fun when is_function(fun, 2) -> fun.(socket, overrides)
      _ -> assign(socket, :status_info, Map.merge(socket.assigns.status_info, overrides))
    end
  end

  defp model_display_name(selected_model, available_models, opts) do
    case Keyword.get(opts, :model_display_name) do
      fun when is_function(fun, 2) ->
        fun.(selected_model, available_models)

      _ ->
        HandbeanWeb.WorkspaceLive.ModelSelection.model_display_name(
          selected_model,
          available_models
        )
    end
  end

  defp current_conversation_present?(socket) do
    conv_id = socket.assigns.current_conversation_id

    bucket =
      if socket.assigns[:chat_scope] == :free,
        do: @free_key,
        else: socket.assigns.current_workspace_id

    convs = Map.get(socket.assigns.conversations_by_workspace, bucket, [])

    is_binary(conv_id) and
      Enum.any?(convs, &(ConversationState.conversation_id(&1) == conv_id))
  end

  defp conversation_title(1), do: "New chat"
  defp conversation_title(num), do: "New chat ##{num}"
end
