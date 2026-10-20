defmodule HandbeanWeb.WorkspaceLive.SidebarHeaderComponents do
  @moduledoc false

  use HandbeanWeb, :html

  import HandbeanWeb.WorkspaceLive.ViewComponents

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

  defp mobile_header_label(true, _chat_scope, _workspace_label), do: gettext("定时任务")
  defp mobile_header_label(false, :free, _workspace_label), do: gettext("对话")
  defp mobile_header_label(false, _chat_scope, workspace_label), do: workspace_label
end
