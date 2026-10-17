defmodule HandbeanWeb.WorkspaceLive.ChatComponents do
  @moduledoc false

  use HandbeanWeb, :html

  alias HandbeanWeb.Components.ModelPicker
  alias HandbeanWeb.FileChangeCard

  import HandbeanWeb.WorkspaceLive.ViewComponents

  attr :id, :string, required: true
  attr :report, :map, required: true

  def subagent_report_card(assigns) do
    ~H"""
    <div
      id={@id}
      class="subagent-report-card"
      data-subagent-report
      data-status={@report.status}
    >
      <details>
        <summary class="subagent-report-summary disclosure-summary">
          <span class="subagent-report-icon" aria-hidden="true">↳</span>
          <span class="subagent-report-title">
            <strong>{@report.subagent_type}</strong>
            <span aria-hidden="true">·</span>
            <span>{@report.status}</span>
            <span aria-hidden="true">·</span>
            <span>{report_availability_label(@report.availability)}</span>
          </span>
          <span class="disclosure-chevron" aria-hidden="true">⌄</span>
        </summary>

        <div class="subagent-report-body">
          <dl class="subagent-report-meta">
            <div :if={@report.child_conversation_id} class="subagent-report-meta-row">
              <dt>{gettext("Child ID")}</dt>
              <dd>
                <code>{@report.child_conversation_id}</code>
                <button
                  id={"#{@id}-copy-child"}
                  type="button"
                  class="subagent-report-action"
                  phx-hook="CopyText"
                  data-copy={@report.child_conversation_id}
                  title={gettext("Copy child ID")}
                  aria-label={gettext("Copy child ID")}
                >
                  {gettext("Copy")}
                </button>
              </dd>
            </div>
            <div :if={@report.child_run_id} class="subagent-report-meta-row">
              <dt>{gettext("Run ID")}</dt>
              <dd><code>{@report.child_run_id}</code></dd>
            </div>
            <div class="subagent-report-meta-row">
              <dt>{gettext("Status")}</dt>
              <dd>{@report.status}</dd>
            </div>
            <div
              :if={Enum.any?(@report.usage, fn {_key, value} -> is_integer(value) end)}
              class="subagent-report-meta-row"
            >
              <dt>Token</dt>
              <dd class="subagent-report-usage">
                <span :if={is_integer(@report.usage.input_tokens)}>
                  {gettext("Input")} {format_tokens(@report.usage.input_tokens)}
                </span>
                <span :if={is_integer(@report.usage.output_tokens)}>
                  {gettext("Output")} {format_tokens(@report.usage.output_tokens)}
                </span>
                <span :if={is_integer(@report.usage.cache_read_tokens)}>
                  {gettext("Cache read")} {format_tokens(@report.usage.cache_read_tokens)}
                </span>
                <span :if={is_integer(@report.usage.cache_write_tokens)}>
                  {gettext("Cache write")} {format_tokens(@report.usage.cache_write_tokens)}
                </span>
              </dd>
            </div>
          </dl>

          <div
            :if={@report.report != ""}
            id={"#{@id}-markdown"}
            data-entry-id={@id}
            data-source={@report.report}
            data-final="true"
            data-streaming="false"
            class="subagent-report-markdown msg-markdown-wrapper"
            phx-hook="StreamingMarkdown"
          >
            <button
              class="msg-copy-btn"
              title={gettext("Copy report")}
              aria-label={gettext("Copy report")}
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
                <rect x="9" y="9" width="13" height="13" rx="2" ry="2"></rect>
                <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"></path>
              </svg>
            </button>
            <div
              id={"#{@id}-markdown-content"}
              data-markdown-target
              phx-update="ignore"
              class="markdown-body prose prose-sm max-w-none break-words"
            >
              <div class="markdown-noscript-fallback">{@report.report}</div>
              <noscript>{@report.report}</noscript>
            </div>
          </div>

          <div :if={@report.report == ""} class="subagent-report-empty">
            {if @report.error != "", do: @report.error, else: gettext("Report content unavailable")}
          </div>

          <div class="subagent-report-footer">
            <button
              :if={@report.child_conversation_id}
              type="button"
              class="subagent-report-action subagent-report-follow-up"
              phx-click={
                JS.push("prefill_subagent_follow_up",
                  value: %{child: @report.child_conversation_id}
                )
                |> JS.focus(to: "#ai-input")
              }
            >
              {gettext("Follow up")}
            </button>
          </div>
        </div>
      </details>
    </div>
    """
  end

  defp report_availability_label(:available), do: gettext("Report available")
  defp report_availability_label(:failed), do: gettext("Report failed")
  defp report_availability_label(_), do: gettext("Report unavailable")

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
      <!-- Rename Conversation Dialog -->
      <div
        :if={@rename_conversation}
        id="rename-conversation-overlay"
        class="absolute inset-0 z-50 flex items-center justify-center"
        phx-window-keydown="cancel_rename_conversation"
        phx-key="Escape"
      >
        <button
          type="button"
          class="absolute inset-0 bg-transparent border-0"
          phx-click="cancel_rename_conversation"
          aria-label={gettext("取消")}
        ></button>
        <form
          id="rename-conversation-dialog"
          phx-submit="confirm_rename_conversation"
          class="relative add-project-dialog bg-surface border rounded-xl shadow-2xl w-[420px] p-5"
        >
          <h3 class="text-base font-semibold text-primary mb-4">{gettext("重命名会话")}</h3>
          <div class="space-y-3 mb-4">
            <div>
              <label for="rename-conversation-input" class="text-xs text-secondary block mb-1">
                {gettext("会话名称")}
              </label>
              <input
                id="rename-conversation-input"
                type="text"
                name="title"
                value={@rename_conversation.title}
                phx-mounted={JS.focus()}
                maxlength="80"
                autocomplete="off"
                class="w-full bg-main border rounded px-2 py-1.5 text-xs text-primary focus:outline-none focus:border-accent"
              />
            </div>
            <div
              :if={@rename_conversation.error}
              id="rename-conversation-error"
              class="text-xs text-error bg-error-subtle rounded px-3 py-2"
            >
              {@rename_conversation.error}
            </div>
          </div>
          <div class="flex justify-end gap-3">
            <button
              type="button"
              phx-click="cancel_rename_conversation"
              class="text-xs text-secondary border rounded px-3 py-1.5 transition-colors hover:text-primary hover:border-hover"
            >
              {gettext("取消")}
            </button>
            <button
              type="submit"
              id="rename-conversation-submit"
              class="text-xs bg-user text-white rounded px-4 py-1.5 transition-colors hover:bg-user-hover"
            >
              {gettext("保存")}
            </button>
          </div>
        </form>
      </div>

      <div
        :if={@rename_workspace}
        id="rename-workspace-overlay"
        class="absolute inset-0 z-50 flex items-center justify-center"
        phx-window-keydown="cancel_rename_workspace"
        phx-key="Escape"
      >
        <button
          type="button"
          class="absolute inset-0 bg-transparent border-0"
          phx-click="cancel_rename_workspace"
          aria-label={gettext("取消")}
        ></button>
        <form
          id="rename-workspace-dialog"
          phx-submit="confirm_rename_workspace"
          class="relative add-project-dialog bg-surface border rounded-xl shadow-2xl w-[420px] p-5"
        >
          <h3 class="text-base font-semibold text-primary mb-4">{gettext("重命名工作区")}</h3>
          <div class="space-y-3 mb-4">
            <div>
              <label for="rename-workspace-input" class="text-xs text-secondary block mb-1">
                {gettext("工作区名称")}
              </label>
              <input
                id="rename-workspace-input"
                type="text"
                name="name"
                value={@rename_workspace.name}
                phx-mounted={JS.focus()}
                maxlength="80"
                autocomplete="off"
                class="w-full bg-main border rounded px-2 py-1.5 text-xs text-primary focus:outline-none focus:border-accent"
              />
            </div>
            <div
              :if={@rename_workspace.error}
              id="rename-workspace-error"
              class="text-xs text-error bg-error-subtle rounded px-3 py-2"
            >
              {@rename_workspace.error}
            </div>
          </div>
          <div class="flex justify-end gap-3">
            <button
              type="button"
              phx-click="cancel_rename_workspace"
              class="text-xs text-secondary border rounded px-3 py-1.5 transition-colors hover:text-primary hover:border-hover"
            >
              {gettext("取消")}
            </button>
            <button
              type="submit"
              id="rename-workspace-submit"
              class="text-xs bg-user text-white rounded px-4 py-1.5 transition-colors hover:bg-user-hover"
            >
              {gettext("保存")}
            </button>
          </div>
        </form>
      </div>

      <div
        :if={@remove_workspace}
        id="remove-workspace-overlay"
        class="absolute inset-0 z-50 flex items-center justify-center"
        phx-window-keydown="cancel_remove_workspace"
        phx-key="Escape"
      >
        <button
          type="button"
          class="absolute inset-0 bg-transparent border-0"
          phx-click="cancel_remove_workspace"
          aria-label={gettext("取消")}
        ></button>
        <div
          id="remove-workspace-dialog"
          class="relative add-project-dialog bg-surface border rounded-xl shadow-2xl w-[420px] p-5"
        >
          <h3 class="text-base font-semibold text-primary mb-2">{gettext("移除工作区")}</h3>
          <p class="text-xs text-secondary mb-4">
            {gettext("移除「%{name}」后，其中的对话会进入已存档。项目目录不会被删除。",
              name: @remove_workspace.name
            )}
          </p>
          <div class="flex justify-end gap-3">
            <button
              type="button"
              phx-click="cancel_remove_workspace"
              class="text-xs text-secondary border rounded px-3 py-1.5 transition-colors hover:text-primary hover:border-hover"
            >
              {gettext("取消")}
            </button>
            <button
              type="button"
              id="confirm-remove-workspace"
              phx-click="confirm_remove_workspace"
              class="text-xs bg-error text-white rounded px-4 py-1.5 transition-colors"
            >
              {gettext("移除")}
            </button>
          </div>
        </div>
      </div>

      <!-- Add Project Dialog (overlay) -->
      <div
        :if={@show_add_project}
        id="add-project-overlay"
        class="absolute inset-0 z-50 flex items-center justify-center pointer-events-none"
      >
        <div class="pointer-events-auto add-project-dialog bg-surface border rounded-xl shadow-2xl w-[420px] p-5">
          <h3 class="text-base font-semibold text-primary mb-4">{gettext("添加项目")}</h3>

          <div class="space-y-3 mb-4">
            <div>
              <label class="text-xs text-secondary block mb-1">{gettext("项目路径")}</label>
              <div class="flex gap-2">
                <input
                  type="text"
                  name="add_path"
                  value={@add_project_form["path"]}
                  phx-keyup="update_add_path"
                  phx-value-value={@add_project_form["path"]}
                  placeholder={
                    if(@sandbox_workspace?,
                      do: gettext("使用系统选择器导入到应用内"),
                      else: "/path/to/project"
                    )
                  }
                  readonly={@sandbox_workspace?}
                  class="flex-1 bg-main border rounded px-2 py-1.5 text-xs text-primary font-mono focus:outline-none focus:border-accent"
                />
                <button
                  type="button"
                  phx-click="browse_folder"
                  class="text-xs bg-transparent border rounded px-3 py-1.5 text-secondary transition-colors hover:text-primary hover:border-hover whitespace-nowrap"
                >
                  {if @sandbox_workspace?, do: gettext("从下载导入…"), else: gettext("浏览...")}
                </button>
              </div>
              <p :if={@sandbox_workspace?} class="text-xs text-tertiary mt-2">
                {gettext(
                  "手机不能直接把系统下载目录当工作区。系统授权后会把所选文件夹复制进应用私有目录。Downloads 根目录在部分 Android 版本上不可选，请选其中的项目子文件夹。"
                )}
              </p>
            </div>
            <div>
              <label class="text-xs text-secondary block mb-1">{gettext("项目名称 (可选)")}</label>
              <input
                type="text"
                name="add_name"
                value={@add_project_form["name"]}
                phx-keyup="update_add_name"
                phx-value-value={@add_project_form["name"]}
                placeholder={Path.basename(@add_project_form["path"]) || gettext("自动填充")}
                class="w-full bg-main border rounded px-2 py-1.5 text-xs text-primary focus:outline-none focus:border-accent"
              />
            </div>
            <div class="flex items-center justify-between gap-4 py-1">
              <div>
                <label for="add-project-builtin-memory" class="text-xs text-primary block">
                  {gettext("使用自带的记忆功能")}
                </label>
                <p id="add-project-builtin-memory-desc" class="text-[11px] text-tertiary mt-0.5">
                  {gettext("关闭后可使用配置的外部记忆工具")}
                </p>
              </div>
              <label class="relative inline-flex items-center cursor-pointer h-4 shrink-0">
                <input
                  id="add-project-builtin-memory"
                  type="checkbox"
                  checked={@add_project_form["builtin_memory_enabled"]}
                  phx-click="toggle_add_project_memory"
                  aria-describedby="add-project-builtin-memory-desc"
                  class="sr-only peer"
                />
                <span class="settings-toggle-track">
                  <span class="settings-toggle-thumb"></span>
                </span>
              </label>
            </div>
            <div
              :if={@add_project_form["error"]}
              class="text-xs text-error bg-error-subtle rounded px-3 py-2"
            >
              {@add_project_form["error"]}
            </div>
          </div>

          <div class="flex justify-end gap-3">
            <button
              phx-click="cancel_add_project"
              class="text-xs text-secondary border rounded px-3 py-1.5 transition-colors hover:text-primary hover:border-hover"
            >
              {gettext("取消")}
            </button>
            <button
              phx-click="confirm_add_project"
              class="text-xs bg-user text-white rounded px-4 py-1.5 transition-colors hover:bg-user-hover"
            >
              {gettext("添加项目")}
            </button>
          </div>
        </div>
      </div>

      <!-- File Browser (LiveComponent) -->
      <.live_component
        module={HandbeanWeb.FileBrowserComponent}
        id="file-browser"
        show_browser={@show_file_browser}
        current_path={@file_browser_path}
      />

      <!-- Chat messages -->
      <div class="conversation-nav-host">
        <div
          id="ai-messages"
          class="flex-1 overflow-y-auto p-4 space-y-3"
          phx-hook="ChatScroll"
          data-conversation-id={@current_conversation_id || ""}
          data-history-before={@history_before || ""}
          data-history-has-more={to_string(@history_has_more?)}
        >
          <div :if={length(@timeline) > 1} id="turn-header" class="turn-header">
            <span class="turn-summary">
              {timeline_summary(@timeline)}
            </span>
          </div>
          <div
            id="timeline-stream"
            phx-update="stream"
            class={["space-y-3", if(@timeline == [], do: "", else: "turn-group")]}
            data-running={@running}
          >
            <div :for={{dom_id, entry} <- @streams.timeline} id={dom_id} data-run-id={entry["run_id"]}>
              <% reports = delegation_reports(entry) %>
              <HandbeanWeb.ThreadHandoff.card
                :if={HandbeanWeb.ThreadHandoff.show?(entry, @timeline)}
                entry={entry}
                conversation_id={@current_conversation_id}
                workspace_id={@current_workspace_id}
                time_zone={@user_time_zone}
              />
              <.subagent_report_card
                :for={report <- reports}
                id={"subagent-report-#{entry["id"] || dom_id}-#{report.key}"}
                report={report}
              />
              <div
                :if={
                  entry["content_type"] == "user_msg" and
                    get_in(entry, ["origin", "kind"]) != "thread" and reports == []
                }
                class="msg-row flex w-full msg-user justify-end"
                data-user-msg={entry["id"]}
              >
                <% attachments =
                  if(is_list(entry["attachments"]), do: entry["attachments"], else: []) %>
                <% {images, files} = Enum.split_with(attachments, &image_attachment?/1) %>
                <div class="msg-user-stack">
                  <div :if={images != []} class="msg-shots">
                    <button
                      :for={{att, index} <- Enum.with_index(images)}
                      type="button"
                      class="msg-shot"
                      data-shot-open
                      data-shot-id={"#{entry["id"]}-#{index}"}
                      data-shot-src={attachment_url(att)}
                      data-shot-name={attachment_filename(att)}
                      title={attachment_filename(att)}
                      aria-label={gettext("查看图片 %{name}", name: attachment_filename(att))}
                    >
                      <img
                        src={attachment_url(att)}
                        alt={attachment_filename(att)}
                        decoding="async"
                      />
                    </button>
                  </div>
                  <a
                    :for={att <- files}
                    href={attachment_url(att)}
                    target="_blank"
                    rel="noreferrer"
                    class="msg-file"
                  >
                    {attachment_filename(att)}
                  </a>
                  <div
                    :if={
                      String.trim(to_string(entry["content"] || "")) != "" or
                        get_in(entry, ["origin", "kind"]) == "automatic"
                    }
                    class="msg-bubble msg-user"
                  >
                    <div
                      :if={get_in(entry, ["origin", "kind"]) == "automatic"}
                      class="text-xs opacity-60 mb-1"
                    >
                      Automatic · {get_in(entry, ["origin", "source"])}
                    </div>
                    <div class="whitespace-pre-wrap break-words">{entry["content"]}</div>
                  </div>
                  <%= if item = Map.get(@pending_messages || %{}, entry["id"]) do %>
                    <div class="mt-1 flex items-center gap-2 text-xs opacity-70">
                      <span>
                        {cond do
                          item[:status] == :undelivered ->
                            gettext("Not delivered")

                          @pending_approval ->
                            gettext("Inserts after approval")

                          item[:deliver_as] == :follow_up ->
                            gettext("Queued · when this run finishes")

                          true ->
                            gettext("Waiting to insert · next step")
                        end}
                      </span>
                      <button
                        :if={item[:status] == :queued}
                        type="button"
                        phx-click="cancel_pending"
                        phx-value-id={entry["id"]}
                        class="underline"
                      >
                        {gettext("Undo")}
                      </button>
                      <button
                        :if={item[:status] == :undelivered}
                        type="button"
                        phx-click="resend_pending"
                        phx-value-id={entry["id"]}
                        class="underline"
                      >
                        {gettext("Resend")}
                      </button>
                    </div>
                  <% end %>
                </div>
              </div>

              <div
                :if={entry["content_type"] == "assistant_msg"}
                class="msg-row flex w-full msg-assistant justify-start"
              >
                <div class="msg-bubble msg-assistant">
                  <span class="sr-only">{entry["content"]}</span>
                  <div
                    id={"assistant-md-wrapper-#{entry["id"]}"}
                    data-entry-id={entry["id"]}
                    data-source={entry["content"] || ""}
                    data-final={
                      to_string(
                        assistant_message_final?(entry, @running, @current_assistant_entry_id)
                      )
                    }
                    data-streaming={
                      to_string(
                        assistant_message_streaming?(entry, @running, @current_assistant_entry_id)
                      )
                    }
                    class="msg-markdown-wrapper"
                    phx-hook="StreamingMarkdown"
                  >
                    <button
                      class="msg-copy-btn"
                      title="复制回复"
                      aria-label="复制回复"
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
                      >
                        <rect x="9" y="9" width="13" height="13" rx="2" ry="2"></rect>
                        <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"></path>
                      </svg>
                    </button>
                    <div
                      id={"assistant-md-content-#{entry["id"]}"}
                      data-markdown-target
                      phx-update="ignore"
                      class="markdown-body prose prose-sm max-w-none break-words"
                    >
                      <div class="markdown-noscript-fallback">{entry["content"]}</div>
                      <noscript>{entry["content"]}</noscript>
                    </div>
                  </div>
                </div>
              </div>

              <div
                :if={entry["content_type"] == "system_msg"}
                class="msg-row flex w-full msg-assistant justify-start"
              >
                <div class="msg-bubble msg-system">
                  <div class="whitespace-pre-wrap break-words">{entry["content"]}</div>
                </div>
              </div>

              <div
                :if={entry["content_type"] == "tool"}
                class={[
                  "tool-event tool-card",
                  render_tool_status(tool_entry_status(entry)),
                  if(entry["work_group_first"], do: "tool-work-lead"),
                  if(entry["work_group_id"] && !entry["work_group_first"],
                    do: "tool-work-follow"
                  ),
                  if(entry["work_collapsed"], do: "tool-work-collapsed"),
                  if(!entry["work_collapsed"],
                    do: "tool-work-open"
                  )
                ]}
              >
                <button
                  :if={entry["work_group_first"] && entry["work_group_complete"]}
                  type="button"
                  id={"tool-work-summary-#{entry["work_group_id"]}"}
                  class="tool-work-summary"
                  phx-click="toggle_tool_work"
                  phx-value-group={entry["work_group_id"]}
                  aria-expanded={to_string(entry["work_collapsed"] != true)}
                >
                  <span>{entry["work_summary"]}</span>
                  <span class="tool-work-chevron" aria-hidden="true">
                    {if(entry["work_collapsed"], do: "›", else: "⌄")}
                  </span>
                </button>
                <div
                  :if={!entry["work_collapsed"] && !FileChangeCard.change_entry?(entry)}
                  id={"tool-work-line-#{entry["id"]}"}
                  class={"tool-work-line indent-#{entry["work_indent"] || 1}"}
                >
                  <span class="tool-work-verb">{entry["work_verb"]}</span>
                  <span
                    :if={(entry["work_target"] || "") != ""}
                    class="tool-work-target"
                  >
                    {entry["work_target"]}
                  </span>
                </div>
                <% render_tool_details? =
                  entry["work_collapsed"] != true or entry["work_group_first"] %>
                <% install_prompt =
                  if(render_tool_details?, do: browser_install_prompt(entry), else: nil) %>
                <% preview_card = if(render_tool_details?, do: preview_card(entry), else: nil) %>
                <% browser_takeover =
                  if(render_tool_details?, do: browser_takeover_prompt(entry), else: nil) %>
                <div
                  :if={preview_card}
                  id={"preview-card-#{entry["id"]}"}
                  class="preview-card mt-2 rounded border border-edge px-2 py-2"
                >
                  <p class="text-xs text-primary">{preview_card.title}</p>
                  <p class="mt-1 text-xs text-tertiary">{preview_card.preview_id}</p>
                  <div class="mt-2 flex items-center gap-2">
                    <button
                      id={"open-preview-#{entry["id"]}"}
                      type="button"
                      class="text-xs text-tertiary hover:text-primary"
                      phx-click="open_preview"
                      phx-value-id={preview_card.preview_id}
                    >
                      {gettext("打开预览")}
                    </button>
                    <button
                      id={"open-preview-external-#{entry["id"]}"}
                      type="button"
                      class="text-xs text-tertiary hover:text-primary"
                      phx-click="open_preview_external"
                      phx-value-id={preview_card.preview_id}
                    >
                      {gettext("用浏览器打开")}
                    </button>
                  </div>
                </div>
                <div
                  :if={browser_takeover}
                  id={"browser-takeover-#{entry["id"]}"}
                  class="browser-takeover-prompt mt-2 rounded border border-edge px-2 py-2"
                >
                  <p class="text-xs text-primary">{gettext("接管浏览器")}</p>
                  <p class="mt-1 text-xs text-tertiary">{browser_takeover.reason}</p>
                  <button
                    id={"takeover-browser-#{entry["id"]}"}
                    type="button"
                    class="mt-2 text-xs text-tertiary hover:text-primary"
                    phx-click="takeover_browser"
                    phx-value-session={browser_takeover.session_id}
                  >
                    {gettext("接管浏览器")}
                  </button>
                </div>
                <div
                  :if={install_prompt}
                  id={"browser-install-#{entry["id"]}"}
                  class="browser-install-prompt mt-2 rounded border border-edge px-2 py-2"
                >
                  <p class="text-xs text-primary">{install_prompt.title}</p>
                  <div class="mt-1 flex items-center gap-2">
                    <code
                      id={"browser-install-cmd-#{entry["id"]}"}
                      class="flex-1 text-xs font-mono break-all"
                    >
                      {install_prompt.command}
                    </code>
                    <button
                      id={"browser-install-copy-#{entry["id"]}"}
                      type="button"
                      class="text-xs text-tertiary hover:text-primary"
                      phx-hook="CopyText"
                      data-copy={install_prompt.command}
                      title="Copy install command"
                      aria-label="Copy install command"
                    >
                      Copy
                    </button>
                  </div>
                  <p class="mt-1 text-xs text-tertiary">{install_prompt.hint}</p>
                </div>
                <div
                  :if={render_tool_details? && is_nil(install_prompt) && tool_entry_error(entry)}
                  class="mt-1 text-error truncate"
                >
                  {inspect(tool_entry_error(entry))}
                </div>
                <.card
                  :if={render_tool_details? && FileChangeCard.change_entry?(entry)}
                  entry={entry}
                  open?={entry["file_change_open"] == true}
                  id={"chat-file-change-#{entry["id"]}"}
                  class={
                    if(!entry["work_collapsed"],
                      do: "tool-work-file indent-#{entry["work_indent"] || 1}"
                    )
                  }
                  confirm_change_id={@revert_confirm_change_id}
                  message={@revert_message}
                  workspace_root={@workspace_root}
                />
              </div>
            </div>
          </div>

          <!-- Agent working indicator -->
          <div
            :if={@running and @timeline != []}
            id="agent-working"
            class="agent-working"
          >
            <span class="aw-dot dot" aria-hidden="true"></span>
            <span>{gettext("Agent is working...")}</span>
            <span
              :if={is_binary(@status_info[:status_detail]) and @status_info[:status_detail] != ""}
              id="agent-working-detail"
              class="text-xs text-tertiary"
            >
              ({@status_info[:status_detail]})
            </span>
          </div>

          <!-- Empty state: no messages yet -->
          <div
            :if={@timeline == [] and !@running}
            id="no-messages"
            class="empty-state"
          >
            <p class="empty-state-title">{gettext("No messages yet")}</p>
            <p class="empty-state-subtitle">{gettext("Type a message to start")}</p>
          </div>
        </div>
        <% user_nav_items = user_message_nav_items(@timeline) %>
        <div
          id="conversation-nav"
          class={["conversation-nav", if(length(user_nav_items) >= 2, do: "has-many")]}
          phx-hook="ConversationNav"
        >
          <div
            :if={length(user_nav_items) >= 2}
            id="conversation-nav-panel"
            class="conversation-nav-panel"
            data-conversation-nav-panel
            hidden
            role="dialog"
            aria-label={gettext("对话导航")}
          >
            <div class="conversation-nav-panel-head">
              <span data-conversation-nav-counter>
                {length(user_nav_items)}/{length(user_nav_items)}
              </span>
              <span class="conversation-nav-panel-hint">{gettext("用户消息")}</span>
            </div>
            <div class="conversation-nav-list" role="list">
              <button
                :for={item <- user_nav_items}
                type="button"
                class="conversation-nav-item"
                data-target-id={item.id}
                data-index={item.index}
                role="listitem"
              >
                <span class="conversation-nav-item-summary">{item.summary}</span>
                <span :if={item.age != ""} class="conversation-nav-item-age">{item.age}</span>
              </button>
            </div>
          </div>
          <div class="conversation-nav-buttons">
            <button
              :if={length(user_nav_items) >= 2}
              type="button"
              class="conversation-nav-btn"
              data-conversation-nav-toggle
              aria-expanded="false"
              aria-controls="conversation-nav-panel"
              aria-label={gettext("对话导航")}
            >
              <svg
                width="16"
                height="16"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                stroke-width="2.2"
                stroke-linecap="round"
                aria-hidden="true"
              >
                <line x1="4" y1="7" x2="20" y2="7" />
                <line x1="4" y1="12" x2="20" y2="12" />
                <line x1="4" y1="17" x2="20" y2="17" />
              </svg>
            </button>
            <button
              id="mobile-fab"
              type="button"
              class="conversation-nav-btn conversation-nav-bottom"
              data-conversation-nav-bottom
              phx-click="scroll_to_bottom"
              aria-label={gettext("滚到底部")}
            >
              <svg
                width="16"
                height="16"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                stroke-width="2.5"
                stroke-linecap="round"
                stroke-linejoin="round"
                aria-hidden="true"
              >
                <polyline points="6 9 12 15 18 9" />
              </svg>
            </button>
          </div>
        </div>
      </div>

      <!-- Input area -->
      <div id="ai-input-area" class="composer-dock">
        <form
          id="composer"
          phx-submit="send_message"
          phx-drop-target={@uploads.images.ref}
          phx-change="composer_drop"
          class={["composer dropzone", if(@running, do: "composer-running", else: "")]}
        >
          <div
            :if={@composer_error}
            class="composer-error"
          >
            <span class="truncate">{@composer_error}</span>
            <button type="button" phx-click="clear_composer_error">
              dismiss
            </button>
          </div>

          <div class="composer-turn-controls">
            <div class="composer-turn-pickers">
              <div :if={@available_clis != []} class="model-control">
                <select
                  id="cli-picker"
                  name="cli"
                  phx-hook="BoundSelect"
                  data-value={HandbeanWeb.WorkspaceLive.CliSelection.form_value(@selected_cli)}
                  phx-change="select_cli"
                  aria-label={gettext("CLI")}
                  title={gettext("Handbean owns the turn unless a CLI is selected")}
                >
                  <option value="" selected={is_nil(@selected_cli)}>
                    {gettext("Handbean")}
                  </option>
                  <option
                    :for={cli <- @available_clis}
                    value={cli.id}
                    selected={is_binary(@selected_cli) and cli.id == @selected_cli}
                  >
                    {cli.id}
                  </option>
                </select>
              </div>
              <div :if={@cli_models_error} id="cli-models-error" class="composer-model-error">
                {HandbeanWeb.WorkspaceLive.CliSelection.error_message(@cli_models_error)}
              </div>
              <div :if={is_nil(@selected_cli) and @available_models != []} class="model-control">
                <ModelPicker.render
                  id="model-picker"
                  name="model"
                  value={@selected_model}
                  options={composer_model_options(@available_models)}
                  label={gettext("模型")}
                  title={gettext("可在对话中途更换模型")}
                  change="select_model"
                  refresh="refresh_models"
                  compact
                />
              </div>
              <div :if={is_binary(@selected_cli) and @available_models != []} class="model-control">
                <ModelPicker.render
                  id="cli-model-picker"
                  name="model"
                  value={@selected_model}
                  options={cli_model_options(@available_models)}
                  label={gettext("CLI model")}
                  change="select_model"
                  compact
                />
              </div>
              <div :if={@available_reasoning_levels != []} class="model-control">
                <select
                  id="reasoning-picker"
                  name="reasoning"
                  value={@selected_reasoning_level}
                  phx-hook="BoundSelect"
                  data-value={@selected_reasoning_level || ""}
                  phx-change="select_reasoning"
                  aria-label={gettext("推理等级")}
                  title={gettext("推理等级")}
                >
                  <option
                    :for={level <- @available_reasoning_levels}
                    value={level}
                    selected={level == @selected_reasoning_level}
                  >
                    {reasoning_label(level)}
                  </option>
                </select>
              </div>
            </div>
            <div
              :if={@cli_models_loading}
              id="cli-models-loading"
              class="flex items-center gap-1.5 text-[11px] leading-[1.3] text-tertiary"
              role="status"
            >
              <span class="loading loading-spinner loading-xs" aria-hidden="true"></span>
              {gettext("Loading CLI models…")}
            </div>
            <div
              :if={
                @available_models == [] and is_nil(@cli_models_error) and
                  not @cli_models_loading
              }
              class="composer-model-error"
            >
              {model_empty_message(@workspace_path)}
            </div>
            <div class="permission-menu-container">
              <button
                type="button"
                class="pill"
                phx-click="toggle_permission_menu"
                title={permission_title(@permission_mode)}
              >
                {permission_label(@permission_mode)} ▾
              </button>
              <div
                :if={@show_permission_menu}
                phx-click-away="close_sheets"
                class="permission-dropdown-menu"
              >
                <button
                  :for={
                    {mode, label} <- [
                      {:prompt, gettext("安全模式")},
                      {:auto_review, gettext("智能审批")},
                      {:yolo, gettext("yolo")}
                    ]
                  }
                  type="button"
                  phx-click="select_permission_mode"
                  phx-value-mode={mode}
                  class={["permission-dropdown-item", if(@permission_mode == mode, do: "active")]}
                  title={permission_title(mode)}
                >
                  {label}
                </button>
              </div>
            </div>
          </div>

          <div class="composer-bar">
            <div class="textarea-wrap">
              <label class="sr-only" for="ai-input">{gettext("消息")}</label>
              <textarea
                id="ai-input"
                name="message"
                rows="1"
                phx-keyup="update_input"
                phx-value-value={@input_value}
                phx-hook="ComposerPasteUpload"
                data-upload-name="images"
                placeholder={
                  if(@running,
                    do: gettext("Running: send inserts next · queue waits until this run finishes"),
                    else: gettext("输入消息")
                  )
                }
              >{Phoenix.HTML.Form.normalize_value("textarea", @input_value)}</textarea>

              <div
                :if={@skill_suggestions not in [nil, []]}
                id="skill-suggestions"
                class="skill-suggestions-dropdown"
                phx-click-away="dismiss_skill_suggestions"
              >
                <div
                  :for={skill <- @skill_suggestions}
                  class="skill-suggestion-item"
                >
                  <button
                    type="button"
                    phx-click="select_skill_suggestion"
                    phx-value-name={skill.name}
                    class="skill-suggestion-btn"
                  >
                    <span class="skill-suggestion-name">/skill:{skill.name}</span>
                    <span class="skill-suggestion-desc">{skill.description}</span>
                  </button>
                </div>
              </div>
            </div>

            <div class="composer-toolbar">
              <div
                id="composer-attachments"
                class={[
                  "composer-thumbs",
                  if(@pending_attachments != [] or @uploads.images.entries != [],
                    do: "visible"
                  )
                ]}
              >
                <div :for={entry <- @uploads.images.entries} class="composer-thumb">
                  <.live_img_preview entry={entry} />
                  <span class="sr-only">{entry.client_name}</span>
                  <button
                    type="button"
                    phx-click="cancel_upload"
                    phx-value-ref={entry.ref}
                    class="composer-thumb-remove"
                    aria-label={gettext("移除 %{name}", name: entry.client_name)}
                  >
                    ×
                  </button>
                </div>
                <div :for={att <- @pending_attachments} class="composer-thumb">
                  <img
                    src={Handbean.Utils.SafeMap.get_any(att, [:url, "url"])}
                    alt={Handbean.Utils.SafeMap.get_any(att, [:filename, "filename"])}
                  />
                  <button
                    type="button"
                    phx-click="remove_attachment"
                    phx-value-id={Handbean.Utils.SafeMap.get_any(att, [:id, "id"])}
                    class="composer-thumb-remove"
                    aria-label={
                      gettext("移除 %{name}",
                        name:
                          Handbean.Utils.SafeMap.get_any(att, [:filename, "filename"]) ||
                            gettext("附件")
                      )
                    }
                  >
                    ×
                  </button>
                </div>
              </div>

              <div class="composer-toolbar-actions">
                <label class="composer-icon-btn" title={gettext("添加图片")}>
                  <span class="sr-only">{gettext("添加图片")}</span>
                  <svg
                    width="16"
                    height="16"
                    viewBox="0 0 24 24"
                    fill="none"
                    stroke="currentColor"
                    stroke-width="1.8"
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    aria-hidden="true"
                  >
                    <path d="M21.44 11.05l-8.49 8.49a5.25 5.25 0 0 1-7.42-7.42l8.48-8.49a3.5 3.5 0 0 1 4.95 4.95l-8.48 8.49a1.75 1.75 0 1 1-2.47-2.47l7.78-7.78" />
                  </svg>
                  <.live_file_input upload={@uploads.images} class="hidden" />
                </label>

                <button
                  :if={@running}
                  type="button"
                  phx-click="stop_run"
                  class="composer-icon-btn composer-stop-btn"
                  title={gettext("Stop")}
                >
                  <span class="sr-only">{gettext("Stop")}</span>
                  <span class="composer-stop-square" aria-hidden="true"></span>
                </button>
                <button
                  :if={@running}
                  id="queue-button"
                  type="button"
                  phx-click="queue_message"
                  phx-value-message={@input_value}
                  class="composer-icon-btn"
                  title={gettext("When done")}
                >
                  <span class="sr-only">{gettext("When done")}</span>
                  <span aria-hidden="true">☰</span>
                </button>
                <button
                  id="send-button"
                  type="submit"
                  form="composer"
                  phx-disable-with="…"
                  class={["composer-send-btn", if(@running, do: "steer", else: "primary")]}
                  title={gettext("Send")}
                >
                  <span class="sr-only">{gettext("Send")}</span>
                  <svg
                    width="14"
                    height="14"
                    viewBox="0 0 24 24"
                    fill="none"
                    stroke="currentColor"
                    stroke-width="2.4"
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    aria-hidden="true"
                  >
                    <path d="M5 12h14" />
                    <path d="M13 6l6 6-6 6" />
                  </svg>
                  <span :if={@running} class="composer-steer-dot" aria-hidden="true"></span>
                </button>
              </div>
            </div>
          </div>
        </form>
      </div>
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

  defp composer_model_options(models) do
    models
    |> models_by_provider()
    |> Enum.flat_map(fn {provider_id, provider_models} ->
      group = provider_display_name(provider_id)

      Enum.map(provider_models, fn model ->
        ModelPicker.option(model.id, model_option_label(model, provider_models), group)
      end)
    end)
  end

  defp cli_model_options(models) do
    Enum.map(models, fn model ->
      ModelPicker.option(model.id, model.display_name || model.id)
    end)
  end
end
