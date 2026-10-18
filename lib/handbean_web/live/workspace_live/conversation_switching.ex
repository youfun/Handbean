defmodule HandbeanWeb.WorkspaceLive.ConversationSwitching do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3, update: 3]
  import Phoenix.LiveView, only: [stream: 4, start_async: 3]

  require Logger

  alias HandbeanWeb.WorkspaceLive.ConversationState
  alias HandbeanWeb.WorkspaceLive.SessionMemory
  alias HandbeanWeb.WorkspaceLive.Schedules

  @free_key :free
  @sidebar_page_size 10

  def sidebar_limit(limits, bucket) when is_map(limits) do
    case Map.get(limits, to_string(bucket), @sidebar_page_size) do
      limit when is_integer(limit) and limit > 0 -> limit
      _ -> @sidebar_page_size
    end
  end

  def sidebar_limit(_limits, _bucket), do: @sidebar_page_size

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
        insert_sidebar_conversation(conversations, conversation)
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
                insert_sidebar_conversation(conversations, conversation)
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

  def archive_conversation(socket, conv_id, ws_id, opts \\ []) do
    case Handbean.ConversationStore.get(conv_id, include_timeline?: false) do
      {:ok, conv} ->
        if Handbean.ConversationStore.free?(conv) do
          archive_free_conversation(socket, conv_id, opts)
        else
          archive_workspace_conversation(socket, conv_id, ws_id || conv["workspace_id"], opts)
        end

      _ ->
        {socket, nil}
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

  defp archive_free_conversation(socket, conv_id, opts) do
    _ = Handbean.ConversationStore.archive(conv_id)

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

    if socket.assigns.chat_scope == :free and socket.assigns.current_conversation_id == conv_id do
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

  defp archive_workspace_conversation(socket, conv_id, ws_id, opts) do
    _ = Handbean.ConversationStore.archive(conv_id)

    socket =
      socket
      |> assign(:conversations_by_workspace, reload_workspace_conversations(socket))
      |> reload_conversation_stream()

    if socket.assigns.current_conversation_id == conv_id do
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
              insert_sidebar_conversation(conversations, conversation)
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

  def load_free_conversations(opts \\ []) do
    include_archived? = Keyword.get(opts, :include_archived?, false)

    conversation_summaries(@free_key, opts)
    |> Enum.filter(&persisted_conversation?/1)
    |> filter_archived(include_archived?)
    |> Enum.sort_by(&(&1["updated_at"] || ""), :desc)
    |> Enum.reject(fn conv ->
      String.starts_with?(ConversationState.conv_value(conv, "title", ""), "New chat") and
        ConversationState.conv_value(conv, "title_source", nil) in [nil, "manual"] and
        transcript_empty?(ConversationState.conversation_id(conv))
    end)
  end

  def new_free_conversation(socket, opts \\ []) do
    conversations = Map.get(socket.assigns.conversations_by_workspace, @free_key, [])
    conversation = build_free_conversation(length(conversations) + 1)

    conversations_by_ws =
      Map.put(
        socket.assigns.conversations_by_workspace,
        @free_key,
        insert_sidebar_conversation(conversations, conversation)
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
    |> assign(:workspace_label, "Chats")
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

  def new_conversation_projects(workspaces) when is_list(workspaces) do
    Enum.map(workspaces, fn ws ->
      %{
        id: ws["id"],
        name: ws["name"] || ws["id"],
        path: ws["path"],
        checkouts: checkouts_for(ws)
      }
    end)
  end

  def new_conversation_projects(_workspaces), do: []

  def toggle_thread(socket, conversation_id) when is_binary(conversation_id) do
    update(socket, :collapsed_thread_ids, fn collapsed ->
      collapsed = collapsed || MapSet.new()

      if MapSet.member?(collapsed, conversation_id),
        do: MapSet.delete(collapsed, conversation_id),
        else: MapSet.put(collapsed, conversation_id)
    end)
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

  def checkout_picker_open?(picker, workspace_id, source \\ :sidebar)

  def checkout_picker_open?(nil, _workspace_id, _source), do: false

  def checkout_picker_open?(%{workspace_id: open_id, source: open_source}, workspace_id, source),
    do: open_id == workspace_id and open_source == source

  def checkout_picker_open?(_picker, _workspace_id, _source), do: false

  defp checkouts_for(ws) do
    root = ws["path"] || ws["default_checkout_path"]

    case Handbean.RepoIdentity.list_checkouts(root) do
      {:ok, checkouts} -> checkouts
      {:error, _reason} -> []
    end
  end

  def new_conversation(socket, workspace_id, opts \\ []) do
    {:ok, ws} = refreshed_workspace(workspace_id)
    Handbean.WorkspaceStore.touch(workspace_id)

    conversations = Map.get(socket.assigns.conversations_by_workspace, workspace_id, [])
    checkout_path = Keyword.get(opts, :checkout_path) || inherited_checkout_path(socket, ws)
    conversation = build_conversation(workspace_id, length(conversations) + 1, checkout_path)

    conversations_by_ws =
      Map.put(
        socket.assigns.conversations_by_workspace,
        workspace_id,
        insert_sidebar_conversation(conversations, conversation)
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
            |> sort_sidebar_conversations()
          else
            insert_sidebar_conversation(current_convs, updated_conv)
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

  def fetch_conversations(workspaces) do
    with {:ok, summaries} <- Handbean.ConversationStore.fetch_summaries() do
      grouped =
        Enum.group_by(summaries, fn summary ->
          if Handbean.ConversationStore.free?(summary),
            do: @free_key,
            else: summary["workspace_id"]
        end)

      opts = [include_archived?: true, summaries_by_workspace: grouped]

      {:ok,
       workspaces
       |> build_conversations_by_workspace(opts)
       |> Map.put(@free_key, load_free_conversations(opts))}
    end
  end

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

  def initial_conversation_id(conversations_by_ws, ws_id) do
    conversations_by_ws
    |> Map.get(ws_id, [])
    |> first_active_conversation()
    |> case do
      nil -> nil
      conversation -> ConversationState.conversation_id(conversation)
    end
  end

  def build_conversation(workspace_id, num, checkout_path \\ nil) do
    title = conversation_title(num)

    opts =
      [title: title]
      |> then(fn opts ->
        if is_binary(checkout_path),
          do: Keyword.put(opts, :checkout_path, checkout_path),
          else: opts
      end)

    {:ok, conversation} = Handbean.ConversationStore.create(workspace_id, opts)
    conversation
  end

  def build_free_conversation(num) do
    title = conversation_title(num)
    {:ok, conversation} = Handbean.ConversationStore.create_free(title: title)
    conversation
  end

  def build_conversations_by_workspace(workspaces, opts) do
    include_archived? = Keyword.get(opts, :include_archived?, false)

    workspaces
    |> Enum.map(fn ws ->
      ws_id = ws["id"]

      convs =
        conversation_summaries(ws_id, opts)
        |> Enum.filter(&persisted_conversation?/1)
        |> filter_archived(include_archived?)
        |> Enum.sort_by(&(&1["updated_at"] || ""), :desc)
        |> Enum.reject(fn conv ->
          String.starts_with?(ConversationState.conv_value(conv, "title", ""), "New chat") and
            ConversationState.conv_value(conv, "title_source", nil) in [nil, "manual"] and
            transcript_empty?(ConversationState.conversation_id(conv))
        end)

      dev_log(
        "[WorkspaceLive] loaded conversations workspace_id=#{inspect(ws_id)} " <>
          "workspace_path=#{inspect(ws["path"])} include_archived?=#{include_archived?} " <>
          "count=#{length(convs)} ids=#{inspect(Enum.map(convs, &ConversationState.conversation_id/1))}"
      )

      {ws_id, maybe_sort_conversations(convs, include_archived?)}
    end)
    |> Map.new()
  end

  defp conversation_summaries(workspace_id, opts) do
    case Keyword.fetch(opts, :summaries_by_workspace) do
      {:ok, grouped} -> Map.get(grouped, workspace_id, [])
      :error when workspace_id == @free_key -> Handbean.ConversationStore.list_free_summaries()
      :error -> Handbean.ConversationStore.list_summaries(workspace_id)
    end
  end

  defp persisted_conversation?(conversation) do
    conversation
    |> ConversationState.conversation_id()
    |> Handbean.ConversationStore.exists?()
  end

  def ensure_active_conversation(socket, workspace_id) do
    conversations = Map.get(socket.assigns.conversations_by_workspace, workspace_id, [])

    case first_active_conversation(conversations) do
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
              insert_sidebar_conversation(conversations, conversation)
            )
          end)

        {socket, conversation}

      conversation ->
        {socket, conversation}
    end
  end

  def stream_conversations(socket, conversations_by_ws, workspaces) do
    ws_names = Map.new(workspaces, fn ws -> {ws["id"], ws["name"]} end)

    items =
      conversations_by_ws
      |> Enum.flat_map(fn {ws_id, convs} ->
        Enum.map(convs, fn conv ->
          %{
            id: ConversationState.conversation_id(conv),
            title: ConversationState.conv_value(conv, "title", "New chat"),
            workspace_id: stream_workspace_id(ws_id),
            workspace_name: stream_workspace_name(ws_id, ws_names),
            scope: if(ws_id == @free_key, do: "free", else: "workspace"),
            archived: archived_conversation?(conv)
          }
        end)
      end)
      |> Enum.sort_by(&{&1.archived, &1.title})

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

  def archived_conversations(workspaces, conversations_by_workspace)
      when is_list(workspaces) and is_map(conversations_by_workspace) do
    ws_map =
      Map.new(workspaces, fn ws ->
        {ws["id"], ws["name"] || ws["id"]}
      end)

    conversations_by_workspace
    |> Enum.flat_map(fn {ws_id, convs} ->
      {workspace_id, label, scope} = archived_bucket(ws_id, ws_map)

      convs
      |> Enum.filter(&archived_conversation?/1)
      |> Enum.map(fn c ->
        archived_row(c, workspace_id, label, scope)
      end)
    end)
    |> Enum.sort_by(& &1.updated_at, :desc)
  end

  defp archived_row(conv, workspace_id, label, scope) do
    row = %{
      id: ConversationState.conversation_id(conv),
      title: ConversationState.conv_value(conv, "title", "Archived"),
      workspace_id: workspace_id,
      workspace_label: label,
      scope: scope,
      updated_at: ConversationState.conv_value(conv, "updated_at", "")
    }

    Map.put(row, :age, HandbeanWeb.WorkspaceLive.ViewComponents.short_relative_time(row))
  end

  defp archived_bucket(@free_key, _ws_map), do: {nil, "对话", "free"}

  defp archived_bucket(ws_id, ws_map),
    do: {ws_id, Map.get(ws_map, ws_id, ws_id), "workspace"}

  def free_conversations(conversations_by_workspace) when is_map(conversations_by_workspace) do
    conversations_by_workspace
    |> Map.get(@free_key, [])
    |> Enum.reject(&archived_conversation?/1)
    |> sort_sidebar_conversations()
    |> Enum.map(&conversation_row(&1, nil, "对话", "free"))
  end

  def free_conversation_slice(conversations_by_workspace, limit, current_conversation_id)
      when is_map(conversations_by_workspace) do
    conversations =
      conversations_by_workspace
      |> free_conversations()
      |> Enum.reject(& &1.pinned)

    effective_limit = effective_row_limit(conversations, limit, current_conversation_id)

    %{
      rows: Enum.take(conversations, effective_limit),
      has_more?: length(conversations) > effective_limit,
      hidden_count: max(length(conversations) - effective_limit, 0),
      visible_limit: effective_limit
    }
  end

  def workspace_conversations(conversations_by_workspace, ws_id, workspaces)
      when is_map(conversations_by_workspace) and is_list(workspaces) do
    ws_map = Map.new(workspaces, fn ws -> {ws["id"], ws["name"] || ws["id"]} end)
    workspace_name = Map.get(ws_map, ws_id, ws_id)

    {pinned, unpinned} =
      conversations_by_workspace
      |> Map.get(ws_id, [])
      |> Enum.reject(&archived_conversation?/1)
      |> Enum.split_with(&pinned_conversation?/1)

    tree_rows =
      thread_tree_rows(unpinned, fn conv ->
        conversation_row(conv, ws_id, workspace_name, "workspace")
      end)

    pinned_rows =
      pinned
      |> sort_sidebar_conversations()
      |> Enum.map(&conversation_row(&1, ws_id, workspace_name, "workspace"))

    tree_rows ++ pinned_rows
  end

  def visible_workspace_conversations(
        conversations_by_workspace,
        ws_id,
        workspaces,
        collapsed_thread_ids
      ) do
    collapsed_thread_ids = normalize_collapsed_threads(collapsed_thread_ids)

    conversations_by_workspace
    |> workspace_conversations(ws_id, workspaces)
    |> Enum.reject(fn row ->
      Enum.any?(row.tree_ancestor_ids, &MapSet.member?(collapsed_thread_ids, &1))
    end)
  end

  def workspace_conversation_slice(
        conversations_by_workspace,
        ws_id,
        workspaces,
        collapsed_thread_ids,
        limit,
        current_conversation_id
      )
      when is_map(conversations_by_workspace) and is_list(workspaces) do
    ws_map = Map.new(workspaces, fn ws -> {ws["id"], ws["name"] || ws["id"]} end)
    workspace_name = Map.get(ws_map, ws_id, ws_id)

    families =
      conversations_by_workspace
      |> Map.get(ws_id, [])
      |> Enum.reject(&archived_conversation?/1)
      |> Enum.reject(&pinned_conversation?/1)
      |> thread_tree_families(fn conv ->
        conversation_row(conv, ws_id, workspace_name, "workspace")
      end)

    effective_limit = effective_family_limit(families, limit, current_conversation_id)
    collapsed_thread_ids = normalize_collapsed_threads(collapsed_thread_ids)

    rows =
      families
      |> Enum.take(effective_limit)
      |> List.flatten()
      |> Enum.reject(fn row ->
        Enum.any?(row.tree_ancestor_ids, &MapSet.member?(collapsed_thread_ids, &1))
      end)

    %{
      rows: rows,
      has_more?: length(families) > effective_limit,
      hidden_count: max(length(families) - effective_limit, 0),
      visible_limit: effective_limit
    }
  end

  defp normalize_collapsed_threads(collapsed_thread_ids) do
    if is_struct(collapsed_thread_ids, MapSet),
      do: collapsed_thread_ids,
      else: MapSet.new()
  end

  defp effective_row_limit(rows, limit, current_conversation_id) do
    limit = normalize_sidebar_limit(limit)

    case Enum.find_index(rows, &(&1.id == current_conversation_id)) do
      nil -> limit
      index -> max(limit, index + 1)
    end
  end

  defp effective_family_limit(families, limit, current_conversation_id) do
    limit = normalize_sidebar_limit(limit)

    case Enum.find_index(families, fn rows ->
           Enum.any?(rows, &(&1.id == current_conversation_id))
         end) do
      nil -> limit
      index -> max(limit, index + 1)
    end
  end

  defp normalize_sidebar_limit(limit) when is_integer(limit) and limit > 0, do: limit
  defp normalize_sidebar_limit(_limit), do: @sidebar_page_size

  defp conversation_row(conv, workspace_id, workspace_name, scope) do
    row = %{
      id: ConversationState.conversation_id(conv),
      title: ConversationState.conv_value(conv, "title", "New chat"),
      workspace_id: workspace_id,
      workspace_name: workspace_name,
      scope: scope,
      parent_id: Handbean.ConversationStore.parent_conversation_id(conv),
      tree_depth: 0,
      tree_branch: nil,
      tree_ancestor_ids: [],
      child_count: 0,
      archived: archived_conversation?(conv),
      pinned: pinned_conversation?(conv),
      pinned_at: ConversationState.conv_value(conv, "pinned_at", nil),
      updated_at: ConversationState.conv_value(conv, "updated_at", nil),
      created_at: ConversationState.conv_value(conv, "created_at", nil),
      checkout_path: ConversationState.conv_value(conv, "checkout_path", nil)
    }

    Map.put(row, :age, HandbeanWeb.WorkspaceLive.ViewComponents.short_relative_time(row))
  end

  @doc "Folder, live branch, and absolute checkout path shown on conversation hover."
  def hover_context(conversation) when is_map(conversation) do
    path = ConversationState.conv_value(conversation, "checkout_path", nil)
    available? = is_binary(path) and path != "" and File.dir?(path)

    %{
      folder: if(is_binary(path) and path != "", do: Path.basename(path)),
      branch: if(available?, do: hover_branch(path)),
      path: path,
      available: available?
    }
  end

  def hover_context(_conversation),
    do: %{folder: nil, branch: nil, path: nil, available: false}

  defp hover_branch(path) when is_binary(path) and path != "" do
    key = {path, branch_cache_bucket()}

    case :persistent_term.get({__MODULE__, :branch, key}, :miss) do
      :miss ->
        branch = read_branch(path)
        :persistent_term.put({__MODULE__, :branch, key}, branch)
        branch

      branch ->
        branch
    end
  end

  defp hover_branch(_path), do: nil

  defp branch_cache_bucket do
    div(System.system_time(:second), 30)
  end

  @doc "Git remote repository name for a workspace path, e.g. `Handbean`."
  def repo_name(path) when is_binary(path) and path != "" do
    key = {path, branch_cache_bucket()}

    case :persistent_term.get({__MODULE__, :repo, key}, :miss) do
      :miss ->
        name = read_repo_name(path)
        :persistent_term.put({__MODULE__, :repo, key}, name)
        name

      name ->
        name
    end
  end

  def repo_name(_path), do: nil

  defp read_repo_name(path) do
    case Handbean.Git.CLI.remotes({:cli, path}) do
      {:ok, remotes} ->
        remotes
        |> Enum.find(&(&1.name == "origin"))
        |> Kernel.||(List.first(remotes))
        |> then(&repo_name_from_remote/1)

      _ ->
        nil
    end
  end

  defp repo_name_from_remote(nil), do: nil
  defp repo_name_from_remote(%{url: url}), do: repo_name_from_url(url)

  defp repo_name_from_url(url) when is_binary(url) do
    url
    |> String.trim()
    |> String.trim_trailing("/")
    |> String.replace(~r/\.git$/, "")
    |> String.split(["/", ":"])
    |> List.last()
    |> case do
      name when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end

  defp repo_name_from_url(_url), do: nil

  defp read_branch(path) do
    case Handbean.Git.CLI.branches({:cli, path}) do
      {:ok, branches} ->
        case Enum.find(branches, & &1.current?) do
          %{name: name} when is_binary(name) and name != "" -> name
          _ -> nil
        end

      _ ->
        nil
    end
  end

  def pinned_conversations(workspaces, conversations_by_workspace)
      when is_list(workspaces) and is_map(conversations_by_workspace) do
    ws_map = Map.new(workspaces, fn ws -> {ws["id"], ws["name"] || ws["id"]} end)

    conversations_by_workspace
    |> Enum.flat_map(fn {ws_id, convs} ->
      {workspace_id, label, scope} = archived_bucket(ws_id, ws_map)

      convs
      |> Enum.filter(&(pinned_conversation?(&1) and not archived_conversation?(&1)))
      |> Enum.map(&conversation_row(&1, workspace_id, label, scope))
    end)
    |> Enum.sort_by(&(&1.pinned_at || ""), :desc)
  end

  defp stream_workspace_id(@free_key), do: nil
  defp stream_workspace_id(ws_id), do: ws_id

  defp stream_workspace_name(@free_key, _ws_names), do: "对话"
  defp stream_workspace_name(ws_id, ws_names), do: Map.get(ws_names, ws_id, ws_id)

  def archived_stream_count(stream_entries) when is_list(stream_entries) do
    Enum.count(stream_entries, fn {_, conv} -> conv.archived end)
  end

  def archived_conversation?(conversation) do
    Handbean.ConversationStore.archived_conversation?(conversation)
  end

  def pinned_conversation?(conversation) do
    Handbean.ConversationStore.pinned_conversation?(conversation)
  end

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

  defp first_active_conversation(conversations) do
    Enum.find(conversations, &(not archived_conversation?(&1)))
  end

  defp transcript_empty?(conversation_id) do
    Handbean.ConversationStore.transcript_empty?(conversation_id)
  end

  defp maybe_sort_conversations(conversations, _include_archived?),
    do: sort_sidebar_conversations(conversations)

  defp insert_sidebar_conversation(conversations, conversation) do
    id = ConversationState.conversation_id(conversation)

    conversations
    |> Enum.reject(&(ConversationState.conversation_id(&1) == id))
    |> then(&[conversation | &1])
    |> sort_sidebar_conversations()
  end

  defp thread_tree_rows(conversations, row_fun) do
    conversations
    |> thread_tree_families(row_fun)
    |> List.flatten()
  end

  defp thread_tree_families(conversations, row_fun) do
    by_id = Map.new(conversations, &{ConversationState.conversation_id(&1), &1})

    parent_by_id =
      Map.new(conversations, fn conversation ->
        id = ConversationState.conversation_id(conversation)
        {id, effective_parent_id(conversation, id, by_id)}
      end)

    children_by_parent =
      Enum.reduce(conversations, %{}, fn conversation, children ->
        case Map.get(parent_by_id, ConversationState.conversation_id(conversation)) do
          parent_id when is_binary(parent_id) ->
            Map.update(children, parent_id, [conversation], &[conversation | &1])

          _ ->
            children
        end
      end)

    conversations
    |> Enum.filter(&is_nil(Map.get(parent_by_id, ConversationState.conversation_id(&1))))
    |> Enum.sort_by(&family_activity_key(&1, children_by_parent), :desc)
    |> Enum.flat_map(fn conversation ->
      flatten_thread_tree(conversation, 0, nil, [], children_by_parent, row_fun)
    end)
  end

  defp effective_parent_id(conversation, id, by_id) do
    parent_id = Handbean.ConversationStore.parent_conversation_id(conversation)

    if is_binary(parent_id) and parent_id != id and Map.has_key?(by_id, parent_id) and
         not cyclic_parent_chain?(id, parent_id, by_id, MapSet.new()) do
      parent_id
    end
  end

  defp cyclic_parent_chain?(origin_id, current_id, by_id, visited) do
    cond do
      current_id == origin_id ->
        true

      MapSet.member?(visited, current_id) ->
        true

      true ->
        case Map.get(by_id, current_id) do
          nil ->
            false

          conversation ->
            case Handbean.ConversationStore.parent_conversation_id(conversation) do
              parent_id when is_binary(parent_id) and is_map_key(by_id, parent_id) ->
                cyclic_parent_chain?(
                  origin_id,
                  parent_id,
                  by_id,
                  MapSet.put(visited, current_id)
                )

              _ ->
                false
            end
        end
    end
  end

  defp flatten_thread_tree(
         conversation,
         depth,
         branch,
         ancestor_ids,
         children_by_parent,
         row_fun
       ) do
    id = ConversationState.conversation_id(conversation)

    children =
      children_by_parent
      |> Map.get(id, [])
      |> Enum.sort_by(&family_activity_key(&1, children_by_parent), :desc)

    row =
      conversation
      |> row_fun.()
      |> Map.merge(%{
        tree_depth: depth,
        tree_branch: branch,
        tree_ancestor_ids: ancestor_ids,
        child_count: length(children)
      })

    descendants =
      children
      |> Enum.with_index()
      |> Enum.flat_map(fn {child, index} ->
        child_branch = if index == length(children) - 1, do: :last, else: :middle

        flatten_thread_tree(
          child,
          depth + 1,
          child_branch,
          [id | ancestor_ids],
          children_by_parent,
          row_fun
        )
      end)

    [row | descendants]
  end

  defp family_activity_key(conversation, children_by_parent) do
    own_key = conversation_activity_key(conversation)

    children_by_parent
    |> Map.get(ConversationState.conversation_id(conversation), [])
    |> Enum.reduce(own_key, fn child, latest ->
      max(family_activity_key(child, children_by_parent), latest)
    end)
  end

  defp conversation_activity_key(conversation) do
    {
      ConversationState.conv_value(conversation, "updated_at", "") || "",
      ConversationState.conv_value(conversation, "created_at", "") || "",
      ConversationState.conversation_id(conversation)
    }
  end

  # Active chats stay above archived ones. Within each group, the most recently
  # updated conversation is first so a new chat appears at the top of the sidebar.
  # Opening a chat must not change this key; only a new user-authored message
  # should advance it.
  defp sort_sidebar_conversations(conversations) do
    Enum.sort_by(conversations, &sidebar_sort_key/1, :desc)
  end

  defp sidebar_sort_key(conversation) do
    {
      not archived_conversation?(conversation),
      ConversationState.conv_value(conversation, "updated_at", "") || "",
      ConversationState.conv_value(conversation, "created_at", "") || ""
    }
  end

  defp filter_archived(conversations, true), do: conversations

  defp filter_archived(conversations, false),
    do: Enum.reject(conversations, &archived_conversation?/1)

  defp conversation_title(1), do: "New chat"
  defp conversation_title(num), do: "New chat ##{num}"

  defp dev_log(message) do
    if dev_env?(), do: Logger.debug(message)
  end

  defp dev_env? do
    function_exported?(Mix, :env, 0) and Mix.env() == :dev
  end
end
