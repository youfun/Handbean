defmodule HandbeanWeb.WorkspaceLive.OverlayComponents do
  @moduledoc false

  use HandbeanWeb, :html

  alias HandbeanWeb.WorkspaceLive.SidebarComponents

  import HandbeanWeb.WorkspaceLive.ViewComponents

  attr :available_models, :any, required: true
  attr :available_reasoning_levels, :any, required: true
  attr :chat_scope, :any, required: true
  attr :collapsed_workspace_ids, :any, required: true
  attr :checkout_picker, :any, default: nil
  attr :conversations_by_workspace, :any, required: true
  attr :current_conversation_id, :any, required: true
  attr :current_workspace_id, :any, required: true
  attr :mcp_count, :any, required: true
  attr :runtime_tasks, :map, default: %{tasks: []}
  attr :selected_cli, :any, default: nil
  attr :selected_model, :any, required: true
  attr :selected_reasoning_level, :any, required: true
  attr :show_model_sheet, :any, required: true
  attr :show_reasoning_sheet, :any, required: true
  attr :show_settings_sheet, :any, required: true
  attr :show_workspace_sheet, :any, required: true
  attr :show_schedules, :boolean, default: false
  attr :schedule_count, :integer, default: 0
  attr :skills_count, :any, required: true
  attr :status_info, :any, required: true
  attr :workspace_label, :any, required: true
  attr :workspaces, :any, required: true

  def mobile_sheets(assigns) do
    assigns =
      assign(
        assigns,
        run_states: Map.new(assigns.runtime_tasks.tasks, &{&1.conversation_id, &1.status})
      )

    ~H"""
    <div
      id="mobile-backdrop"
      aria-hidden="true"
      class={[
        "mobile-backdrop",
        if(
          any_sheet_open?(
            @show_workspace_sheet,
            @show_model_sheet,
            @show_reasoning_sheet,
            @show_settings_sheet
          ),
          do: "open",
          else: ""
        )
      ]}
      phx-click="close_sheets"
    >
    </div>

    <!-- Workspace / Conversation Switcher Sheet -->
    <div
      id="workspace-sheet"
      phx-hook="ConversationActivity"
      class={["bottom-sheet", if(@show_workspace_sheet, do: "open", else: "")]}
      aria-hidden={to_string(not @show_workspace_sheet)}
      inert={!@show_workspace_sheet}
    >
      <div class="sheet-handle"></div>
      <div class="bottom-sheet-inner">
        <button
          :if={@chat_scope == :workspace}
          id="mobile-schedule-nav"
          type="button"
          phx-click="toggle_schedules"
          class={["sheet-primary-row", @show_schedules && "active"]}
          aria-current={if(@show_schedules, do: "page", else: nil)}
        >
          <span class="sheet-primary-icon" aria-hidden="true">
            <svg
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="1.8"
              stroke-linecap="round"
              stroke-linejoin="round"
            >
              <circle cx="12" cy="12" r="8.5" />
              <path d="M12 7.5V12l3 2" />
            </svg>
          </span>
          <span class="flex-1">{gettext("定时任务")}</span>
          <span :if={@schedule_count > 0} class="sheet-primary-count">{@schedule_count}</span>
          <svg
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            stroke-linecap="round"
            stroke-linejoin="round"
            aria-hidden="true"
          >
            <polyline points="9 18 15 12 9 6" />
          </svg>
        </button>
        <div :if={pinned_conversations(@workspaces, @conversations_by_workspace) != []}>
          <div class="sheet-section-title">{gettext("已置顶")}</div>
          <div
            :for={conv <- pinned_conversations(@workspaces, @conversations_by_workspace)}
            id={"sheet-pinned-conversation-#{conv.id}"}
            class="sheet-conv-row"
          >
            <button
              phx-click={
                if(conv.scope == "free", do: "select_free_conversation", else: "select_conversation")
              }
              phx-value-id={conv.id}
              phx-value-ws_id={conv.workspace_id}
              class="sheet-conv-row"
            >
              <SidebarComponents.run_indicator
                id={conv.id}
                state={Map.get(@run_states, conv.id)}
              />
              <span class="truncate flex-1">{conv.title}</span>
            </button>
            <button
              type="button"
              phx-click="toggle_pin_conversation"
              phx-value-id={conv.id}
              class="conversation-action restore"
              title={gettext("取消置顶")}
              aria-label={gettext("取消置顶")}
            >
              <span aria-hidden="true">×</span>
            </button>
          </div>
        </div>
        <% free_collapsed? = workspace_group_collapsed?(@collapsed_workspace_ids, "free") %>
        <div class="sheet-section-title sheet-section-header">
          <button
            type="button"
            id="sheet-free-toggle"
            phx-click="toggle_workspace_group"
            phx-value-id="free"
            class="sheet-section-toggle"
            aria-expanded={to_string(not free_collapsed?)}
            aria-controls="sheet-free-conversations"
          >
            <span class="truncate flex-1 min-w-0">{gettext("对话")}</span>
            <span id="sheet-free-count" class="sheet-conv-count" title={gettext("会话数量")}>
              {free_conversation_count(@conversations_by_workspace)}
            </span>
            <svg
              class={["workspace-chevron-icon", free_collapsed? && "is-collapsed"]}
              width="12"
              height="12"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="2.5"
              aria-hidden="true"
            >
              <polyline points="6 9 12 15 18 9" />
            </svg>
          </button>
          <button
            id="sheet-new-free-conversation"
            phx-click="new_free_conversation"
            class="sheet-new-conv-btn"
            title={gettext("新建自由对话")}
            aria-label={gettext("新建自由对话")}
          >
            <svg
              width="16"
              height="16"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="2.5"
              stroke-linecap="round"
            >
              <line x1="12" y1="5" x2="12" y2="19" />
              <line x1="5" y1="12" x2="19" y2="12" />
            </svg>
          </button>
        </div>
        <div :if={not free_collapsed?} id="sheet-free-conversations">
          <button
            :for={conv <- free_conversations(@conversations_by_workspace)}
            :if={not conv.pinned}
            phx-click="select_free_conversation"
            phx-value-id={conv.id}
            class={[
              "sheet-conv-row",
              @current_conversation_id == conv.id && @chat_scope == :free && "active"
            ]}
          >
            <SidebarComponents.run_indicator
              id={conv.id}
              state={Map.get(@run_states, conv.id)}
            />
            <span class="truncate flex-1">{conv.title}</span>
          </button>
        </div>
        <%= for ws <- @workspaces do %>
          <% collapsed? = workspace_group_collapsed?(@collapsed_workspace_ids, ws["id"]) %>
          <div class="sheet-section-title sheet-section-header">
            <button
              type="button"
              id={"sheet-workspace-toggle-#{ws["id"]}"}
              phx-click="toggle_workspace_group"
              phx-value-id={ws["id"]}
              class="sheet-section-toggle"
              aria-expanded={to_string(not collapsed?)}
            >
              <span class="workspace-icon" aria-hidden="true">
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
                  <path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" />
                </svg>
              </span>
              <span class="truncate flex-1 min-w-0">{ws["name"]}</span>
              <span
                id={"sheet-workspace-count-#{ws["id"]}"}
                class="sheet-conv-count"
                title={gettext("会话数量")}
              >
                {active_conversation_count(@conversations_by_workspace, ws["id"], @workspaces)}
              </span>
              <svg
                class={["workspace-chevron-icon", collapsed? && "is-collapsed"]}
                width="12"
                height="12"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                stroke-width="2.5"
                aria-hidden="true"
              >
                <polyline points="6 9 12 15 18 9" />
              </svg>
            </button>
            <button
              :if={!ws["default"]}
              phx-click="open_remove_workspace"
              phx-value-id={ws["id"]}
              class="sheet-remove-workspace-btn"
              title={gettext("移除工作区")}
              aria-label={gettext("移除工作区")}
            >
              {gettext("移除")}
            </button>
            <SidebarComponents.checkout_picker
              workspace_id={ws["id"]}
              picker={@checkout_picker}
              source={:mobile}
            />
          </div>
          <%= if not workspace_group_collapsed?(@collapsed_workspace_ids, ws["id"]) do %>
            <%= for conv <- workspace_conversations(@conversations_by_workspace, ws["id"], @workspaces) |> Enum.reject(&(&1[:archived] or &1.pinned)) do %>
              <button
                phx-click="select_conversation"
                phx-value-id={conv.id}
                phx-value-ws_id={conv.workspace_id}
                class={[
                  "sheet-conv-row",
                  conv.tree_depth > 0 && "conversation-row-child",
                  if(
                    @current_conversation_id == conv.id and
                      @current_workspace_id == conv.workspace_id,
                    do: "active",
                    else: ""
                  )
                ]}
                data-parent-conversation-id={conv.parent_id}
                data-thread-depth={conv.tree_depth}
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
                <SidebarComponents.run_indicator
                  id={conv.id}
                  state={Map.get(@run_states, conv.id)}
                />
                <span class="truncate flex-1">{conv.title}</span>
                <span class="sheet-conv-time">{relative_time(conv)}</span>
              </button>
            <% end %>
          <% end %>
        <% end %>
        <button phx-click="open_add_project" class="sheet-add-row">
          <svg
            width="16"
            height="16"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2.5"
          >
            <line x1="12" y1="5" x2="12" y2="19" /><line x1="5" y1="12" x2="19" y2="12" />
          </svg>
          添加项目
        </button>
      </div>
    </div>

    <!-- Model Picker Sheet -->
    <div
      id="model-sheet"
      class={["bottom-sheet", if(@show_model_sheet, do: "open", else: "")]}
      aria-hidden={to_string(not @show_model_sheet)}
      inert={!@show_model_sheet}
    >
      <div class="sheet-handle"></div>
      <div class="bottom-sheet-inner">
        <%= if is_nil(@selected_cli) do %>
          <%= for {provider_id, models} <- models_by_provider(@available_models) do %>
            <div class="sheet-section-title">{provider_display_name(provider_id)}</div>
            <%= for m <- models do %>
              <button
                phx-click="select_model_from_sheet"
                phx-value-model={m.id}
                class={["sheet-select-row", if(m.id == @selected_model, do: "active", else: "")]}
              >
                <span>{model_option_label(m, models)}</span>
                <span
                  class="sheet-select-check"
                  style={"opacity: #{if m.id == @selected_model, do: "1", else: "0"}"}
                >
                  ✓
                </span>
              </button>
            <% end %>
          <% end %>
        <% else %>
          <%= for m <- @available_models do %>
            <button
              phx-click="select_model_from_sheet"
              phx-value-model={m.id}
              class={["sheet-select-row", if(m.id == @selected_model, do: "active", else: "")]}
            >
              <span>{m.display_name || m.id}</span>
            </button>
          <% end %>
        <% end %>
      </div>
    </div>

    <!-- Reasoning Picker Sheet -->
    <div
      id="reasoning-sheet"
      class={["bottom-sheet", if(@show_reasoning_sheet, do: "open", else: "")]}
      aria-hidden={to_string(not @show_reasoning_sheet)}
      inert={!@show_reasoning_sheet}
    >
      <div class="sheet-handle"></div>
      <div class="bottom-sheet-inner">
        <div class="sheet-section-title">{gettext("Reasoning Level")}</div>
        <%= for level <- @available_reasoning_levels do %>
          <button
            phx-click="select_reasoning_from_sheet"
            phx-value-level={level}
            class={[
              "sheet-select-row",
              if(level == @selected_reasoning_level, do: "active", else: "")
            ]}
          >
            <span>{reasoning_label(level)}</span>
            <span
              class="sheet-select-check"
              style={"opacity: #{if level == @selected_reasoning_level, do: "1", else: "0"}"}
            >
              ✓
            </span>
          </button>
        <% end %>
      </div>
    </div>

    <!-- Settings Sheet -->
    <div
      id="settings-sheet"
      class={["bottom-sheet", if(@show_settings_sheet, do: "open", else: "")]}
      aria-hidden={to_string(not @show_settings_sheet)}
      inert={!@show_settings_sheet}
    >
      <div class="sheet-handle"></div>
      <div class="bottom-sheet-inner">
        <div class="sheet-section-title">{gettext("Conversation info")}</div>
        <div class="mobile-settings-list">
          <div class="mobile-settings-row">
            <span>{gettext("Workspace")}</span>
            <strong class="truncate">{@workspace_label}</strong>
          </div>
          <div class="mobile-settings-row">
            <span>{gettext("Model")}</span>
            <strong class="truncate">{@status_info.model || gettext("None")}</strong>
          </div>
          <div class="mobile-settings-row">
            <span>{gettext("Status")}</span>
            <strong>{@status_info.status}</strong>
          </div>
          <div class="mobile-settings-row">
            <span>{gettext("Session")}</span>
            <strong class="truncate font-mono text-[11px]">
              {if @current_conversation_id,
                do: String.slice(@current_conversation_id, 0, 8),
                else: "none"}
            </strong>
          </div>
          <div class="mobile-settings-row">
            <span>{gettext("MCP / Skills")}</span>
            <strong>{@mcp_count} / {@skills_count}</strong>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :pending_approval, :any, required: true

  def approval_overlay(assigns) do
    ~H"""
    <%= if @pending_approval do %>
      <div id="tool-approval-overlay" class="tool-approval-overlay">
        <div class="approval-card bg-surface border rounded-xl shadow-2xl">
          <div class="approval-card-header">
            <h3 class="text-base font-semibold text-primary">
              ⚠ {if(@pending_approval[:kind] == :cli_agent,
                do: gettext("CLI approval required"),
                else: gettext("Tool Approval Required")
              )}
            </h3>
            <p class="text-xs text-secondary">
              {gettext("The agent wants to run the following tools. Review and approve or deny.")}
            </p>
          </div>

          <div class="approval-card-body">
            <div class="space-y-3">
              <%= for request <- approval_action_requests(@pending_approval) do %>
                <div class="bg-main border rounded-lg p-3">
                  <div class="flex items-center gap-2 mb-2">
                    <span class="font-mono font-bold text-xs text-accent">
                      {Handbean.Utils.SafeMap.get_any(request, ["tool_name", :tool_name])}
                    </span>
                    <span class="text-xs text-tertiary font-mono truncate">
                      {Handbean.Utils.SafeMap.get_any(request, ["tool_call_id", :tool_call_id])}
                    </span>
                  </div>
                  <div class="approval-arguments text-xs text-secondary font-mono rounded p-2">
                    <pre>{format_arguments(Handbean.Utils.SafeMap.get_any(request, ["arguments", :arguments]) || %{})}</pre>
                    <div class="mt-2 whitespace-pre-wrap font-sans">{schedule_preview(request)}</div>
                  </div>
                </div>
              <% end %>
            </div>

            <details
              :if={@pending_approval[:kind] != :cli_agent}
              id="approval-more-options"
              class="text-xs text-secondary"
            >
              <summary class="cursor-pointer py-2">{gettext("More approval options")}</summary>
              <div class="space-y-3 border rounded-lg p-3 mt-2">
                <p>{gettext("Session approval allows these tools for the rest of this run.")}</p>
                <button
                  phx-click="approve_all_tools"
                  phx-value-remember="session"
                  class="text-xs bg-surface text-primary border rounded px-3 py-2 transition-colors hover:bg-surface-hover"
                >
                  {gettext("This session")}
                </button>
                <p>{gettext("Always allow saves these rules in this workspace:")}</p>
                <ul class="approval-patterns space-y-1 font-mono">
                  <%= for request <- approval_action_requests(@pending_approval) do %>
                    <li>
                      {Handbean.Utils.SafeMap.get_any(request, [
                        :suggested_pattern,
                        "suggested_pattern"
                      ]) ||
                        Handbean.Utils.SafeMap.get_any(request, [:tool_name, "tool_name"])}
                    </li>
                  <% end %>
                </ul>
                <button
                  phx-click="approve_all_tools"
                  phx-value-remember="always"
                  class="text-xs bg-surface text-primary border rounded px-3 py-2 transition-colors hover:bg-surface-hover"
                >
                  {gettext("Always allow")}
                </button>
              </div>
            </details>
          </div>

          <div class="approval-card-actions">
            <button
              phx-click="deny_all_tools"
              class="text-xs bg-error-subtle text-error border border-error/30 rounded px-3 py-2 transition-colors hover:bg-error/10"
            >
              {gettext("Deny")}
            </button>
            <%= if @pending_approval[:kind] == :cli_agent do %>
              <button
                :for={option <- @pending_approval[:options] || []}
                :if={option["value"] not in [nil, "cancel"]}
                id={"cli-approval-#{option["value"]}"}
                phx-click="approve_cli_option"
                phx-value-option={option["value"]}
                class="text-xs bg-primary text-user rounded px-3 py-2 transition-colors"
              >
                {option["label"] || option["value"]}
              </button>
            <% else %>
              <button
                phx-click="approve_all_tools"
                class="text-xs bg-primary text-user rounded px-3 py-2 transition-colors"
              >
                {gettext("Allow once")}
              </button>
            <% end %>
          </div>
        </div>
      </div>
    <% end %>
    """
  end

  attr :current_conversation_id, :any, required: true
  attr :current_workspace_id, :any, required: true
  attr :mcp_count, :any, required: true
  attr :skills_count, :any, required: true
  attr :status_info, :any, required: true

  def status_bar(assigns) do
    ~H"""
    <div
      id="status-bar"
      class="h-8 border-t bg-surface flex items-center justify-between px-4 text-xs text-tertiary flex-shrink-0"
    >
      <div id="status-bar-left" class="flex items-center space-x-4">
        <.link
          id="open-settings"
          navigate={settings_href(@current_workspace_id, @current_conversation_id)}
          class="text-tertiary hover:text-primary transition-colors p-0.5 rounded hover:bg-gray-200 dark:hover:bg-gray-700 inline-flex no-underline"
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
          >
            <circle cx="12" cy="12" r="3" />
            <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.68a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z" />
          </svg>
        </.link>
        <span id="status-tokens">
          {gettext("Tokens:")}
          {gettext("input")}
          <span id="status-input-tokens" title={@status_info.input_tokens}>
            {format_tokens(@status_info.input_tokens)}
          </span>
          / {gettext("output")}
          <span id="status-output-tokens" title={@status_info.output_tokens}>
            {format_tokens(@status_info.output_tokens)}
          </span>
        </span>
        <span
          :if={has_cache_tokens?(@status_info)}
          id="status-cache-tokens"
          class="text-secondary"
          title="Prompt cache hits/writes (discounted tokens)"
        >
          {gettext("read")}
          <span id="status-cache-read" title={@status_info.cache_read_tokens}>
            {format_tokens(@status_info.cache_read_tokens)}
          </span>
          / {gettext("write")}
          <span id="status-cache-write" title={@status_info.cache_write_tokens}>
            {format_tokens(@status_info.cache_write_tokens)}
          </span>
        </span>
        <span
          id="status-cache-hit-rate"
          class="whitespace-nowrap"
          title={
            gettext(
              "This run: cached input / total input (including cache reads and writes). Not a cost saving rate. — means no cache activity reported."
            )
          }
        >
          {gettext("Cache hit")} {format_cache_hit_rate(@status_info)}
        </span>
        <span :if={@status_info.turns > 0}>
          {gettext("Turns:")} <span id="status-turns">{@status_info.turns}</span>
        </span>
        <span
          id="status-session-id"
          class="text-tertiary"
          data-session-id={@current_conversation_id || ""}
        >
          sid:{@current_conversation_id || "none"}
        </span>
        <span
          id="status-mcp-count"
          class="inline-flex items-center gap-1 whitespace-nowrap tabular-nums"
          title={"MCP servers: #{@mcp_count}"}
        >
          <span>MCP</span>
          <span>{@mcp_count}</span>
        </span>
        <span
          id="status-skills-count"
          class="inline-flex items-center gap-1 whitespace-nowrap tabular-nums"
          title={"Skills: #{@skills_count}"}
        >
          <span>Skills</span>
          <span>{@skills_count}</span>
        </span>
      </div>
      <div class="flex items-center space-x-4">
        <span class="flex items-center text-tertiary">
          <span
            id="status-dot"
            class={["status-dot", status_dot_class(@status_info.status)]}
          ></span>
          <span id="status-label">{@status_info.status}</span>
        </span>
      </div>
    </div>
    """
  end

  defp schedule_preview(request) do
    name = Handbean.Utils.SafeMap.get_any(request, [:tool_name, "tool_name"])
    args = Handbean.Utils.SafeMap.get_any(request, [:arguments, "arguments"]) || %{}
    action = to_string(Handbean.Utils.SafeMap.get_any(args, ["action", :action]) || "")

    if name == "schedule" and action in ["create", "update", "run_now"] do
      rule = Handbean.Utils.SafeMap.get_any(args, ["rule", :rule])
      zone = Handbean.Utils.SafeMap.get_any(args, ["time_zone", :time_zone]) || "UTC"

      upcoming =
        if is_map(rule) and Handbean.Schedule.Rule.valid_zone?(zone) do
          case Handbean.Schedule.Rule.upcoming(rule, zone, DateTime.utc_now(), 3) do
            {:ok, times} ->
              Enum.map_join(times, "\n", &Handbean.Schedule.Rule.format_local(&1, zone))

            _ ->
              ""
          end
        else
          ""
        end

      [
        Handbean.Schedule.Rule.describe(rule || %{}),
        zone,
        upcoming
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n")
    else
      ""
    end
  end
end
