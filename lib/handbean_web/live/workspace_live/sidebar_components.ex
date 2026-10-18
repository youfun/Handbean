defmodule HandbeanWeb.WorkspaceLive.SidebarComponents do
  @moduledoc false

  use HandbeanWeb, :html

  import HandbeanWeb.WorkspaceLive.ViewComponents

  alias HandbeanWeb.WorkspaceLive.{ConversationState, ConversationSwitching}

  attr :chat_scope, :any, required: true
  attr :conversations_by_workspace, :any, required: true
  attr :current_conversation_id, :any, required: true
  attr :current_workspace_id, :any, required: true
  attr :terminal_available?, :any, required: true
  attr :workspace_label, :any, required: true
  attr :workspaces, :any, required: true
  attr :show_schedules, :boolean, default: false
  attr :schedule_count, :integer, default: 0

  def mobile_header(assigns) do
    ~H"""
    <div class="mobile-header-v2">
      <button
        id={if(@show_schedules, do: "mobile-schedule-back", else: nil)}
        phx-click={if(@show_schedules, do: "toggle_schedules", else: "open_sheet")}
        phx-value-type={if(@show_schedules, do: nil, else: "workspace")}
        class="mobile-header-workspace-btn"
        aria-label={if(@show_schedules, do: gettext("返回对话"), else: nil)}
      >
        <div class="mobile-header-title">
          <img
            :if={not @show_schedules}
            src={~p"/images/logo.svg"}
            class="brand-mark"
            width="18"
            height="18"
            alt=""
          />
          <svg
            :if={@show_schedules}
            class="mobile-schedule-back-icon"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            stroke-linecap="round"
            stroke-linejoin="round"
            aria-hidden="true"
          >
            <polyline points="15 18 9 12 15 6" />
          </svg>
          <span class="mobile-brand">Handbean</span>
          <span class="mobile-workspace truncate">
            {mobile_header_label(@show_schedules, @chat_scope, @workspace_label)}
          </span>
        </div>
        <span
          id="mobile-workspace-count"
          class="mobile-workspace-count"
          title={if(@show_schedules, do: gettext("任务数量"), else: gettext("会话数量"))}
        >
          {if(@show_schedules,
            do: @schedule_count,
            else:
              scoped_conversation_count(
                @conversations_by_workspace,
                @chat_scope,
                @current_workspace_id,
                @workspaces
              )
          )}
        </span>
        <svg
          :if={not @show_schedules}
          class="mobile-chevron"
          width="10"
          height="10"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="3"
          aria-hidden="true"
        >
          <polyline points="6 9 12 15 18 9" />
        </svg>
      </button>
      <div class="mobile-header-actions">
        <button
          :if={@chat_scope != :free and not @show_schedules}
          id="mobile-open-files"
          phx-click="select_mobile_right_panel_view"
          phx-value-view="files"
          class="mobile-header-panel-btn"
          aria-label={gettext("Files")}
          title={gettext("Files")}
        >
          <svg
            width="14"
            height="14"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            stroke-linecap="round"
            stroke-linejoin="round"
            aria-hidden="true"
          >
            <path d="M3 6h6l2 2h10v10H3z" />
          </svg>
        </button>
        <button
          :if={@terminal_available? and not @show_schedules}
          id="mobile-open-terminal"
          phx-click="select_mobile_right_panel_view"
          phx-value-view="terminal"
          class="mobile-header-panel-btn"
          aria-label={gettext("Terminal")}
          title={gettext("Terminal")}
        >
          <span aria-hidden="true">›_</span>
        </button>
        <button
          :if={not @show_schedules}
          phx-click="open_sheet"
          phx-value-type="settings"
          class="mobile-header-info-btn"
          aria-label={gettext("Conversation info")}
          title={gettext("Conversation info")}
        >
          <svg
            width="14"
            height="14"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            stroke-linecap="round"
            stroke-linejoin="round"
            aria-hidden="true"
          >
            <circle cx="12" cy="12" r="10" />
            <path d="M12 16v-4" />
            <path d="M12 8h.01" />
          </svg>
        </button>
        <.link
          id="mobile-open-settings"
          navigate={settings_href(@current_workspace_id, @current_conversation_id)}
          class="mobile-header-settings-btn"
          title={gettext("Settings")}
          aria-label={gettext("Settings")}
        >
          <svg
            width="14"
            height="14"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            stroke-linecap="round"
            stroke-linejoin="round"
            aria-hidden="true"
          >
            <circle cx="12" cy="12" r="3" />
            <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0 1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.68a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z" />
          </svg>
        </.link>
      </div>
    </div>
    """
  end

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
  attr :show_schedules, :boolean, default: false
  attr :schedule_count, :integer, default: 0

  def projects_sidebar(assigns) do
    assigns =
      assign(
        assigns,
        run_states: Map.new(assigns.runtime_tasks.tasks, &{&1.conversation_id, &1.status})
      )

    ~H"""
    <div
      id="activity-bar"
      phx-hook="ConversationSidebar"
      class="w-[220px] flex-shrink-0 border-r bg-surface flex flex-col workspace-panel projects-panel"
    >
      <div class="projects-panel-header">
        <h2 class="projects-panel-title">
          <img src={~p"/images/logo.svg"} class="brand-mark" width="16" height="16" alt="" />
          <span>{gettext("专案")}</span>
        </h2>
        <div class="projects-panel-new-conversation">
          <button
            id="new-conversation-picker-toggle"
            type="button"
            phx-click="toggle_new_conversation_picker"
            class="text-xs text-tertiary hover:text-primary transition-colors leading-none"
            title={gettext("新建对话")}
            aria-label={gettext("新建对话")}
            aria-haspopup="menu"
            aria-expanded={to_string(match?(%{source: :header}, @checkout_picker))}
          >
            +
          </button>
          <div
            :if={match?(%{source: :header}, @checkout_picker)}
            id="new-conversation-picker"
            class="workspace-checkout-menu projects-panel-new-conversation-menu"
            role="menu"
            phx-click-away="close_checkout_picker"
          >
            <%= if is_nil(@checkout_picker.workspace_id) do %>
              <div class="workspace-checkout-heading">{gettext("选择项目")}</div>
              <button
                :for={ws <- @workspaces}
                id={"new-conversation-project-#{ws["id"]}"}
                type="button"
                role="menuitem"
                phx-click="new_conversation_in_workspace"
                phx-value-ws_id={ws["id"]}
                phx-value-source="header"
                class="workspace-checkout-item"
                title={ws["path"]}
              >
                <span class="workspace-checkout-name">{ws["name"]}</span>
              </button>
            <% else %>
              <div class="workspace-checkout-heading">{gettext("Choose a checkout")}</div>
              <button
                :for={checkout <- @checkout_picker.checkouts}
                type="button"
                role="menuitem"
                phx-click="new_conversation_on_checkout"
                phx-value-ws_id={@checkout_picker.workspace_id}
                phx-value-path={checkout.path}
                class="workspace-checkout-item"
                title={checkout.path}
              >
                <span class="workspace-checkout-name">{Path.basename(checkout.path)}</span>
                <span :if={checkout_ref(checkout)} class="workspace-checkout-ref">
                  {checkout_ref(checkout)}
                </span>
              </button>
            <% end %>
          </div>
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
              <span class="truncate flex-1">{gettext("对话")}</span>
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
          <div
            :if={not workspace_group_collapsed?(@collapsed_workspace_ids, "free")}
            id="free-conversations"
            class="conversations-list"
          >
            <div
              :for={conv <- free_conversations(@conversations_by_workspace)}
              :if={not conv.pinned}
              id={"free-conversation-#{conv.id}"}
              class="conversation-row"
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

          <div
            :if={not workspace_group_collapsed?(@collapsed_workspace_ids, ws["id"])}
            id={"workspace-conversations-#{ws["id"]}"}
            class="conversations-list"
          >
            <div
              :for={
                conv <-
                  visible_workspace_conversations(
                    @conversations_by_workspace,
                    ws["id"],
                    @workspaces,
                    @collapsed_thread_ids
                  )
              }
              :if={!conv.archived and not conv.pinned}
              id={"conversation-#{conv.id}"}
              class={[
                "conversation-row",
                conv.tree_depth > 0 && "conversation-row-child"
              ]}
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
                    do: gettext("展开子线程"),
                    else: gettext("收起子线程")
                  )
                }
                title={
                  if(thread_collapsed?(@collapsed_thread_ids, conv.id),
                    do: gettext("展开子线程"),
                    else: gettext("收起子线程")
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
                <span class="thread-child-count" title={gettext("子线程数量")}>
                  {conv.child_count}
                </span>
              </button>
              <.conversation_menu conv={conv} conversation_menu_id={@conversation_menu_id} />
            </div>
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
                  {if(conv.scope == "free", do: gettext("对话"), else: conv.workspace_label)}
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
      <.conversation_hover_card conversations_by_workspace={@conversations_by_workspace} />
      <.workspace_hover_card />
    </div>
    """
  end

  defp workspace_hover_card(assigns) do
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

  attr :conversations_by_workspace, :map, required: true

  defp conversation_hover_card(assigns) do
    assigns =
      assign(assigns, :contexts, hover_contexts(assigns.conversations_by_workspace))

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

  defp hover_contexts(conversations_by_workspace) do
    conversations_by_workspace
    |> Map.values()
    |> List.flatten()
    |> Enum.map(fn conversation ->
      {ConversationState.conversation_id(conversation),
       ConversationSwitching.hover_context(conversation)}
    end)
    |> Enum.filter(fn {id, meta} ->
      is_binary(id) and (meta.folder || meta.branch || meta.path)
    end)
    |> Enum.uniq_by(&elem(&1, 0))
  end

  attr :id, :string, required: true
  attr :state, :atom, default: nil

  def run_indicator(assigns) do
    ~H"""
    <span
      class="conversation-run-indicator"
      data-run-id={@id}
      data-run-state={@state || :idle}
      role={@state && "img"}
      aria-label={
        case @state do
          :running ->
            gettext("运行中")

          :waiting_confirmation ->
            gettext("等待确认")

          _ ->
            nil
        end
      }
    >
      <svg
        class="conversation-idle-stem"
        viewBox="0 0 24 26"
        width="20"
        height="22"
        shape-rendering="crispEdges"
        aria-hidden="true"
      >
        <g transform="translate(0 7)">
          <path
            class="idle-stem-outline"
            d="M11 5h1v3h-1zM11 3h1v3h-1zM12 2h4v1h1v1h-1v1h-4V4h-1V3h1z"
          />
          <path class="idle-stem-fill" d="M12 3h4v1h-4z" />
          <path class="idle-stem-highlight" d="M13 2h2v1h-2z" />
        </g>
      </svg>
      <svg
        class="conversation-run-sprite"
        viewBox="0 0 24 26"
        width="20"
        height="22"
        shape-rendering="crispEdges"
        aria-hidden="true"
      >
        <path class="run-shadow" d="M6 24h12v1H6z" />
        <g class="run-character">
          <g class="run-outline">
            <path class="run-leg-left" d="M8 21h2v3H7v-1h1z" />
            <path class="run-leg-right" d="M15 21h2v2h1v1h-3z" />
          </g>
          <g class="run-upper">
            <g class="run-outline">
              <g class="run-arm-left">
                <path d="M4 16h1v4H4z" />
                <path class="run-fill" d="M3 19h2v2H3z" />
              </g>
              <g class="run-arm-right">
                <path d="M19 16h1v4h-1z" />
                <path class="run-fill" d="M19 19h2v2h-2z" />
              </g>
            </g>
            <g class="run-leaf">
              <path class="run-outline" d="M11 5h1v3h-1zM11 3h1v3h-1zM12 2h4v1h1v1h-1v1h-4V4h-1V3h1z" />
              <path class="run-fill" d="M12 3h4v1h-4z" />
              <path class="run-highlight" d="M13 2h2v1h-2z" />
            </g>
            <path class="run-outline" d="M9 8h6v1h2v1h1v1h1v10h-1v1h-1v1H7v-1H6v-1H5V11h1v-1h1V9h2z" />
            <path class="run-fill" d="M9 9h6v1h2v1h1v10h-1v1H7v-1H6V11h1v-1h2z" />
            <path class="run-highlight" d="M9 9h6v1h-1v1h-2v1H8v1H7v-2h1v-1h1z" />
            <path class="run-shade" d="M17 17h1v4h-1v1H7v-1h8v-1h1v-1h1z" />
            <path class="run-eyes" fill="#263b25" d="M8 14h2v2H8zM14 14h2v2h-2z" />
            <path fill="#db9968" d="M7 17h1v1H7zM16 17h1v1h-1z" />
          </g>
        </g>
      </svg>
    </span>
    """
  end

  attr :workspace_id, :string, required: true
  attr :picker, :any, default: nil
  attr :source, :atom, default: :sidebar

  def checkout_picker(assigns) do
    open? =
      ConversationSwitching.checkout_picker_open?(
        assigns.picker,
        assigns.workspace_id,
        assigns.source
      )

    checkouts = if open?, do: assigns.picker.checkouts, else: []

    click =
      if assigns.source == :mobile,
        do: "mobile_new_conversation_in_workspace",
        else: "new_conversation_in_workspace"

    assigns =
      assigns
      |> assign(:open?, open?)
      |> assign(:checkouts, checkouts)
      |> assign(:click, click)

    ~H"""
    <div class="workspace-checkout-picker">
      <button
        type="button"
        phx-click={@click}
        phx-value-ws_id={@workspace_id}
        class={[
          @source != :mobile &&
            "workspace-add-btn flex-shrink-0 w-5 h-5 flex items-center justify-center rounded text-tertiary hover:text-primary hover:bg-surface-hover transition-colors",
          @source == :mobile && "sheet-new-conv-btn",
          @open? && "is-open"
        ]}
        title={gettext("在此工作区新建对话")}
        aria-label={gettext("在此工作区新建对话")}
        aria-haspopup="menu"
        aria-expanded={to_string(@open?)}
      >
        <svg width="12" height="12" viewBox="0 0 12 12" fill="none" aria-hidden="true">
          <path
            d="M6 1v10M1 6h10"
            stroke="currentColor"
            stroke-width="1.5"
            stroke-linecap="round"
          />
        </svg>
      </button>
      <div
        :if={@open?}
        id={"checkout-picker-#{@source}-#{@workspace_id}"}
        class="workspace-checkout-menu"
        role="menu"
        phx-click-away="close_checkout_picker"
      >
        <div class="workspace-checkout-heading">{gettext("Choose a checkout")}</div>
        <button
          :for={checkout <- @checkouts}
          type="button"
          role="menuitem"
          phx-click="new_conversation_on_checkout"
          phx-value-ws_id={@workspace_id}
          phx-value-path={checkout.path}
          class="workspace-checkout-item"
          title={checkout.path}
        >
          <span class="workspace-checkout-name">{Path.basename(checkout.path)}</span>
          <span :if={checkout_ref(checkout)} class="workspace-checkout-ref">
            {checkout_ref(checkout)}
          </span>
        </button>
      </div>
    </div>
    """
  end

  defp checkout_ref(%{branch: branch}) when is_binary(branch) and branch != "", do: branch
  defp checkout_ref(%{detached?: true}), do: "detached"
  defp checkout_ref(_checkout), do: nil

  attr :conv, :map, required: true
  attr :conversation_menu_id, :any, required: true

  def conversation_menu(assigns) do
    ~H"""
    <div class="conversation-menu">
      <button
        type="button"
        phx-click="toggle_conversation_menu"
        phx-value-id={@conv.id}
        data-conversation-menu-toggle
        id={"conversation-menu-#{menu_scope_id(@conv)}-#{@conv.id}"}
        class={[
          "conversation-action",
          @conversation_menu_id == @conv.id && "is-open"
        ]}
        title={gettext("更多操作")}
        aria-label={gettext("更多操作")}
        aria-haspopup="menu"
        aria-expanded={to_string(@conversation_menu_id == @conv.id)}
      >
        <span class="sr-only">{gettext("更多操作")}</span>
        <svg width="12" height="12" viewBox="0 0 12 12" fill="currentColor" aria-hidden="true">
          <circle cx="2.25" cy="6" r="1" />
          <circle cx="6" cy="6" r="1" />
          <circle cx="9.75" cy="6" r="1" />
        </svg>
      </button>
      <div
        :if={@conversation_menu_id == @conv.id}
        id={"conversation-menu-panel-#{@conv.id}"}
        class="conversation-menu-panel"
        role="menu"
        phx-click-away="close_conversation_menu"
      >
        <button
          type="button"
          role="menuitem"
          phx-click="toggle_pin_conversation"
          phx-value-id={@conv.id}
          phx-value-ws_id={@conv.workspace_id}
          id={"conversation-action-pin-#{menu_scope_id(@conv)}-#{@conv.id}"}
          class="conversation-menu-item"
        >
          <svg width="12" height="12" viewBox="0 0 12 12" fill="none" aria-hidden="true">
            <path
              d="M4.1 1.4h3.8v1.7l1.2 1.2H2.9l1.2-1.2V1.4Z"
              stroke="currentColor"
              stroke-width="1.1"
              stroke-linejoin="round"
            />
            <path d="M6 4.3v6.3" stroke="currentColor" stroke-width="1.1" stroke-linecap="round" />
          </svg>
          <span>{if(@conv.pinned, do: gettext("取消置顶"), else: gettext("置顶"))}</span>
        </button>
        <button
          type="button"
          role="menuitem"
          phx-click="open_rename_conversation"
          phx-value-id={@conv.id}
          phx-value-ws_id={@conv.workspace_id}
          id={"conversation-action-rename-#{menu_scope_id(@conv)}-#{@conv.id}"}
          class="conversation-menu-item"
        >
          <svg width="12" height="12" viewBox="0 0 12 12" fill="none" aria-hidden="true">
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
          <span>{gettext("重命名")}</span>
        </button>
        <button
          type="button"
          role="menuitem"
          id={"conversation-action-copy-id-#{menu_scope_id(@conv)}-#{@conv.id}"}
          class="conversation-menu-item"
          phx-hook="CopyText"
          data-copy={@conv.id}
          title={gettext("复制会话 ID，用于线程通讯")}
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
          <span class="copy-idle">{gettext("复制 ID")}</span>
          <span class="copy-done">{gettext("已复制")}</span>
        </button>
        <button
          type="button"
          role="menuitem"
          phx-click="archive_conversation"
          phx-value-id={@conv.id}
          phx-value-ws_id={@conv.workspace_id}
          id={"conversation-action-archive-#{menu_scope_id(@conv)}-#{@conv.id}"}
          class="conversation-menu-item danger"
        >
          <svg width="12" height="12" viewBox="0 0 12 12" fill="none" aria-hidden="true">
            <path
              d="M2 3.5h8M4.5 3.5V2.75a.75.75 0 0 1 .75-.75h1.5a.75.75 0 0 1 .75.75V3.5M3 3.5l.5 6.75a.75.75 0 0 0 .75.75h3.5a.75.75 0 0 0 .75-.75L9 3.5"
              stroke="currentColor"
              stroke-width="1.1"
              stroke-linecap="round"
              stroke-linejoin="round"
            />
          </svg>
          <span>{gettext("归档")}</span>
        </button>
      </div>
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

  defp menu_scope_id(%{scope: "free"}), do: "free"
  defp menu_scope_id(%{workspace_id: id}) when is_binary(id) and id != "", do: id
  defp menu_scope_id(_), do: "free"

  defp mobile_header_label(true, _chat_scope, _workspace_label), do: gettext("定时任务")
  defp mobile_header_label(false, :free, _workspace_label), do: gettext("对话")
  defp mobile_header_label(false, _chat_scope, workspace_label), do: workspace_label

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
