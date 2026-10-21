defmodule HandbeanWeb.WorkspaceLive.Schedules do
  @moduledoc """
  Task center: a scannable list of schedules plus a detail pane.

  The list projection is what every refresh pays for, so run history and
  conversation titles are loaded only while the center is visible.
  """

  use HandbeanWeb, :html

  import HandbeanWeb.WorkspaceLive.Schedules.Projection

  alias Handbean.ConversationStore
  alias Handbean.Schedule.{Presentation, Rule, Store}

  @run_history_limit 20

  def defaults(socket) do
    tz =
      case Phoenix.LiveView.get_connect_params(socket) do
        %{"time_zone" => zone} when is_binary(zone) -> zone
        _ -> nil
      end

    socket
    |> Phoenix.Component.assign(:user_time_zone, tz)
    |> reset()
  end

  def reset(socket) do
    socket
    |> Phoenix.Component.assign(:show_schedules, false)
    |> Phoenix.Component.assign(:schedule_request, "")
    |> Phoenix.Component.assign(:schedule_error, nil)
    |> Phoenix.Component.assign(:schedule_in_place, false)
    |> Phoenix.Component.assign(:schedule_target_conversation_id, nil)
    |> Phoenix.Component.assign(:schedule_target_workspace_id, nil)
    |> Phoenix.Component.assign(:schedules, [])
    |> Phoenix.Component.assign(:schedule_count, 0)
    |> Phoenix.Component.assign(:schedule_runs, %{})
    |> Phoenix.Component.assign(:schedule_views, %{})
    |> Phoenix.Component.assign(:schedule_conversation_titles, %{})
    |> Phoenix.Component.assign(:schedule_filter, "all")
    |> Phoenix.Component.assign(:schedule_query, "")
    |> Phoenix.Component.assign(:schedule_selected_id, :auto)
    |> Phoenix.Component.assign(:schedule_detail_open, false)
    |> Phoenix.Component.assign(:schedule_instruction_open, false)
  end

  def toggle(socket) do
    show = not socket.assigns.show_schedules

    socket
    |> Phoenix.Component.assign(:show_schedules, show)
    |> Phoenix.Component.assign(:schedule_error, nil)
    |> Phoenix.Component.assign(:schedule_detail_open, false)
    |> Phoenix.Component.assign(:schedule_instruction_open, false)
    |> reload()
  end

  @doc """
  Refresh what the current view needs.

  A closed center only needs the sidebar count: one aggregate instead of the
  2N+1 reads the open center performs.
  """
  def reload(socket) do
    cond do
      socket.assigns.chat_scope != :workspace ->
        socket
        |> Phoenix.Component.assign(:schedule_count, 0)
        |> clear_details()

      socket.assigns.show_schedules ->
        load_details(socket)

      true ->
        socket
        |> Phoenix.Component.assign(:schedule_count, Store.count())
        |> clear_details()
    end
  end

  defp load_details(socket) do
    schedules = Store.list()
    runs = Store.recent_runs_by_schedule(Enum.map(schedules, & &1.id), @run_history_limit)
    now = Handbean.Schedule.now()

    views =
      Map.new(schedules, fn entry ->
        {entry.id, Presentation.once(entry, Map.get(runs, entry.id, []), now)}
      end)

    socket
    |> Phoenix.Component.assign(:schedules, schedules)
    |> Phoenix.Component.assign(:schedule_count, length(schedules))
    |> Phoenix.Component.assign(:schedule_runs, runs)
    |> Phoenix.Component.assign(:schedule_views, views)
    |> Phoenix.Component.assign(:schedule_conversation_titles, conversation_titles(schedules))
    |> ensure_selection()
  end

  defp clear_details(socket) do
    socket
    |> Phoenix.Component.assign(:schedules, [])
    |> Phoenix.Component.assign(:schedule_runs, %{})
    |> Phoenix.Component.assign(:schedule_views, %{})
    |> Phoenix.Component.assign(:schedule_conversation_titles, %{})
    |> Phoenix.Component.assign(:schedule_selected_id, :auto)
  end

  # `:auto` follows the first visible task; `nil` means the reader closed the
  # pane on purpose and we do not reopen it behind their back.
  defp ensure_selection(socket) do
    ids = Enum.map(socket.assigns.schedules, & &1.id)

    case socket.assigns.schedule_selected_id do
      id when is_binary(id) -> if id in ids, do: socket, else: select_first(socket, ids)
      nil -> Phoenix.Component.assign(socket, :schedule_selected_id, nil)
      _auto_default -> select_first(socket, ids)
    end
  end

  defp select_first(socket, [id | _]),
    do: Phoenix.Component.assign(socket, :schedule_selected_id, id)

  defp select_first(socket, []), do: Phoenix.Component.assign(socket, :schedule_selected_id, nil)

  def prepare_ask(socket, text) do
    text = text |> to_string() |> String.trim()

    if text == "" do
      {:error, Phoenix.Component.assign(socket, :schedule_error, gettext("先说清何时、做什么"))}
    else
      {:ok,
       socket
       |> Phoenix.Component.assign(:schedule_request, "")
       |> Phoenix.Component.assign(:schedule_error, nil), text}
    end
  end

  def remember_request(socket, text) do
    Phoenix.Component.assign(socket, :schedule_request, to_string(text || ""))
  end

  def revise(socket, id) do
    case current(socket, id) do
      {:ok, entry} ->
        socket
        |> Phoenix.Component.assign(:schedule_request, revise_prompt(entry))
        |> Phoenix.Component.assign(:schedule_in_place, true)
        |> Phoenix.Component.assign(:schedule_target_conversation_id, entry.conversation_id)
        |> Phoenix.Component.assign(:schedule_target_workspace_id, entry.workspace_id)
        |> Phoenix.Component.assign(:schedule_error, nil)

      {:error, reason} ->
        Phoenix.Component.assign(socket, :schedule_error, inspect(reason))
    end
  end

  def pause(socket, id), do: mutate(socket, id, &Store.pause/1)
  def resume(socket, id), do: mutate(socket, id, &Store.resume/1)

  def delete(socket, id) do
    with {:ok, entry} <- current(socket, id),
         :ok <- Store.delete(entry) do
      reload(socket)
    else
      {:error, reason} -> Phoenix.Component.assign(socket, :schedule_error, inspect(reason))
    end
  end

  def run_now(socket, id) do
    with {:ok, entry} <- current(socket, id),
         {:ok, claim} <- Store.run_now(entry) do
      Handbean.Schedule.Dispatch.run(claim)
      reload(socket)
    else
      {:error, reason} -> Phoenix.Component.assign(socket, :schedule_error, inspect(reason))
    end
  end

  @doc "Select a schedule and reveal the detail pane on narrow screens."
  def select(socket, id) do
    socket
    |> Phoenix.Component.assign(:schedule_selected_id, id)
    |> Phoenix.Component.assign(:schedule_detail_open, true)
    |> Phoenix.Component.assign(:schedule_instruction_open, false)
  end

  def close_detail(socket) do
    socket
    |> Phoenix.Component.assign(:schedule_selected_id, nil)
    |> Phoenix.Component.assign(:schedule_detail_open, false)
  end

  def set_filter(socket, filter) do
    Phoenix.Component.assign(socket, :schedule_filter, normalize_filter(filter))
  end

  def set_query(socket, query) do
    Phoenix.Component.assign(socket, :schedule_query, to_string(query || ""))
  end

  def toggle_instruction(socket) do
    Phoenix.Component.assign(
      socket,
      :schedule_instruction_open,
      not socket.assigns.schedule_instruction_open
    )
  end

  attr :chat_scope, :any, required: true
  attr :schedules, :list, required: true
  attr :runs, :map, required: true
  attr :views, :map, required: true
  attr :count, :integer, default: 0
  attr :request, :string, default: ""
  attr :error, :any, default: nil
  attr :time_zone, :any, default: nil
  attr :workspace_id, :any, default: nil
  attr :workspace_label, :string, required: true
  attr :workspaces, :list, default: []
  attr :conversation_titles, :map, default: %{}
  attr :filter, :string, default: "all"
  attr :query, :string, default: ""
  attr :selected_id, :any, default: nil
  attr :detail_open, :boolean, default: false
  attr :instruction_open, :boolean, default: false

  def center(assigns) do
    now = Handbean.Schedule.now()
    scoped = workspace_entries(assigns.schedules, assigns.workspace_id)
    overdue = overdue_ids(scoped, now)
    visible = visible_entries(%{assigns | schedules: scoped}, overdue)
    selected = selected_entry(visible, assigns.selected_id)
    counts = filter_counts(scoped, assigns.runs, assigns.views, overdue)

    assigns =
      assigns
      |> assign(:scoped, scoped)
      |> assign(:overdue, overdue)
      |> assign(:visible, visible)
      |> assign(:selected, selected)
      |> assign(:filter_options, filters())
      |> assign(:counts, counts)
      |> assign(:attention_count, Map.get(counts, "attention", 0))

    ~H"""
    <section :if={@chat_scope == :workspace} id="schedule-center" class="schedule-center">
      <header class="schedule-center-header">
        <div class="schedule-center-heading">
          <span class="schedule-center-icon" aria-hidden="true">
            <.clock_icon />
          </span>
          <div>
            <h1>{gettext("定时任务")}</h1>
            <p>
              {gettext("管理定时任务，点对话可以跳转")}
              ·
              <.workspace_picker
                id="schedule-workspace"
                workspaces={@workspaces}
                workspace_id={@workspace_id}
              />
            </p>
          </div>
        </div>
        <button
          id="schedule-center-close"
          type="button"
          phx-click="toggle_schedules"
          class="schedule-secondary-button"
        >
          <span aria-hidden="true">←</span>
          {gettext("返回对话")}
        </button>
      </header>

      <div class="schedule-toolbar">
        <form id="schedule-ask" phx-submit="schedule_ask" phx-change="schedule_request">
          <input
            id="schedule-request"
            type="text"
            name="request"
            value={@request}
            phx-debounce="200"
            placeholder={gettext("工作日每天 09:00，把项目摘要发到这个聊天")}
            aria-label={gettext("新建任务")}
          />
          <button type="submit" class="schedule-primary-button">{gettext("交给 Agent")}</button>
        </form>
        <p class="schedule-toolbar-hint">
          {gettext("任务会在「%{workspace}」的新对话中运行并返回结果", workspace: @workspace_label)}
        </p>
        <p :if={@error} class="schedule-error" role="alert">{@error}</p>
      </div>

      <div class="schedule-filters" role="group" aria-label={gettext("按状态筛选任务")}>
        <button
          :for={{key, label} <- @filter_options}
          :key={key}
          type="button"
          class={["schedule-chip", key == "attention" and @attention_count > 0 and "is-alert"]}
          phx-click="schedule_filter"
          phx-value-filter={key}
          aria-pressed={to_string(@filter == key)}
        >
          {label}
          <span class="schedule-chip-count">{Map.get(@counts, key, 0)}</span>
        </button>
        <span class="schedule-filters-spacer"></span>
        <form id="schedule-search-form" phx-change="schedule_search" phx-submit="schedule_search">
          <input
            id="schedule-search"
            type="search"
            name="query"
            value={@query}
            phx-debounce="150"
            placeholder={gettext("搜索任务或指令")}
            aria-label={gettext("搜索任务或指令")}
            class="schedule-search"
          />
        </form>
      </div>

      <div class="schedule-body">
        <div class="schedule-list" id="schedule-list">
          <div :if={@visible == []} id="schedule-empty" class="schedule-empty">
            <span aria-hidden="true"><.clock_icon /></span>
            <h3>
              {if @scoped == [],
                do: gettext("还没有定时任务"),
                else: gettext("没有匹配的任务")}
            </h3>
            <p>
              {if @scoped == [],
                do: gettext("在上方描述一个任务，Agent 会确认时间和执行内容。"),
                else: gettext("换个关键词，或清空筛选条件。")}
            </p>
          </div>

          <article
            :for={entry <- @visible}
            :key={entry.id}
            id={"schedule-#{entry.id}"}
            class={[
              "schedule-row",
              entry.id == (@selected && @selected.id) && "is-selected",
              needs_attention?(@runs, @overdue, entry.id) && "needs-attention"
            ]}
            phx-click="schedule_select"
            phx-value-id={entry.id}
            data-schedule-id={entry.id}
          >
            <span
              class={[
                "schedule-dot",
                dot_class(entry, Map.get(@views, entry.id), @runs, overdue?(@overdue, entry.id))
              ]}
              aria-hidden="true"
            ></span>

            <div class="schedule-row-main">
              <h3 class="schedule-row-name">{entry.name}</h3>
              <p class="schedule-row-meta">
                <span
                  :if={
                    row_status(
                      entry,
                      Map.get(@views, entry.id),
                      Map.get(@runs, entry.id, []),
                      overdue?(@overdue, entry.id)
                    )
                  }
                  class="schedule-row-status"
                >
                  {row_status(
                    entry,
                    Map.get(@views, entry.id),
                    Map.get(@runs, entry.id, []),
                    overdue?(@overdue, entry.id)
                  )}
                </span>
                <span class="schedule-row-rule">{Rule.describe(entry.rule)}</span>
                <span class="schedule-sep" aria-hidden="true">·</span>
                <button
                  id={"schedule-#{entry.id}-conversation"}
                  type="button"
                  phx-click="open_schedule_conversation"
                  phx-value-id={entry.conversation_id}
                  phx-value-ws_id={entry.workspace_id}
                  title={gettext("打开对话")}
                  aria-label={
                    gettext("打开对话 %{title}", title: conversation_title(entry, @conversation_titles))
                  }
                >
                  {conversation_title(entry, @conversation_titles)}
                </button>
              </p>
            </div>

            <p class="schedule-row-next">
              <span>{next_date(entry, Map.get(@runs, entry.id, []), @time_zone)}</span>
              <span class="schedule-row-next-time">
                {next_time(entry, Map.get(@runs, entry.id, []), @time_zone)}
              </span>
            </p>

            <div class="schedule-row-actions">
              <button
                :if={row_action(entry, Map.get(@views, entry.id)) == :pause}
                type="button"
                phx-click="schedule_pause"
                phx-value-id={entry.id}
                class="schedule-icon-button"
                title={gettext("暂停")}
                aria-label={gettext("暂停 %{name}", name: entry.name)}
              >
                <.pause_icon />
              </button>
              <button
                :if={row_action(entry, Map.get(@views, entry.id)) == :resume}
                type="button"
                phx-click="schedule_resume"
                phx-value-id={entry.id}
                class="schedule-icon-button"
                title={gettext("恢复")}
                aria-label={gettext("恢复 %{name}", name: entry.name)}
              >
                <.play_icon />
              </button>
              <button
                type="button"
                phx-click="schedule_run_now"
                phx-value-id={entry.id}
                class="schedule-icon-button"
                title={gettext("立即运行")}
                aria-label={gettext("立即运行 %{name}", name: entry.name)}
              >
                <.run_icon />
              </button>
              <button
                type="button"
                phx-click="schedule_revise"
                phx-value-id={entry.id}
                class="schedule-icon-button"
                title={gettext("修改")}
                aria-label={gettext("修改 %{name}", name: entry.name)}
              >
                <.edit_icon />
              </button>
              <button
                type="button"
                phx-click="schedule_delete"
                phx-value-id={entry.id}
                class="schedule-icon-button is-danger"
                title={gettext("删除")}
                aria-label={gettext("删除 %{name}", name: entry.name)}
              >
                <.trash_icon />
              </button>
            </div>
          </article>
        </div>

        <aside
          class="schedule-detail"
          id="schedule-detail"
          data-open={to_string(@detail_open)}
          aria-label={gettext("任务详情")}
        >
          <div :if={is_nil(@selected)} class="schedule-detail-empty">
            <p>{gettext("从左侧选择一个任务，查看指令与运行历史。")}</p>
          </div>

          <div :if={@selected} class="schedule-detail-inner">
            <div class="schedule-detail-head">
              <div class="schedule-detail-heading">
                <p class="schedule-detail-status">
                  <span
                    class={[
                      "schedule-dot",
                      dot_class(
                        @selected,
                        Map.get(@views, @selected.id),
                        @runs,
                        overdue?(@overdue, @selected.id)
                      )
                    ]}
                    aria-hidden="true"
                  ></span>
                  {detail_status(
                    @selected,
                    Map.get(@views, @selected.id),
                    Map.get(@runs, @selected.id, []),
                    overdue?(@overdue, @selected.id)
                  )}
                </p>
                <h2>{@selected.name}</h2>
              </div>
              <button
                type="button"
                phx-click="schedule_close_detail"
                class="schedule-icon-button"
                aria-label={gettext("关闭详情")}
              >
                ✕
              </button>
            </div>

            <div class="schedule-detail-body">
              <dl class="schedule-meta">
                <dt>{gettext("频率")}</dt>
                <dd>{Rule.describe(@selected.rule)}</dd>
                <dt>{gettext("下次")}</dt>
                <dd>{next_label(@selected, Map.get(@runs, @selected.id, []), @time_zone)}</dd>
                <dt>{gettext("时区")}</dt>
                <dd>{@selected.time_zone}</dd>
                <dt>{gettext("模型")}</dt>
                <dd>{@selected.model}</dd>
                <dt>{gettext("对话")}</dt>
                <dd>
                  <button
                    type="button"
                    class="schedule-link"
                    phx-click="open_schedule_conversation"
                    phx-value-id={@selected.conversation_id}
                    phx-value-ws_id={@selected.workspace_id}
                  >
                    {conversation_title(@selected, @conversation_titles)}
                  </button>
                </dd>
              </dl>

              <div class="schedule-detail-section">
                <h3>{gettext("指令")}</h3>
                <button
                  :if={long_instruction?(@selected)}
                  type="button"
                  phx-click="schedule_instruction_toggle"
                  class="schedule-link"
                >
                  {if @instruction_open, do: gettext("收起"), else: gettext("展开")}
                </button>
              </div>
              <p
                id="schedule-instruction"
                class={instruction_class(@selected, @instruction_open)}
                phx-no-format
              >{String.trim(@selected.instruction || "")}</p>

              <div class="schedule-detail-section">
                <h3>{gettext("运行历史")}</h3>
                <span class="schedule-detail-count">
                  {gettext("最近 %{count} 次", count: length(Map.get(@runs, @selected.id, [])))}
                </span>
              </div>
              <p
                :if={Map.get(@runs, @selected.id, []) == []}
                class="schedule-detail-empty"
              >
                {gettext("还没有运行记录。")}
              </p>
              <ul class="schedule-runs">
                <li :for={run <- Map.get(@runs, @selected.id, [])} :key={run.id}>
                  <span class="schedule-run-when">{run_label(run, @selected.time_zone)}</span>
                  <span class="schedule-run-kind">{run_kind_label(run.kind)}</span>
                  <span class={["schedule-run-status", "is-#{run.status}"]}>
                    {run_status_label(run.status)}
                  </span>
                  <span :if={run.reason} class="schedule-run-reason">{run.reason}</span>
                  <button
                    :if={run.run_id}
                    type="button"
                    class="schedule-link"
                    phx-click="open_schedule_conversation"
                    phx-value-id={@selected.conversation_id}
                    phx-value-ws_id={@selected.workspace_id}
                  >
                    {gettext("查看对话")}
                  </button>
                </li>
              </ul>
            </div>

            <div class="schedule-detail-foot">
              <button
                :if={row_action(@selected, Map.get(@views, @selected.id)) == :pause}
                type="button"
                phx-click="schedule_pause"
                phx-value-id={@selected.id}
                class="schedule-secondary-button"
              >
                {gettext("暂停")}
              </button>
              <button
                :if={row_action(@selected, Map.get(@views, @selected.id)) == :resume}
                type="button"
                phx-click="schedule_resume"
                phx-value-id={@selected.id}
                class="schedule-secondary-button"
              >
                {gettext("恢复")}
              </button>
              <button
                type="button"
                phx-click="schedule_run_now"
                phx-value-id={@selected.id}
                class="schedule-primary-button"
              >
                {gettext("立即运行")}
              </button>
              <button
                type="button"
                phx-click="schedule_revise"
                phx-value-id={@selected.id}
                class="schedule-secondary-button"
              >
                {gettext("修改")}
              </button>
              <button
                type="button"
                phx-click="schedule_delete"
                phx-value-id={@selected.id}
                class="schedule-danger-button"
              >
                {gettext("删除")}
              </button>
            </div>
          </div>
        </aside>
      </div>
    </section>
    """
  end

  defp conversation_titles(schedules) do
    schedules
    |> Enum.map(& &1.conversation_id)
    |> ConversationStore.titles_for_ids()
  end

  defp mutate(socket, id, fun) do
    with {:ok, entry} <- current(socket, id),
         {:ok, _} <- fun.(entry) do
      reload(socket)
    else
      {:error, reason} -> Phoenix.Component.assign(socket, :schedule_error, inspect(reason))
    end
  end

  defp current(_socket, id), do: Store.get(id)

  defp revise_prompt(entry) do
    "把「#{entry.name}」改成："
  end

  attr :id, :string, required: true
  attr :workspaces, :list, required: true
  attr :workspace_id, :any, required: true

  def workspace_picker(assigns) do
    ~H"""
    <form id={"#{@id}-form"} phx-change="schedule_workspace" class="schedule-workspace-switch">
      <select id={@id} name="workspace_id" aria-label={gettext("当前工作区")}>
        <option :for={ws <- @workspaces} value={ws["id"]} selected={ws["id"] == @workspace_id}>
          {ws["name"]}
        </option>
      </select>
    </form>
    """
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

  defp pause_icon(assigns) do
    ~H"""
    <svg viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">
      <rect x="4.6" y="3.2" width="2.3" height="9.6" rx="0.6" />
      <rect x="9.1" y="3.2" width="2.3" height="9.6" rx="0.6" />
    </svg>
    """
  end

  defp play_icon(assigns) do
    ~H"""
    <svg viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">
      <path d="M4.2 3.1 12.6 8l-8.4 4.9z" />
    </svg>
    """
  end

  defp run_icon(assigns) do
    ~H"""
    <svg
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      stroke-width="1.5"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <path d="M8 2.6a5.4 5.4 0 1 0 5.4 5.4" />
      <path d="M13.4 2.6v3.4H10" />
    </svg>
    """
  end

  defp edit_icon(assigns) do
    ~H"""
    <svg
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      stroke-width="1.5"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <path d="M10.6 2.9 13.1 5.4 6 12.5l-3.1.6.6-3.1z" />
    </svg>
    """
  end

  defp trash_icon(assigns) do
    ~H"""
    <svg
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      stroke-width="1.5"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <path d="M2.8 4.6h10.4M6.2 4.6V3.1h3.6v1.5M4.2 4.6l.6 8.3h6.4l.6-8.3" />
    </svg>
    """
  end
end
