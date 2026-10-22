defmodule HandbeanWeb.WorkspaceLive.ChatComponents do
  @moduledoc false

  use HandbeanWeb, :html

  alias HandbeanWeb.WorkspaceLive.ChatComposerComponents
  alias HandbeanWeb.WorkspaceLive.ChatDialogComponents
  alias HandbeanWeb.WorkspaceLive.ChatTimelineComponents

  attr :attachments, :any, default: []
  attr :entry_id, :any, required: true

  def attachment_gallery(assigns) do
    ~H"""
    <ChatTimelineComponents.attachment_gallery
      attachments={@attachments}
      entry_id={@entry_id}
    />
    """
  end

  attr :id, :string, required: true
  attr :report, :map, required: true

  def subagent_report_card(assigns) do
    ~H"""
    <ChatTimelineComponents.subagent_report_card id={@id} report={@report} />
    """
  end

  attr :add_project_form, :any, required: true
  attr :available_clis, :any, default: []
  attr :available_models, :any, required: true
  attr :available_reasoning_levels, :any, required: true
  attr :chat_scope, :any, required: true
  attr :composer_error, :any, required: true
  attr :current_assistant_entry_id, :any, required: true
  attr :current_conversation_id, :any, required: true
  attr :current_workspace_id, :any, required: true
  attr :file_browser_path, :any, required: true
  attr :history_before, :any, required: true
  attr :history_has_more?, :any, required: true
  attr :input_value, :any, required: true
  attr :mobile_right_panel_open, :any, required: true
  attr :pending_approval, :any, required: true
  attr :pending_attachments, :any, required: true
  attr :pending_messages, :any, required: true
  attr :permission_mode, :any, required: true
  attr :remove_workspace, :any, required: true
  attr :rename_workspace, :any, required: true
  attr :rename_conversation, :any, required: true
  attr :revert_confirm_change_id, :any, required: true
  attr :revert_message, :any, required: true
  attr :right_panel_collapsed, :any, required: true
  attr :running, :any, required: true
  attr :sandbox_workspace?, :any, required: true
  attr :cli_models_error, :any, default: nil
  attr :cli_models_loading, :boolean, default: false
  attr :selected_cli, :any, default: nil
  attr :selected_model, :any, required: true
  attr :selected_reasoning_level, :any, required: true
  attr :show_add_project, :any, required: true
  attr :show_file_browser, :any, required: true
  attr :show_permission_menu, :any, required: true
  attr :skill_suggestions, :any, required: true
  attr :speech_available?, :boolean, required: true
  attr :speech_state, :any, required: true
  attr :status_info, :map, default: %{}
  attr :streams, :any, required: true
  attr :timeline, :any, required: true
  attr :user_time_zone, :any, default: nil
  attr :uploads, :any, required: true
  attr :workspace_path, :any, required: true
  attr :workspace_root, :any, required: true

  def chat_panel(assigns) do
    ~H"""
    <div
      id="ai-panel"
      class={[
        "flex-1 flex flex-col min-w-0 workspace-panel chat-panel",
        if(@mobile_right_panel_open, do: "mobile-right-panel-open", else: "")
      ]}
    >
      <ChatDialogComponents.dialogs
        add_project_form={@add_project_form}
        file_browser_path={@file_browser_path}
        remove_workspace={@remove_workspace}
        rename_conversation={@rename_conversation}
        rename_workspace={@rename_workspace}
        sandbox_workspace?={@sandbox_workspace?}
        show_add_project={@show_add_project}
        show_file_browser={@show_file_browser}
      />
      <ChatTimelineComponents.timeline
        current_assistant_entry_id={@current_assistant_entry_id}
        current_conversation_id={@current_conversation_id}
        current_workspace_id={@current_workspace_id}
        history_before={@history_before}
        history_has_more?={@history_has_more?}
        pending_approval={@pending_approval}
        pending_messages={@pending_messages}
        revert_confirm_change_id={@revert_confirm_change_id}
        revert_message={@revert_message}
        running={@running}
        status_info={@status_info}
        streams={@streams}
        timeline={@timeline}
        user_time_zone={@user_time_zone}
        workspace_root={@workspace_root}
      />
      <ChatComposerComponents.composer
        available_clis={@available_clis}
        available_models={@available_models}
        available_reasoning_levels={@available_reasoning_levels}
        chat_scope={@chat_scope}
        cli_models_error={@cli_models_error}
        cli_models_loading={@cli_models_loading}
        composer_error={@composer_error}
        current_conversation_id={@current_conversation_id}
        input_value={@input_value}
        pending_attachments={@pending_attachments}
        permission_mode={@permission_mode}
        running={@running}
        selected_cli={@selected_cli}
        selected_model={@selected_model}
        selected_reasoning_level={@selected_reasoning_level}
        show_permission_menu={@show_permission_menu}
        skill_suggestions={@skill_suggestions}
        speech_available?={@speech_available?}
        speech_state={@speech_state}
        uploads={@uploads}
        workspace_path={@workspace_path}
      />
    </div>

    <button
      :if={@right_panel_collapsed and @chat_scope != :free}
      id="workspace-panel-expand"
      data-workspace-panel-toggle
      phx-click="toggle_right_panel"
      class="workspace-panel-toggle collapsed"
      title={gettext("Show workspace")}
      aria-label={gettext("Show workspace")}
      aria-pressed="false"
    >
      <svg
        width="16"
        height="16"
        viewBox="0 0 16 16"
        fill="none"
        stroke="currentColor"
        stroke-width="1.7"
        stroke-linecap="round"
        stroke-linejoin="round"
      >
        <rect x="2.5" y="3" width="11" height="10" rx="1.4" />
        <path d="M10.2 3v10" />
        <path d="M5.3 6.2 7.1 8 5.3 9.8" />
      </svg>
    </button>
    """
  end
end
