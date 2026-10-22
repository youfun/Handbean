defmodule HandbeanWeb.WorkspaceLive.SidebarListComponents do
  @moduledoc false

  use HandbeanWeb, :html

  import HandbeanWeb.WorkspaceLive.SidebarCheckoutComponents, only: [checkout_picker: 1]

  import HandbeanWeb.WorkspaceLive.SidebarConversationComponents,
    only: [conversation_menu: 1, run_indicator: 1]

  import HandbeanWeb.WorkspaceLive.SidebarHoverComponents,
    only: [conversation_hover_card: 1, visible_hover_ids: 1, workspace_hover_card: 1]

  import HandbeanWeb.WorkspaceLive.ViewComponents

  attr :chat_scope, :any, required: true
  attr :collapsed_workspace_ids, :any, required: true
  attr :collapsed_thread_ids, :any, default: MapSet.new()
  attr :conversation_menu_id, :any, required: true
  attr :checkout_picker, :any, default: nil
  attr :conversations_by_workspace, :any, required: true
  attr :current_conversation_id, :any, required: true
  attr :current_workspace_id, :any, required: true
  attr :show_archive, :any, required: true
  attr :workspaces, :any, required: true
  attr :conversation_list_loading, :boolean, default: false
  attr :conversation_list_loaded, :boolean, default: false
  attr :conversation_list_error, :any, default: nil
  attr :runtime_tasks, :map, default: %{tasks: []}
  attr :sidebar_visible_limits, :map, default: %{}
  attr :show_schedules, :boolean, default: false
  attr :schedule_count, :integer, default: 0

  def projects_sidebar(assigns) do
    assigns =
      assigns
      |> assign(
        :run_states,
        Map.new(assigns.runtime_tasks.tasks, &{&1.conversation_id, &1.status})
      )
      |> assign(:visible_hover_ids, visible_hover_ids(assigns))

    ~H"""
    <div
      id="activity-bar"
      phx-hook="ConversationSidebar"
      class="flex-shrink-0 border-r bg-surface flex flex-col workspace-panel projects-panel"
    >
      <div class="projects-panel-header">
        <h2 class="projects-panel-title">
          <img src={~p"/images/logo.svg"} class="brand-mark" width="16" height="16" alt="" />
          <span>{gettext("专案")}</span>
        </h2>
        <div class="projects-panel-new-conversation">
          <button
            id="open-conversation-search"
            type="button"
            phx-click="open_conversation_search"
            class="conversation-search-trigger"
            title={gettext("Search conversations")}
            aria-label={gettext("Search conversations")}
            aria-haspopup="dialog"
          >
            <svg
              width="14"
              height="14"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="1.8"
              aria-hidden="true"
            >
              <circle cx="10.5" cy="10.5" r="6.5" />
              <path d="m15.5 15.5 4.5 4.5" />
            </svg>
          </button>
          <button
            id="new-conversation-picker-toggle"
            type="button"
            phx-click="toggle_new_conversation_picker"
            class="text-xs text-tertiary hover:text-primary transition-colors leading-none"
            title={gettext("新建对话")}
            aria-label={gettext("新建对话")}
            aria-haspopup="dialog"
            aria-expanded={to_string(match?(%{source: :header}, @checkout_picker))}
          >
            +
          </button>
        </div>
      </div>
      <div
        class="flex-1 overflow-y-auto"
        id="projects-sidebar-scroll"
        aria-busy={to_string(@conversation_list_loading)}
      >
        <div
          :if={@conversation_list_loading and not @conversation_list_loaded}
          id="conversation-list-loading"
          role="status"
          class="px-3 py-2 text-xs text-tertiary flex items-center gap-2"
        >
          <span class="loading loading-spinner loading-xs" aria-hidden="true"></span>
          {gettext("正在加载对话…")}
        </div>
        <div
          :if={@conversation_list_loading and @conversation_list_loaded}
          id="conversation-list-refreshing"
          role="status"
          class="px-3 py-1 text-xs text-tertiary"
        >
          {gettext("正在刷新对话…")}
        </div>
        <div
          :if={@conversation_list_error}
          id="conversation-list-error"
          role="alert"
          class="px-3 py-2 text-xs text-tertiary"
        >
          <p>{gettext("对话加载失败")}</p>
          <button
            type="button"
            phx-click="retry_conversation_list"
            class="mt-1 underline hover:text-primary"
          >{gettext("重试")}</button>
        </div>
        <div
          :if={pinned_conversations(@workspaces, @conversations_by_workspace) != []}
          id="pinned-conversations-group"
          class={[
            "pinned-group",
            workspace_group_collapsed?(@collapsed_workspace_ids, "pinned") && "is-collapsed"
          ]}
        >
          <div class="workspace-title-row">
            <button
              type="button"
              phx-click="toggle_workspace_group"
              phx-value-id="pinned"
              aria-expanded={
                to_string(not workspace_group_collapsed?(@collapsed_workspace_ids, "pinned"))
              }
              aria-controls="pinned-conversations"
              title={
                if(workspace_group_collapsed?(@collapsed_workspace_ids, "pinned"),
                  do: gettext("展开"),
                  else: gettext("收起")
                )
              }
              class="workspace-header min-w-0 text-left px-2 py-1.5 text-xs flex items-center gap-1.5"
            >
              <span class="truncate flex-1">{gettext("已置顶")}</span>
            </button>
            <span class="workspace-title-rule" aria-hidden="true"></span>
            <button
              type="button"
              id="pinned-workspace-toggle"
              phx-click="toggle_workspace_group"
              phx-value-id="pinned"
              class="workspace-count-toggle"
              aria-expanded={
                to_string(not workspace_group_collapsed?(@collapsed_workspace_ids, "pinned"))
              }
              aria-controls="pinned-conversations"
              title={
                if(workspace_group_collapsed?(@collapsed_workspace_ids, "pinned"),
                  do: gettext("展开"),
                  else: gettext("收起")
                )
              }
              aria-label={
                if(workspace_group_collapsed?(@collapsed_workspace_ids, "pinned"),
                  do: gettext("展开"),
                  else: gettext("收起")
                )
              }
            >
              <span class="workspace-conv-count" title={gettext("会话数量")}>
                {length(pinned_conversations(@workspaces, @conversations_by_workspace))}
              </span>
              <svg
                class={[
                  "workspace-chevron-icon",
                  workspace_group_collapsed?(@collapsed_workspace_ids, "pinned") && "is-collapsed"
                ]}
                width="10"
                height="10"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                stroke-width="2.5"
                aria-hidden="true"
              >
                <polyline points="6 9 12 15 18 9" />
              </svg>
            </button>
          </div>
          <div
            :if={not workspace_group_collapsed?(@collapsed_workspace_ids, "pinned")}
            id="pinned-conversations"
            class="conversations-list"
          >
            <div
              :for={conv <- pinned_conversations(@workspaces, @conversations_by_workspace)}
              id={"pinned-conversation-#{conv.id}"}
              class="conversation-row is-pinned"
              data-conversation-menu-row
              data-conversation-id={conv.id}
              data-conversation-title={conv.title}
              data-conversation-age={conv.age}
              data-workspace-id={conv.workspace_id}
            >
              <button
                phx-click={
                  if(conv.scope == "free",
                    do: "select_free_conversation",
                    else: "select_conversation"
                  )
                }
                phx-value-id={conv.id}
                phx-value-ws_id={conv.workspace_id}
                class={[
                  "conversation-item flex-1 min-w-0 text-left py-1.5 text-xs transition-colors flex items-center gap-1.5",
                  conversation_row_active?(
                    conv,
                    @current_conversation_id,
                    @current_workspace_id,
                    @chat_scope
                  ) &&
                    "conversation-item-active"
                ]}
              >
                <.run_indicator
                  id={conv.id}
                  state={Map.get(@run_states, conv.id)}
                />
                <span class="truncate flex-1">{conv.title}</span>
              </button>
              <.conversation_menu conv={conv} conversation_menu_id={@conversation_menu_id} />
            </div>
          </div>
        </div>

        <div
          id="free-chats"
          class={[
            "workspace-group",
            workspace_group_collapsed?(@collapsed_workspace_ids, "free") && "is-collapsed"
          ]}
        >
          <div class={[
            "workspace-title-row",
            @chat_scope == :free && "is-active"
          ]}>
            <button
              type="button"
              phx-click="toggle_workspace_group"
              phx-value-id="free"
              aria-expanded={
                to_string(not workspace_group_collapsed?(@collapsed_workspace_ids, "free"))
              }
              aria-controls="free-conversations"
              title={
                if(workspace_group_collapsed?(@collapsed_workspace_ids, "free"),
                  do: gettext("展开"),
                  else: gettext("收起")
                )
              }
              class="workspace-header min-w-0 text-left px-2 py-1.5 text-xs flex items-center gap-1.5"
            >
              <span class="truncate flex-1">{gettext("自由对话")}</span>
            </button>
            <span class="workspace-title-rule" aria-hidden="true"></span>
            <button
              id="new-free-conversation"
              phx-click="new_free_conversation"
              class="workspace-add-btn flex-shrink-0 w-5 h-5 flex items-center justify-center rounded text-tertiary hover:text-primary hover:bg-surface-hover transition-colors"
              title={gettext("新建自由对话")}
            >
              <svg width="12" height="12" viewBox="0 0 12 12" fill="none">
                <path
                  d="M6 1v10M1 6h10"
                  stroke="currentColor"
                  stroke-width="1.5"
                  stroke-linecap="round"
                />
              </svg>
            </button>
            <button
              type="button"
              id="free-workspace-toggle"
              phx-click="toggle_workspace_group"
              phx-value-id="free"
              class="workspace-count-toggle"
              aria-expanded={
                to_string(not workspace_group_collapsed?(@collapsed_workspace_ids, "free"))
              }
              aria-controls="free-conversations"
              title={
                if(workspace_group_collapsed?(@collapsed_workspace_ids, "free"),
                  do: gettext("展开"),
                  else: gettext("收起")
                )
              }
              aria-label={
                if(workspace_group_collapsed?(@collapsed_workspace_ids, "free"),
                  do: gettext("展开"),
                  else: gettext("收起")
                )
              }
            >
              <span id="free-workspace-count" class="workspace-conv-count" title={gettext("会话数量")}>
                {free_conversation_count(@conversations_by_workspace)}
              </span>
              <svg
                class={[
                  "workspace-chevron-icon",
                  workspace_group_collapsed?(@collapsed_workspace_ids, "free") && "is-collapsed"
                ]}
                width="10"
                height="10"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                stroke-width="2.5"
                aria-hidden="true"
              >
                <polyline points="6 9 12 15 18 9" />
              </svg>
            </button>
          </div>
          <% free_slice =
            free_conversation_slice(
              @conversations_by_workspace,
              sidebar_limit(@sidebar_visible_limits, "free"),
              @current_conversation_id
            ) %>
          <div
            :if={not workspace_group_collapsed?(@collapsed_workspace_ids, "free")}
            id="free-conversations"
            class="conversations-list"
          >
            <div
              :for={conv <- free_slice.rows}
              id={"free-conversation-#{conv.id}"}
              class="conversation-row"
              data-conversation-menu-row
              data-conversation-id={conv.id}
              data-conversation-title={conv.title}
              data-conversation-age={conv.age}
              data-workspace-id={conv.workspace_id}
            >
              <button
                phx-click="select_free_conversation"
                phx-value-id={conv.id}
                class={[
                  "conversation-item flex-1 min-w-0 text-left pl-6 pr-1 py-1.5 text-xs transition-colors flex items-center gap-1.5",
                  if(@current_conversation_id == conv.id and @chat_scope == :free,
                    do: "conversation-item-active",
                    else: "hover:bg-surface-hover text-secondary"
                  )
                ]}
              >
                <.run_indicator
                  id={conv.id}
                  state={Map.get(@run_states, conv.id)}
                />
                <span class="truncate flex-1">{conv.title}</span>
              </button>
              <.conversation_menu conv={conv} conversation_menu_id={@conversation_menu_id} />
            </div>
            <button
              :if={free_slice.has_more?}
              id="free-conversations-more"
              type="button"
              phx-click="show_more_conversations"
              phx-value-bucket="free"
              class="conversation-more-button"
              aria-label={gettext("显示更多对话")}
            >
              {gettext("更多")}
            </button>
          </div>
        </div>

        <!-- Workspace headers (outside stream, fixed) -->
        <div
          :for={ws <- @workspaces}
          id={"workspace-group-#{ws["id"]}"}
          class={[
            "workspace-group",
            workspace_group_collapsed?(@collapsed_workspace_ids, ws["id"]) && "is-collapsed"
          ]}
          data-workspace-id={ws["id"]}
          data-workspace-name={ws["name"]}
          data-workspace-path={ws["path"]}
          data-workspace-repo={repo_name(ws["path"])}
          data-workspace-default={if(ws["default"], do: "true", else: "false")}
        >
          <div class={[
            "workspace-title-row",
            @current_workspace_id == ws["id"] && @chat_scope != :free && "is-active"
          ]}>
            <button
              type="button"
              phx-click="toggle_workspace_group"
              phx-value-id={ws["id"]}
              aria-expanded={
                to_string(not workspace_group_collapsed?(@collapsed_workspace_ids, ws["id"]))
              }
              aria-controls={"workspace-conversations-#{ws["id"]}"}
              title={
                if(workspace_group_collapsed?(@collapsed_workspace_ids, ws["id"]),
                  do: gettext("展开"),
                  else: gettext("收起")
                )
              }
              class="workspace-header min-w-0 text-left px-2 py-1.5 text-xs flex items-center gap-1.5 transition-colors hover:bg-surface-hover"
            >
              <span class="workspace-icon" aria-hidden="true">
                <svg
                  width="20"
                  height="22"
                  viewBox="0 0 24 24"
                  fill="none"
                  stroke="currentColor"
                  stroke-width="2"
                  stroke-linecap="round"
                  stroke-linejoin="round"
                >
                  <path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" />
                </svg>
              </span>
              <span class="truncate flex-1">{ws["name"]}</span>
            </button>
            <span class="workspace-title-rule" aria-hidden="true"></span>
            <div class="workspace-row-actions">
              <.checkout_picker
                workspace_id={ws["id"]}
                picker={@checkout_picker}
                source={:sidebar}
              />
            </div>
            <button
              type="button"
              id={"workspace-toggle-#{ws["id"]}"}
              phx-click="toggle_workspace_group"
              phx-value-id={ws["id"]}
              class="workspace-count-toggle"
              aria-expanded={
                to_string(not workspace_group_collapsed?(@collapsed_workspace_ids, ws["id"]))
              }
              aria-controls={"workspace-conversations-#{ws["id"]}"}
              title={
                if(workspace_group_collapsed?(@collapsed_workspace_ids, ws["id"]),
                  do: gettext("展开"),
                  else: gettext("收起")
                )
              }
              aria-label={
                if(workspace_group_collapsed?(@collapsed_workspace_ids, ws["id"]),
                  do: gettext("展开"),
                  else: gettext("收起")
                )
              }
            >
              <span
                id={"workspace-count-#{ws["id"]}"}
                class="workspace-conv-count"
                title={gettext("会话数量")}
              >
                {active_conversation_count(@conversations_by_workspace, ws["id"], @workspaces)}
              </span>
              <svg
                class={[
                  "workspace-chevron-icon",
                  workspace_group_collapsed?(@collapsed_workspace_ids, ws["id"]) && "is-collapsed"
                ]}
                width="10"
                height="10"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                stroke-width="2.5"
                aria-hidden="true"
              >
                <polyline points="6 9 12 15 18 9" />
              </svg>
            </button>
          </div>

          <% workspace_slice =
            workspace_conversation_slice(
              @conversations_by_workspace,
              ws["id"],
              @workspaces,
              @collapsed_thread_ids,
              sidebar_limit(@sidebar_visible_limits, ws["id"]),
              @current_conversation_id
            ) %>
          <div
            :if={not workspace_group_collapsed?(@collapsed_workspace_ids, ws["id"])}
            id={"workspace-conversations-#{ws["id"]}"}
            class="conversations-list"
          >
            <div
              :for={conv <- workspace_slice.rows}
              id={"conversation-#{conv.id}"}
              class={[
                "conversation-row",
                conv.tree_depth > 0 && "conversation-row-child"
              ]}
              data-conversation-menu-row
              data-conversation-id={conv.id}
              data-parent-conversation-id={conv.parent_id}
              data-thread-depth={conv.tree_depth}
              data-conversation-title={conv.title}
              data-conversation-age={conv.age}
              data-workspace-id={conv.workspace_id}
            >
              <button
                phx-click="select_conversation"
                phx-value-id={conv.id}
                phx-value-ws_id={conv.workspace_id}
                class={[
                  "conversation-item flex-1 min-w-0 text-left py-1.5 text-xs transition-colors flex items-center gap-1.5",
                  if(
                    @current_conversation_id == conv.id and
                      @current_workspace_id == conv.workspace_id,
                    do: "conversation-item-active",
                    else: "hover:bg-surface-hover text-tertiary"
                  )
                ]}
              >
                <span
                  :if={conv.tree_depth > 0}
                  class={[
                    "thread-tree-connector",
                    conv.tree_branch == :middle && "is-middle",
                    conv.tree_branch == :last && "is-last"
                  ]}
                  style={"--thread-indent: #{(conv.tree_depth - 1) * 12}px"}
                  aria-hidden="true"
                ></span>
                <.run_indicator
                  id={conv.id}
                  state={Map.get(@run_states, conv.id)}
                />
                <span class="truncate flex-1">{conv.title}</span>
              </button>
              <button
                :if={conv.child_count > 0}
                id={"thread-toggle-#{conv.id}"}
                type="button"
                phx-click="toggle_thread"
                phx-value-id={conv.id}
                class="thread-toggle"
                aria-expanded={to_string(not thread_collapsed?(@collapsed_thread_ids, conv.id))}
                aria-label={
                  if(thread_collapsed?(@collapsed_thread_ids, conv.id),
                    do: gettext("展开子对话"),
                    else: gettext("收起子对话")
                  )
                }
                title={
                  if(thread_collapsed?(@collapsed_thread_ids, conv.id),
                    do: gettext("展开子对话"),
                    else: gettext("收起子对话")
                  )
                }
              >
                <svg
                  class={[
                    "thread-toggle-icon",
                    thread_collapsed?(@collapsed_thread_ids, conv.id) && "is-collapsed"
                  ]}
                  width="10"
                  height="10"
                  viewBox="0 0 24 24"
                  fill="none"
                  stroke="currentColor"
                  stroke-width="2.5"
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  aria-hidden="true"
                >
                  <polyline points="6 15 12 9 18 15" />
                </svg>
              </button>
              <.conversation_menu conv={conv} conversation_menu_id={@conversation_menu_id} />
            </div>
            <button
              :if={workspace_slice.has_more?}
              id={"workspace-more-#{ws["id"]}"}
              type="button"
              phx-click="show_more_conversations"
              phx-value-bucket={ws["id"]}
              class="conversation-more-button"
              aria-label={gettext("显示更多对话")}
            >
              {gettext("更多")}
            </button>
          </div>
        </div>

        <div class="workspace-group workspace-add-entry">
          <button
            id="add-workspace"
            type="button"
            phx-click="open_add_project"
            class="workspace-add-entry-button"
            title={gettext("添加工作区")}
          >
            <svg
              width="20"
              height="20"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="1.8"
              stroke-linecap="round"
              stroke-linejoin="round"
              aria-hidden="true"
            >
              <path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" />
              <path d="M12 11v5M9.5 13.5h5" />
            </svg>
            <span>{gettext("添加工作区")}</span>
          </button>
        </div>

        <!-- Archived conversations -->
        <div class="workspace-group">
          <div class="workspace-title-row">
            <button
              phx-click="toggle_archive"
              class="workspace-header w-full text-left px-2 py-1.5 flex items-center gap-1.5 text-xs text-tertiary hover:bg-surface-hover transition-colors rounded"
              aria-expanded={to_string(@show_archive)}
            >
              <span class="workspace-icon" aria-hidden="true">
                <svg
                  width="20"
                  height="22"
                  viewBox="0 0 24 24"
                  fill="none"
                  stroke="currentColor"
                  stroke-width="2"
                  stroke-linecap="round"
                  stroke-linejoin="round"
                >
                  <rect x="3" y="3" width="18" height="4" rx="1" />
                  <path d="M5 7v12a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V7M10 11h4" />
                </svg>
              </span>
              <span>{gettext("已存档")}</span>
            </button>
            <span class="workspace-title-rule" aria-hidden="true"></span>
            <button
              type="button"
              phx-click="toggle_archive"
              class="workspace-count-toggle"
              aria-expanded={to_string(@show_archive)}
            >
              <span class="workspace-conv-count">
                {length(archived_conversations(@workspaces, @conversations_by_workspace))}
              </span>
            </button>
          </div>

          <div :if={@show_archive} class="conversations-list">
            <div
              :for={conv <- archived_conversations(@workspaces, @conversations_by_workspace)}
              id={"archived-conversation-#{conv.id}"}
              class="conversation-row archived"
              data-conversation-menu-row
              data-conversation-id={conv.id}
              data-conversation-title={conv.title}
              data-conversation-age={conv.age}
              data-workspace-id={conv.workspace_id}
            >
              <button
                phx-click="select_archived_conversation"
                phx-value-ws={conv.workspace_id}
                phx-value-id={conv.id}
                class={[
                  "conversation-item flex-1 min-w-0 text-left pl-6 pr-1 py-1.5 text-xs transition-colors flex items-center gap-1.5",
                  if(
                    archived_conversation_active?(
                      conv,
                      @current_conversation_id,
                      @current_workspace_id,
                      @chat_scope
                    ),
                    do: "conversation-item-active",
                    else: "hover:bg-surface-hover text-tertiary"
                  )
                ]}
              >
                <span class={[
                  "conversation-dot archived",
                  if(
                    archived_conversation_active?(
                      conv,
                      @current_conversation_id,
                      @current_workspace_id,
                      @chat_scope
                    ),
                    do: "conversation-dot-active",
                    else: ""
                  )
                ]}></span>
                <span class="truncate flex-1">{conv.title}</span>
                <span class="conversation-badge">
                  {if(conv.scope == "free", do: gettext("自由对话"), else: conv.workspace_label)}
                </span>
              </button>
              <button
                phx-click="unarchive_conversation"
                phx-value-id={conv.id}
                class="conversation-action restore"
                title={gettext("恢复")}
              >
                <svg width="11" height="11" viewBox="0 0 12 12" fill="none">
                  <path
                    d="M3 6.5a.5.5 0 0 1 .5-.5h5a.5.5 0 0 1 0 1h-5a.5.5 0 0 1-.5-.5z"
                    fill="currentColor"
                  /><path
                    d="M6 3.5a.5.5 0 0 1 .5.5v5a.5.5 0 0 1-1 0V4a.5.5 0 0 1 .5-.5z"
                    fill="currentColor"
                  />
                </svg>
              </button>
            </div>
          </div>
        </div>
      </div>
      <nav :if={@chat_scope == :workspace} class="sidebar-primary-nav" aria-label={gettext("工具")}>
        <button
          id="schedule-nav"
          type="button"
          phx-click="toggle_schedules"
          class={["sidebar-primary-nav-item", @show_schedules && "is-active"]}
          aria-current={if(@show_schedules, do: "page", else: nil)}
        >
          <span class="sidebar-primary-nav-icon" aria-hidden="true">
            <.clock_icon />
          </span>
          <span>{gettext("定时任务")}</span>
          <span :if={@schedule_count > 0} class="sidebar-primary-nav-count">{@schedule_count}</span>
        </button>
      </nav>
      <.conversation_hover_card
        conversations_by_workspace={@conversations_by_workspace}
        visible_ids={@visible_hover_ids}
      />
      <.workspace_hover_card />
    </div>
    """
  end

  defp conversation_row_active?(conv, current_id, current_workspace_id, chat_scope) do
    current_id == conv.id and
      if(conv.scope == "free",
        do: chat_scope == :free,
        else: current_workspace_id == conv.workspace_id and chat_scope != :free
      )
  end

  defp clock_icon(assigns) do
    ~H"""
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.8"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <circle cx="12" cy="12" r="8.5" />
      <path d="M12 7.5V12l3 2" />
    </svg>
    """
  end

  defp archived_conversation_active?(conv, current_id, current_workspace_id, chat_scope) do
    current_id == conv.id and
      if(conv.scope == "free",
        do: chat_scope == :free,
        else: current_workspace_id == conv.workspace_id
      )
  end
end
