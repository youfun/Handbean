defmodule HandbeanWeb.WorkspaceLive.Schedules do
  @moduledoc false

  use HandbeanWeb, :html

  alias Handbean.Schedule.{Presentation, Rule, Store}
  alias Phoenix.LiveView.JS

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
    |> Phoenix.Component.assign(:schedules, [])
    |> Phoenix.Component.assign(:schedule_runs, %{})
  end

  def toggle(socket) do
    show = not socket.assigns.show_schedules

    socket
    |> Phoenix.Component.assign(:show_schedules, show)
    |> Phoenix.Component.assign(:schedule_error, nil)
    |> reload()
  end

  def reload(socket) do
    id = socket.assigns.current_conversation_id

    if socket.assigns.chat_scope == :workspace and is_binary(id) do
      schedules = Store.list_for_conversation(id)

      runs =
        Map.new(schedules, fn entry ->
          {entry.id, Store.recent_runs(entry.id, 20)}
        end)

      socket
      |> Phoenix.Component.assign(:schedules, schedules)
      |> Phoenix.Component.assign(:schedule_runs, runs)
    else
      socket
      |> Phoenix.Component.assign(:schedules, [])
      |> Phoenix.Component.assign(:schedule_runs, %{})
    end
  end

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

  attr :chat_scope, :any, required: true
  attr :schedules, :list, required: true
  attr :runs, :map, required: true
  attr :request, :string, default: ""
  attr :error, :any, default: nil
  attr :time_zone, :any, default: nil
  attr :workspace_label, :string, required: true

  def center(assigns) do
    ~H"""
    <section :if={@chat_scope == :workspace} id="schedule-center" class="schedule-center">
      <header class="schedule-center-header">
        <div class="schedule-center-heading">
          <span class="schedule-center-icon" aria-hidden="true">
            <.clock_icon />
          </span>
          <div>
            <h1>{gettext("定时任务")}</h1>
            <p>{gettext("管理当前对话的自动运行")} · {@workspace_label}</p>
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

      <div class="schedule-center-body">
        <form
          id="schedule-ask"
          phx-submit="schedule_ask"
          phx-change="schedule_request"
          class="schedule-create-card"
        >
          <div>
            <h2>{gettext("新建任务")}</h2>
            <p>{gettext("用一句话说明何时运行、要做什么。后续修改时间、频率或语言，也可以直接说。")}</p>
          </div>
          <textarea
            id="schedule-request"
            name="request"
            rows="3"
            value={@request}
            placeholder={gettext("工作日每天 09:00，把项目摘要发到这个聊天")}
          ></textarea>
          <p :if={@error} class="schedule-error" role="alert">{@error}</p>
          <div class="schedule-create-actions">
            <span>{gettext("任务会在当前对话中运行并返回结果")}</span>
            <button type="submit" class="schedule-primary-button">
              {gettext("交给 Agent")}
            </button>
          </div>
        </form>

        <div class="schedule-list-heading">
          <div>
            <h2>{gettext("任务")}</h2>
            <p>{ngettext("当前对话有 1 个任务", "当前对话有 %{count} 个任务", length(@schedules))}</p>
          </div>
        </div>

        <div :if={@schedules == []} id="schedule-empty" class="schedule-empty">
          <span aria-hidden="true"><.clock_icon /></span>
          <h3>{gettext("还没有定时任务")}</h3>
          <p>{gettext("在上方描述一个任务，Agent 会确认时间和执行内容。")}</p>
        </div>

        <div :if={@schedules != []} id="schedule-list" class="schedule-list">
          <article
            :for={entry <- @schedules}
            id={"schedule-#{entry.id}"}
            class="schedule-card"
          >
            <% view = once_view(entry, Map.get(@runs, entry.id, [])) %>
            <div class="schedule-card-main">
              <div class="schedule-card-title-row">
                <h3>{entry.name}</h3>
                <span class={["schedule-status", "is-#{entry.status}"]}>
                  {status_label(entry.status)}
                </span>
              </div>
              <p class="schedule-card-rule">{sidebar_summary(entry, @runs)}</p>
              <p class="schedule-card-next">{sidebar_status(entry, @runs, @time_zone)}</p>
              <p class="schedule-card-instruction">{entry.instruction}</p>
            </div>

            <div class="schedule-card-actions">
              <button
                :if={view && view.action == :pause}
                type="button"
                phx-click="schedule_pause"
                phx-value-id={entry.id}
                class="schedule-secondary-button"
              >
                {gettext("暂停")}
              </button>
              <button
                :if={view && view.action == :resume}
                type="button"
                phx-click="schedule_resume"
                phx-value-id={entry.id}
                class="schedule-secondary-button"
              >
                {gettext("恢复")}
              </button>
              <button
                :if={!view && entry.status == "active"}
                type="button"
                phx-click="schedule_pause"
                phx-value-id={entry.id}
                class="schedule-secondary-button"
              >
                {gettext("暂停")}
              </button>
              <button
                :if={!view && entry.status == "paused"}
                type="button"
                phx-click="schedule_resume"
                phx-value-id={entry.id}
                class="schedule-secondary-button"
              >
                {gettext("恢复")}
              </button>
              <button
                :if={!view}
                type="button"
                phx-click="schedule_run_now"
                phx-value-id={entry.id}
                class="schedule-secondary-button"
              >
                {gettext("立即运行")}
              </button>
              <button
                :if={!view}
                type="button"
                phx-click="schedule_revise"
                phx-value-id={entry.id}
                class="schedule-secondary-button"
              >
                {gettext("修改")}
              </button>
              <button
                type="button"
                phx-click="schedule_delete"
                phx-value-id={entry.id}
                class="schedule-danger-button"
              >
                {gettext("删除")}
              </button>
            </div>

            <details :if={Map.get(@runs, entry.id, []) != []} class="schedule-history">
              <summary>{gettext("运行历史")}</summary>
              <ul>
                <li :for={run <- Map.get(@runs, entry.id, [])}>
                  <span>{run_label(run, entry.time_zone)} · {run.kind} · {run.status}</span>
                  <span :if={run.reason}> · {run.reason}</span>
                  <button
                    :if={run.run_id}
                    type="button"
                    phx-click={
                      JS.dispatch("phx:scroll-to-run",
                        to: "window",
                        detail: %{run_id: run.run_id}
                      )
                    }
                  >
                    {gettext("查看对话")}
                  </button>
                </li>
              </ul>
            </details>
          </article>
        </div>
      </div>
    </section>
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

  defp once_view(entry, runs) do
    Presentation.once(entry, runs, Handbean.Schedule.now())
  end

  defp sidebar_summary(entry, runs) do
    case once_view(entry, Map.get(runs, entry.id, [])) do
      nil -> "#{Rule.describe(entry.rule)} · #{entry.time_zone}"
      view -> Enum.join(view.lines, " · ")
    end
  end

  defp sidebar_status(entry, runs, zone) do
    case once_view(entry, Map.get(runs, entry.id, [])) do
      nil -> "#{gettext("下次")}：#{next_label(entry, zone)} · #{entry.status}"
      view -> view.headline
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

  defp current(socket, id) do
    Store.get_for_conversation(socket.assigns.current_conversation_id, id)
  end

  defp revise_prompt(entry) do
    "把「#{entry.name}」改成："
  end

  defp next_label(%{next_run_at: nil}, _zone), do: "—"

  defp next_label(entry, zone) do
    Rule.format_local(entry.next_run_at, zone || entry.time_zone)
  end

  defp status_label("active"), do: gettext("运行中")
  defp status_label("paused"), do: gettext("已暂停")
  defp status_label("completed"), do: gettext("已完成")
  defp status_label("disabled"), do: gettext("已停用")
  defp status_label(status), do: status

  defp run_label(run, zone) do
    if run.slot_at, do: Rule.format_local(run.slot_at, zone), else: gettext("立即运行")
  end
end
