defmodule HandbeanWeb.WorkspaceLive.SidebarHeaderComponents do
  @moduledoc false

  use HandbeanWeb, :html

  import HandbeanWeb.WorkspaceLive.ViewComponents
  import HandbeanWeb.WorkspaceLive.Schedules, only: [workspace_picker: 1]

  alias HandbeanWeb.WorkspaceLive.NewConversationDraft

  attr :chat_scope, :any, required: true
  attr :conversations_by_workspace, :any, required: true
  attr :current_workspace_id, :any, required: true
  attr :workspace_label, :any, required: true
  attr :workspaces, :any, required: true
  attr :show_schedules, :boolean, default: false
  attr :schedule_count, :integer, default: 0

  attr :current_conversation_id, :any, required: true
  attr :conversation_menu_id, :any, required: true
  attr :mobile_right_panel_open, :boolean, required: true
  attr :right_panel_view, :atom, required: true
  attr :terminal_available?, :boolean, required: true
  attr :new_conversation_draft, :any, required: true

  def mobile_header(assigns) do
    chat_scope =
      if NewConversationDraft.free_draft?(assigns.new_conversation_draft),
        do: :free,
        else: assigns.chat_scope

    conversations =
      case chat_scope do
        :free ->
          free_conversations(assigns.conversations_by_workspace)

        _ ->
          workspace_conversations(
            assigns.conversations_by_workspace,
            assigns.current_workspace_id,
            assigns.workspaces
          )
      end

    current_conversation = Enum.find(conversations, &(&1.id == assigns.current_conversation_id))

    assigns =
      assigns
      |> assign(:current_conversation, current_conversation)
      |> assign(:mobile_chat_scope, chat_scope)

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
            {mobile_header_label(@mobile_chat_scope, @workspace_label)}
          </span>
        </div>
        <span
          id="mobile-workspace-count"
          class="mobile-workspace-count"
          title={gettext("会话数量")}
        >
          {scoped_conversation_count(
            @conversations_by_workspace,
            @mobile_chat_scope,
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
      <button
        :if={not @show_schedules}
        id="mobile-open-conversation-search"
        type="button"
        phx-click="open_conversation_search"
        class="mobile-header-panel-btn"
        title={gettext("Search conversations")}
        aria-label={gettext("Search conversations")}
        aria-haspopup="dialog"
      >
        <svg
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
      <HandbeanWeb.WorkspaceLive.SidebarConversationComponents.conversation_menu
        :if={not @show_schedules && @current_conversation}
        conv={@current_conversation}
        conversation_menu_id={@conversation_menu_id}
        id_prefix="mobile-"
      />
      <span
        :if={@show_schedules}
        id="mobile-workspace-count"
        class="mobile-workspace-count"
        title={gettext("任务数量")}
      >
        {@schedule_count}
      </span>
    </div>
    <nav
      :if={not @show_schedules && @mobile_chat_scope != :free}
      class="mobile-workspace-tabs"
      aria-label={gettext("Workspace")}
    >
      <button
        id="mobile-tab-agent"
        type="button"
        phx-click="close_mobile_right_panel"
        aria-pressed={to_string(not @mobile_right_panel_open)}
      >
        Agent
      </button>
      <button
        :for={
          {view, label} <- [
            {"changes", gettext("Changes")},
            {"files", gettext("Files")},
            {"terminal", gettext("Terminal")}
          ]
        }
        :if={view != "terminal" || @terminal_available?}
        id={"mobile-tab-#{view}"}
        type="button"
        phx-click="select_mobile_right_panel_view"
        phx-value-view={view}
        aria-pressed={
          to_string(@mobile_right_panel_open && Atom.to_string(@right_panel_view) == view)
        }
      >
        {label}
      </button>
    </nav>
    """
  end

  defp mobile_header_label(:free, _workspace_label), do: gettext("自由对话")
  defp mobile_header_label(_chat_scope, workspace_label), do: workspace_label
end
