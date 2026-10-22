defmodule HandbeanWeb.WorkspaceLive.SidebarHeaderComponents do
  @moduledoc false

  use HandbeanWeb, :html

  import HandbeanWeb.WorkspaceLive.ViewComponents
  import HandbeanWeb.WorkspaceLive.Schedules, only: [workspace_picker: 1]

  attr :chat_scope, :any, required: true
  attr :conversations_by_workspace, :any, required: true
  attr :current_workspace_id, :any, required: true
  attr :workspace_label, :any, required: true
  attr :workspaces, :any, required: true
  attr :show_schedules, :boolean, default: false
  attr :schedule_count, :integer, default: 0

  def mobile_header(assigns) do
    ~H"""
    <div class="mobile-header-v2">
      <button
        :if={@show_schedules}
        id="mobile-schedule-back"
        type="button"
        phx-click="toggle_schedules"
        class="mobile-header-panel-btn"
        aria-label={gettext("返回对话")}
      >
        <svg
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
      </button>
      <.workspace_picker
        :if={@show_schedules}
        id="mobile-schedule-workspace"
        workspaces={@workspaces}
        workspace_id={@current_workspace_id}
      />
      <button
        :if={not @show_schedules}
        phx-click="open_sheet"
        phx-value-type="workspace"
        class="mobile-header-workspace-btn"
      >
        <div class="mobile-header-title">
          <img src={~p"/images/logo.svg"} class="brand-mark" width="18" height="18" alt="" />
          <span class="mobile-brand">Handbean</span>
          <span class="mobile-workspace truncate">
            {mobile_header_label(@chat_scope, @workspace_label)}
          </span>
        </div>
        <span
          id="mobile-workspace-count"
          class="mobile-workspace-count"
          title={gettext("会话数量")}
        >
          {scoped_conversation_count(
            @conversations_by_workspace,
            @chat_scope,
            @current_workspace_id,
            @workspaces
          )}
        </span>
        <svg
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
      <span
        :if={@show_schedules}
        id="mobile-workspace-count"
        class="mobile-workspace-count"
        title={gettext("任务数量")}
      >
        {@schedule_count}
      </span>
    </div>
    """
  end

  defp mobile_header_label(:free, _workspace_label), do: gettext("自由对话")
  defp mobile_header_label(_chat_scope, workspace_label), do: workspace_label
end
