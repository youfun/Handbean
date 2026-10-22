defmodule HandbeanWeb.WorkspaceLive.ConversationSwitching.ListProjection do
  @moduledoc false

  use Gettext, backend: Handbean.Gettext

  alias HandbeanWeb.WorkspaceLive.ConversationState

  require Logger

  @free_key :free
  @sidebar_page_size 10

  def sidebar_limit(limits, bucket) when is_map(limits) do
    case Map.get(limits, to_string(bucket), @sidebar_page_size) do
      limit when is_integer(limit) and limit > 0 -> limit
      _ -> @sidebar_page_size
    end
  end

  def sidebar_limit(_limits, _bucket), do: @sidebar_page_size

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

  def initial_conversation_id(conversations_by_ws, ws_id) do
    conversations_by_ws
    |> Map.get(ws_id, [])
    |> first_active_conversation()
    |> case do
      nil -> nil
      conversation -> ConversationState.conversation_id(conversation)
    end
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

      {ws_id, sort_sidebar_conversations(convs)}
    end)
    |> Map.new()
  end

  def stream_items(conversations_by_ws, workspaces) do
    ws_names = Map.new(workspaces, fn ws -> {ws["id"], ws["name"]} end)

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
      |> Enum.map(fn conversation ->
        archived_row(conversation, workspace_id, label, scope)
      end)
    end)
    |> Enum.sort_by(& &1.updated_at, :desc)
  end

  def free_conversations(conversations_by_workspace) when is_map(conversations_by_workspace) do
    conversations_by_workspace
    |> Map.get(@free_key, [])
    |> Enum.reject(&archived_conversation?/1)
    |> sort_sidebar_conversations()
    |> Enum.map(&conversation_row(&1, nil, gettext("自由对话"), "free"))
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

  def archived_stream_count(stream_entries) when is_list(stream_entries) do
    Enum.count(stream_entries, fn {_, conv} -> conv.archived end)
  end

  def archived_conversation?(conversation) do
    Handbean.ConversationStore.archived_conversation?(conversation)
  end

  def pinned_conversation?(conversation) do
    Handbean.ConversationStore.pinned_conversation?(conversation)
  end

  def first_active_conversation(conversations) do
    Enum.find(conversations, &(not archived_conversation?(&1)))
  end

  def insert_sidebar_conversation(conversations, conversation) do
    id = ConversationState.conversation_id(conversation)

    conversations
    |> Enum.reject(&(ConversationState.conversation_id(&1) == id))
    |> then(&[conversation | &1])
    |> sort_sidebar_conversations()
  end

  # Active chats stay above archived ones. Within each group, the most recently
  # updated conversation is first so a new chat appears at the top of the sidebar.
  # Opening a chat must not change this key; only a new user-authored message
  # should advance it.
  def sort_sidebar_conversations(conversations) do
    Enum.sort_by(conversations, &sidebar_sort_key/1, :desc)
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

  defp archived_bucket(@free_key, _ws_map), do: {nil, gettext("自由对话"), "free"}

  defp archived_bucket(ws_id, ws_map),
    do: {ws_id, Map.get(ws_map, ws_id, ws_id), "workspace"}

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

  defp stream_workspace_id(@free_key), do: nil
  defp stream_workspace_id(ws_id), do: ws_id

  defp stream_workspace_name(@free_key, _ws_names), do: gettext("自由对话")
  defp stream_workspace_name(ws_id, ws_names), do: Map.get(ws_names, ws_id, ws_id)

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
    |> Enum.map(fn conversation ->
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

  defp transcript_empty?(conversation_id) do
    Handbean.ConversationStore.transcript_empty?(conversation_id)
  end

  defp dev_log(message) do
    if dev_env?(), do: Logger.debug(message)
  end

  defp dev_env? do
    function_exported?(Mix, :env, 0) and Mix.env() == :dev
  end
end
