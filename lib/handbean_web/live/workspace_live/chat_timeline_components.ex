defmodule HandbeanWeb.WorkspaceLive.ChatTimelineComponents do
  @moduledoc false

  use HandbeanWeb, :html

  alias HandbeanWeb.FileChangeCard

  import HandbeanWeb.WorkspaceLive.ViewComponents

  attr :attachments, :any, default: []
  attr :entry_id, :any, required: true

  def attachment_gallery(assigns) do
    attachments = if is_list(assigns.attachments), do: assigns.attachments, else: []
    {images, files} = Enum.split_with(attachments, &image_attachment?/1)

    assigns =
      assigns
      |> assign(:images, images)
      |> assign(:files, files)

    ~H"""
    <div :if={@images != []} class="msg-shots">
      <button
        :for={{att, index} <- Enum.with_index(@images)}
        type="button"
        class="msg-shot"
        data-shot-open
        data-shot-id={"#{@entry_id}-#{index}"}
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
      :for={att <- @files}
      href={attachment_url(att)}
      target="_blank"
      rel="noreferrer"
      class="msg-file"
    >
      {attachment_filename(att)}
    </a>
    """
  end

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

  attr :current_assistant_entry_id, :any, required: true
  attr :current_conversation_id, :any, required: true
  attr :current_workspace_id, :any, required: true
  attr :history_before, :any, required: true
  attr :history_has_more?, :boolean, required: true
  attr :pending_approval, :any, required: true
  attr :pending_messages, :any, required: true
  attr :revert_confirm_change_id, :any, required: true
  attr :revert_message, :any, required: true
  attr :running, :boolean, required: true
  attr :status_info, :map, required: true
  attr :streams, :any, required: true
  attr :timeline, :list, required: true
  attr :user_time_zone, :any, required: true
  attr :workspace_root, :any, required: true

  def timeline(assigns) do
    ~H"""
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
            <HandbeanWeb.ConversationHandoff.card
              :if={HandbeanWeb.ConversationHandoff.show?(entry, @timeline)}
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
                  get_in(entry, ["origin", "kind"]) != "conversation" and reports == []
              }
              class="msg-row flex w-full msg-user justify-end"
              data-user-msg={entry["id"]}
            >
              <div class="msg-attachment-stack">
                <.attachment_gallery
                  attachments={entry["attachments"]}
                  entry_id={entry["id"]}
                />
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
                      :if={item[:status] == :queued and item[:deliver_as] == :follow_up}
                      type="button"
                      phx-click="send_pending_now"
                      phx-value-id={entry["id"]}
                      class="underline"
                    >
                      {gettext("Send now")}
                    </button>
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
                    <button
                      :if={item[:status] == :undelivered}
                      type="button"
                      phx-click="delete_undelivered"
                      phx-value-id={entry["id"]}
                      class="underline"
                    >
                      {gettext("Delete")}
                    </button>
                  </div>
                <% end %>
              </div>
            </div>

            <div
              :if={entry["content_type"] == "assistant_msg"}
              class="msg-row flex w-full msg-assistant justify-start"
              data-assistant-msg={entry["id"]}
            >
              <div class="msg-attachment-stack">
                <.attachment_gallery
                  attachments={entry["attachments"]}
                  entry_id={entry["id"]}
                />
                <div
                  :if={String.trim(to_string(entry["content"] || "")) != ""}
                  class="msg-bubble msg-assistant"
                >
                  <span class="sr-only">{entry["content"]}</span>
                  <div
                    id={"assistant-md-wrapper-#{entry["id"]}"}
                    data-entry-id={entry["id"]}
                    data-conversation-id={@current_conversation_id}
                    data-widget-actions="true"
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
    """
  end
end
