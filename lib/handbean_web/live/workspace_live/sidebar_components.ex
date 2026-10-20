defmodule HandbeanWeb.WorkspaceLive.SidebarComponents do
  @moduledoc false

  use HandbeanWeb, :html

  alias HandbeanWeb.WorkspaceLive.{
    SidebarCheckoutComponents,
    SidebarConversationComponents,
    SidebarHeaderComponents,
    SidebarListComponents
  }

  attr :chat_scope, :any, required: true
  attr :conversations_by_workspace, :any, required: true
  attr :current_conversation_id, :any, required: true
  attr :current_workspace_id, :any, required: true
  attr :terminal_available?, :any, required: true
  attr :workspace_label, :any, required: true
  attr :workspaces, :any, required: true
  attr :show_schedules, :boolean, default: false
  attr :schedule_count, :integer, default: 0

  def mobile_header(assigns), do: SidebarHeaderComponents.mobile_header(assigns)

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

  def projects_sidebar(assigns), do: SidebarListComponents.projects_sidebar(assigns)

  attr :id, :string, required: true
  attr :state, :atom, default: nil

  def run_indicator(assigns), do: SidebarConversationComponents.run_indicator(assigns)

  attr :workspace_id, :string, required: true
  attr :picker, :any, default: nil
  attr :source, :atom, default: :sidebar

  def checkout_picker(assigns), do: SidebarCheckoutComponents.checkout_picker(assigns)

  attr :picker, :any, default: nil

  def checkout_picker_dialog(assigns),
    do: SidebarCheckoutComponents.checkout_picker_dialog(assigns)

  attr :conv, :map, required: true
  attr :conversation_menu_id, :any, required: true

  def conversation_menu(assigns), do: SidebarConversationComponents.conversation_menu(assigns)
end
