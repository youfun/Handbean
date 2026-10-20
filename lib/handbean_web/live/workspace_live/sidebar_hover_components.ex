defmodule HandbeanWeb.WorkspaceLive.SidebarHoverComponents do
  @moduledoc false

  use HandbeanWeb, :html

  import HandbeanWeb.WorkspaceLive.ViewComponents

  alias HandbeanWeb.WorkspaceLive.{ConversationState, ConversationSwitching}

  def workspace_hover_card(assigns) do
    ~H"""
    <div id="workspace-hover-card" class="workspace-hover" role="tooltip" hidden>
      <div class="workspace-hover-head">
        <div class="min-w-0">
          <div class="workspace-hover-name" data-workspace-hover-name></div>
          <div class="workspace-hover-path" data-workspace-hover-path></div>
          <div class="workspace-hover-repo" data-workspace-hover-repo hidden>
            <span>{gettext("仓库")}</span>
            <svg
              width="13"
              height="13"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="1.8"
              stroke-linecap="round"
              stroke-linejoin="round"
              aria-hidden="true"
            >
              <line x1="6" y1="3" x2="6" y2="15" />
              <circle cx="18" cy="6" r="3" /><circle cx="6" cy="18" r="3" />
              <path d="M18 9a9 9 0 0 1-9 9" />
            </svg>
            <span class="truncate" data-workspace-hover-repo-name></span>
          </div>
        </div>
        <button
          type="button"
          class="workspace-hover-rename"
          data-workspace-hover-rename
          title={gettext("重命名")}
          aria-label={gettext("重命名")}
        >
          <svg width="13" height="13" viewBox="0 0 12 12" fill="none" aria-hidden="true">
            <path
              d="M7.2 2.1 9.9 4.8 4.4 10.3 1.5 10.5l.2-2.9L7.2 2.1Z"
              stroke="currentColor"
              stroke-width="1.1"
              stroke-linejoin="round"
            />
            <path
              d="M6.4 2.9 9.1 5.6"
              stroke="currentColor"
              stroke-width="1.1"
              stroke-linecap="round"
            />
          </svg>
        </button>
      </div>
      <button
        type="button"
        id="workspace-hover-remove"
        class="workspace-hover-remove"
        data-workspace-hover-remove
        hidden
      >
        {gettext("移除工作区")}
      </button>
    </div>
    """
  end

  def visible_hover_ids(assigns) do
    free_ids =
      if workspace_group_collapsed?(assigns.collapsed_workspace_ids, "free") do
        []
      else
        assigns.conversations_by_workspace
        |> free_conversation_slice(
          sidebar_limit(assigns.sidebar_visible_limits, "free"),
          assigns.current_conversation_id
        )
        |> Map.fetch!(:rows)
        |> Enum.map(& &1.id)
      end

    workspace_ids =
      Enum.flat_map(assigns.workspaces, fn workspace ->
        if workspace_group_collapsed?(assigns.collapsed_workspace_ids, workspace["id"]) do
          []
        else
          assigns.conversations_by_workspace
          |> workspace_conversation_slice(
            workspace["id"],
            assigns.workspaces,
            assigns.collapsed_thread_ids,
            sidebar_limit(assigns.sidebar_visible_limits, workspace["id"]),
            assigns.current_conversation_id
          )
          |> Map.fetch!(:rows)
          |> Enum.map(& &1.id)
        end
      end)

    pinned_ids =
      if workspace_group_collapsed?(assigns.collapsed_workspace_ids, "pinned") do
        []
      else
        assigns.workspaces
        |> pinned_conversations(assigns.conversations_by_workspace)
        |> Enum.map(& &1.id)
      end

    archived_ids =
      if assigns.show_archive do
        assigns.workspaces
        |> archived_conversations(assigns.conversations_by_workspace)
        |> Enum.map(& &1.id)
      else
        []
      end

    MapSet.new(free_ids ++ workspace_ids ++ pinned_ids ++ archived_ids)
  end

  attr :conversations_by_workspace, :map, required: true
  attr :visible_ids, :any, required: true

  def conversation_hover_card(assigns) do
    assigns =
      assign(
        assigns,
        :contexts,
        hover_contexts(assigns.conversations_by_workspace, assigns.visible_ids)
      )

    ~H"""
    <div id="conversation-hover-card" class="conversation-hover" role="tooltip" hidden>
      <div class="conversation-hover-title-row">
        <span class="conversation-hover-grip" aria-hidden="true">
          <svg width="10" height="14" viewBox="0 0 10 14" fill="currentColor">
            <circle cx="2.5" cy="2.5" r="1" /><circle cx="7.5" cy="2.5" r="1" />
            <circle cx="2.5" cy="7" r="1" /><circle cx="7.5" cy="7" r="1" />
            <circle cx="2.5" cy="11.5" r="1" /><circle cx="7.5" cy="11.5" r="1" />
          </svg>
        </span>
        <span class="conversation-hover-title" data-hover-title></span>
        <button
          type="button"
          class="conversation-hover-copy"
          phx-hook="CopyText"
          id="conversation-hover-copy"
          data-copy=""
          title={gettext("复制标题")}
          aria-label={gettext("复制标题")}
        >
          <svg width="12" height="12" viewBox="0 0 12 12" fill="none" aria-hidden="true">
            <rect
              x="4.25"
              y="3.25"
              width="5.5"
              height="6.5"
              rx="0.75"
              stroke="currentColor"
              stroke-width="1.1"
            />
            <path
              d="M3.25 8.75H2.75A.75.75 0 0 1 2 8V2.75A.75.75 0 0 1 2.75 2H8a.75.75 0 0 1 .75.75V3.25"
              stroke="currentColor"
              stroke-width="1.1"
              stroke-linecap="round"
            />
          </svg>
        </button>
        <span class="conversation-hover-age" data-hover-age hidden></span>
      </div>
      <div
        :for={{key, meta} <- @contexts}
        id={"conversation-hover-context-#{key}"}
        data-hover-context={key}
        hidden
      >
        <div :if={meta.folder} class="conversation-hover-meta">
          <svg
            width="13"
            height="13"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="1.8"
            stroke-linecap="round"
            stroke-linejoin="round"
            aria-hidden="true"
          >
            <path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" />
          </svg>
          <span class="truncate">{meta.folder}</span>
        </div>
        <div :if={meta.branch} class="conversation-hover-meta">
          <svg
            class="conversation-hover-branch-icon"
            width="13"
            height="13"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="1.8"
            stroke-linecap="round"
            stroke-linejoin="round"
            aria-hidden="true"
          >
            <line x1="6" y1="3" x2="6" y2="15" />
            <circle cx="18" cy="6" r="3" /><circle cx="6" cy="18" r="3" />
            <path d="M18 9a9 9 0 0 1-9 9" />
          </svg>
          <span class="truncate">{meta.branch}</span>
        </div>
        <div :if={meta.path} class="conversation-hover-meta conversation-hover-path-row">
          <span aria-hidden="true">⌁</span>
          <span class="conversation-hover-path" title={meta.path}>{meta.path}</span>
        </div>
        <div
          :if={meta.path && not meta.available}
          class="conversation-hover-unavailable"
          role="status"
        >
          {gettext("Checkout unavailable")}
        </div>
      </div>
    </div>
    """
  end

  defp hover_contexts(conversations_by_workspace, visible_ids) do
    conversations_by_workspace
    |> Map.values()
    |> List.flatten()
    |> Enum.filter(fn conversation ->
      MapSet.member?(visible_ids, ConversationState.conversation_id(conversation))
    end)
    |> Enum.map(fn conversation ->
      {ConversationState.conversation_id(conversation),
       ConversationSwitching.hover_context(conversation)}
    end)
    |> Enum.filter(fn {id, meta} ->
      is_binary(id) and (meta.folder || meta.branch || meta.path)
    end)
    |> Enum.uniq_by(&elem(&1, 0))
  end
end
