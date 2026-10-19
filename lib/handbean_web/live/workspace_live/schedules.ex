defmodule HandbeanWeb.WorkspaceLive.Schedules do
  @moduledoc """
  Task center: a scannable list of schedules plus a detail pane.

  The list projection is what every refresh pays for, so run history and
  conversation titles are loaded only while the center is visible.
  """

  use HandbeanWeb, :html

  alias Handbean.ConversationStore
  alias Handbean.Schedule.{Presentation, Rule, Store}

  @run_history_limit 20

  # A slot this far past due means the clock is stalled or the run is stuck.
  @overdue_grace_seconds 120

  @filters [
    {"all", "全部"},
    {"active", "已启用"},
    {"paused", "已暂停"},
    {"ended", "已结束"},
    {"attention", "需处理"}
  ]

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

  defp normalize_filter(filter) when is_binary(filter) do
    if Enum.any?(@filters, fn {key, _label} -> key == filter end), do: filter, else: "all"
  end

  defp normalize_filter(_filter), do: "all"

  attr :chat_scope, :any, required: true
  attr :schedules, :list, required: true
  attr :runs, :map, required: true
  attr :views, :map, required: true
  attr :count, :integer, default: 0
  attr :request, :string, default: ""
  attr :error, :any, default: nil
  attr :time_zone, :any, default: nil
  attr :workspace_label, :string, required: true
  attr :conversation_titles, :map, default: %{}
  attr :filter, :string, default: "all"
  attr :query, :string, default: ""
  attr :selected_id, :any, default: nil
  attr :detail_open, :boolean, default: false
  attr :instruction_open, :boolean, default: false

  def center(assigns) do
    now = Handbean.Schedule.now()
    overdue = overdue_ids(assigns.schedules, now)
    visible = visible_entries(assigns, overdue)
    selected = selected_entry(visible, assigns.selected_id)
    counts = filter_counts(assigns.schedules, assigns.runs, assigns.views, overdue)

    assigns =
      assigns
      |> assign(:overdue, overdue)
      |> assign(:visible, visible)
      |> assign(:selected, selected)
      |> assign(:filter_options, @filters)
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
            <p>{gettext("管理定时任务，点对话可以跳转")} · {@workspace_label}</p>
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
          {gettext("任务会在默认工作区的新对话中运行并返回结果")}
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
              {if @schedules == [],
                do: gettext("还没有定时任务"),
                else: gettext("没有匹配的任务")}
            </h3>
            <p>
              {if @schedules == [],
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

  # Filter options and counts are derived, never stored: one owner for the list.
  defp selected_entry(_visible, nil), do: nil
  defp selected_entry(visible, :auto), do: List.first(visible)

  defp selected_entry(visible, id) do
    Enum.find(visible, &(&1.id == id)) || List.first(visible)
  end

  defp visible_entries(assigns, overdue) do
    entries =
      Enum.filter(assigns.schedules, fn entry ->
        matches_filter?(entry, assigns.runs, assigns.views, overdue, assigns.filter) and
          matches_query?(entry, assigns.conversation_titles, assigns.query)
      end)

    Enum.sort_by(entries, &sort_key(&1, assigns.runs, assigns.views, overdue))
  end

  defp matches_filter?(_entry, _runs, _views, _overdue, "all"), do: true
  defp matches_filter?(entry, _runs, _views, _overdue, "active"), do: entry.status == "active"
  defp matches_filter?(entry, _runs, _views, _overdue, "paused"), do: entry.status == "paused"

  defp matches_filter?(entry, _runs, views, _overdue, "ended") do
    entry.status in ["completed", "disabled"] or ended_view?(Map.get(views, entry.id))
  end

  defp matches_filter?(entry, runs, views, overdue, "attention") do
    MapSet.member?(overdue, entry.id) or attention?(runs, entry.id) or
      attention_headline?(headline(views, entry.id))
  end

  defp matches_filter?(_entry, _runs, _views, _overdue, _filter), do: true

  defp ended_view?(nil), do: false
  defp ended_view?(view), do: is_nil(Map.get(view, :action))

  defp matches_query?(_entry, _titles, ""), do: true

  defp matches_query?(entry, titles, query) do
    needle = query |> to_string() |> String.trim() |> String.downcase()

    if needle == "" do
      true
    else
      [
        entry.name,
        entry.instruction,
        Rule.describe(entry.rule),
        Map.get(titles, entry.conversation_id, "")
      ]
      |> Enum.any?(&(String.downcase(to_string(&1 || "")) |> String.contains?(needle)))
    end
  end

  defp filter_counts(schedules, runs, views, overdue) do
    Map.new(@filters, fn {key, _label} ->
      {key, Enum.count(schedules, &matches_filter?(&1, runs, views, overdue, key))}
    end)
  end

  defp sort_key(entry, runs, views, overdue) do
    {rank(entry, runs, views, overdue), next_sort(entry.next_run_at),
     String.downcase(entry.name || "")}
  end

  defp rank(entry, runs, views, overdue) do
    cond do
      MapSet.member?(overdue, entry.id) -> 0
      attention?(runs, entry.id) -> 0
      attention_headline?(headline(views, entry.id)) -> 0
      entry.status in ["active", "running"] -> 1
      entry.status == "paused" -> 2
      true -> 3
    end
  end

  defp next_sort(nil), do: {1, 0}
  defp next_sort(%DateTime{} = at), do: {0, DateTime.to_unix(at)}

  defp headline(views, id) do
    case Map.get(views, id) do
      nil -> nil
      view -> Map.get(view, :headline)
    end
  end

  defp attention_headline?(headline) when is_binary(headline) do
    headline in ["失败", "停滞", "已停止", "结果不明，不会自动重跑"]
  end

  defp attention_headline?(_headline), do: false

  defp overdue_ids(schedules, now) do
    schedules
    |> Enum.filter(&slot_overdue?(&1, now))
    |> MapSet.new(& &1.id)
  end

  defp overdue?(_overdue, nil), do: false
  defp overdue?(overdue, id), do: MapSet.member?(overdue, id)

  # Active but the slot never came: the clock is stalled or the run is stuck.
  defp slot_overdue?(entry, now) do
    entry.status == "active" and match?(%DateTime{}, entry.next_run_at) and
      DateTime.compare(DateTime.add(now, -@overdue_grace_seconds, :second), entry.next_run_at) ==
        :gt
  end

  defp needs_attention?(runs, overdue, id), do: attention?(runs, id) or overdue?(overdue, id)

  defp attention?(runs, id) do
    runs
    |> Map.get(id, [])
    |> Enum.any?(&(to_string(&1.status) in ["failed", "stalled", "halted", "unknown"]))
  end

  defp row_action(entry, view) do
    cond do
      view && view.action -> view.action
      entry.status == "active" -> :pause
      entry.status == "paused" -> :resume
      true -> nil
    end
  end

  # A recurring task keeps "active" after a bad run, so the last run status is
  # what tells the reader something needs attention.
  defp row_status(entry, view, runs, overdue?) do
    cond do
      entry.status in ["paused", "disabled"] -> nil
      is_binary(headline_from(view)) -> headline_from(view)
      status = last_run_status(runs) -> status
      overdue? -> gettext("逾期未运行")
      true -> nil
    end
  end

  defp detail_status(entry, view, runs, overdue?) do
    if entry.status in ["paused", "disabled"],
      do: status_label(entry.status),
      else: row_status(entry, view, runs, overdue?) || status_label(entry.status)
  end

  defp last_run_status([run | _]) when is_binary(run.status) do
    case run.status do
      "completed" -> nil
      "failed" -> gettext("失败")
      "stalled" -> gettext("停滞")
      "halted" -> gettext("已停止")
      "skipped" -> gettext("已跳过")
      "unknown" -> gettext("结果不明")
      "claimed" -> gettext("运行中")
      "started" -> gettext("运行中")
      _other -> nil
    end
  end

  defp last_run_status(_runs), do: nil

  defp dot_class(entry, view, runs, overdue?) do
    cond do
      attention?(runs, entry.id) -> "is-attention"
      attention_headline?(headline_from(view)) -> "is-attention"
      overdue? -> "is-attention"
      entry.status in ["active", "running"] -> "is-active"
      entry.status == "paused" -> "is-paused"
      true -> "is-ended"
    end
  end

  defp headline_from(nil), do: nil
  defp headline_from(view), do: Map.get(view, :headline)

  defp next_label(entry, runs, zone) do
    case entry.next_run_at do
      %DateTime{} = at ->
        Rule.format_local(at, zone || entry.time_zone)

      nil ->
        case last_run(runs) do
          nil ->
            gettext("没有下次")

          run ->
            gettext("没有下次 · 上次 %{at}",
              at: Rule.format_local(run.updated_at, zone || entry.time_zone)
            )
        end
    end
  end

  defp next_date(%{status: "paused"}, _runs, _zone), do: gettext("已暂停")

  defp next_date(entry, runs, zone) do
    case split_stamp(entry, runs, zone) do
      nil -> "—"
      {date, _time} -> date
    end
  end

  defp next_time(%{status: "paused"}, _runs, _zone), do: ""

  defp next_time(entry, runs, zone) do
    case split_stamp(entry, runs, zone) do
      nil -> ""
      {_date, time} -> time
    end
  end

  defp split_stamp(entry, runs, zone) do
    case entry.next_run_at do
      %DateTime{} = at ->
        at |> Rule.format_local(zone || entry.time_zone) |> split_clock()

      _ ->
        case last_run(runs) do
          nil -> nil
          run -> run.updated_at |> Rule.format_local(zone || entry.time_zone) |> split_clock()
        end
    end
  end

  defp split_clock(stamp) do
    case String.split(stamp, " ", parts: 2) do
      [date, time] -> {date, time}
      [date] -> {date, ""}
    end
  end

  defp last_run([run | _]), do: run
  defp last_run([]), do: nil

  defp long_instruction?(entry), do: String.length(entry.instruction || "") > 160

  defp instruction_class(entry, open) do
    ["schedule-instruction", long_instruction?(entry) and not open and "is-clamped"]
  end

  defp conversation_titles(schedules) do
    schedules
    |> Enum.map(& &1.conversation_id)
    |> ConversationStore.titles_for_ids()
  end

  defp conversation_title(entry, titles) do
    case Map.get(titles, entry.conversation_id) do
      title when is_binary(title) and title != "" -> title
      _ -> gettext("对话")
    end
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

  defp status_label("active"), do: gettext("运行中")
  defp status_label("paused"), do: gettext("已暂停")
  defp status_label("completed"), do: gettext("已完成")
  defp status_label("disabled"), do: gettext("已停用")
  defp status_label(status), do: status

  defp run_kind_label("scheduled"), do: gettext("定时")
  defp run_kind_label("manual"), do: gettext("手动")
  defp run_kind_label(kind), do: to_string(kind)

  defp run_status_label("completed"), do: gettext("成功")
  defp run_status_label("failed"), do: gettext("失败")
  defp run_status_label("stalled"), do: gettext("停滞")
  defp run_status_label("halted"), do: gettext("已停止")
  defp run_status_label("skipped"), do: gettext("已跳过")
  defp run_status_label("unknown"), do: gettext("结果不明")
  defp run_status_label("claimed"), do: gettext("已领取")
  defp run_status_label("started"), do: gettext("运行中")
  defp run_status_label(status), do: to_string(status)

  defp run_label(run, zone) do
    if run.slot_at, do: Rule.format_local(run.slot_at, zone), else: gettext("立即运行")
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
