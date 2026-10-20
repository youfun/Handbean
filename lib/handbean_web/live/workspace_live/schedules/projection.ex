defmodule HandbeanWeb.WorkspaceLive.Schedules.Projection do
  @moduledoc false

  use Gettext, backend: Handbean.Gettext

  alias Handbean.Schedule.Rule

  @overdue_grace_seconds 120

  @filters [
    {"all", "全部"},
    {"active", "已启用"},
    {"paused", "已暂停"},
    {"ended", "已结束"},
    {"attention", "需处理"}
  ]

  def filters, do: @filters

  def normalize_filter(filter) when is_binary(filter) do
    if Enum.any?(@filters, fn {key, _label} -> key == filter end), do: filter, else: "all"
  end

  def normalize_filter(_filter), do: "all"

  # Filter options and counts are derived, never stored: one owner for the list.
  def selected_entry(_visible, nil), do: nil
  def selected_entry(visible, :auto), do: List.first(visible)

  def selected_entry(visible, id) do
    Enum.find(visible, &(&1.id == id)) || List.first(visible)
  end

  def visible_entries(assigns, overdue) do
    entries =
      Enum.filter(assigns.schedules, fn entry ->
        matches_filter?(entry, assigns.runs, assigns.views, overdue, assigns.filter) and
          matches_query?(entry, assigns.conversation_titles, assigns.query)
      end)

    Enum.sort_by(entries, &sort_key(&1, assigns.runs, assigns.views, overdue))
  end

  def filter_counts(schedules, runs, views, overdue) do
    Map.new(@filters, fn {key, _label} ->
      {key, Enum.count(schedules, &matches_filter?(&1, runs, views, overdue, key))}
    end)
  end

  def overdue_ids(schedules, now) do
    schedules
    |> Enum.filter(&slot_overdue?(&1, now))
    |> MapSet.new(& &1.id)
  end

  def overdue?(_overdue, nil), do: false
  def overdue?(overdue, id), do: MapSet.member?(overdue, id)

  def needs_attention?(runs, overdue, id), do: attention?(runs, id) or overdue?(overdue, id)

  def row_action(entry, view) do
    cond do
      view && view.action -> view.action
      entry.status == "active" -> :pause
      entry.status == "paused" -> :resume
      true -> nil
    end
  end

  # A recurring task keeps "active" after a bad run, so the last run status is
  # what tells the reader something needs attention.
  def row_status(entry, view, runs, overdue?) do
    cond do
      entry.status in ["paused", "disabled"] -> nil
      is_binary(headline_from(view)) -> headline_from(view)
      status = last_run_status(runs) -> status
      overdue? -> gettext("逾期未运行")
      true -> nil
    end
  end

  def detail_status(entry, view, runs, overdue?) do
    if entry.status in ["paused", "disabled"],
      do: status_label(entry.status),
      else: row_status(entry, view, runs, overdue?) || status_label(entry.status)
  end

  def dot_class(entry, view, runs, overdue?) do
    cond do
      attention?(runs, entry.id) -> "is-attention"
      attention_headline?(headline_from(view)) -> "is-attention"
      overdue? -> "is-attention"
      entry.status in ["active", "running"] -> "is-active"
      entry.status == "paused" -> "is-paused"
      true -> "is-ended"
    end
  end

  def next_label(entry, runs, zone) do
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

  def next_date(%{status: "paused"}, _runs, _zone), do: gettext("已暂停")

  def next_date(entry, runs, zone) do
    case split_stamp(entry, runs, zone) do
      nil -> "—"
      {date, _time} -> date
    end
  end

  def next_time(%{status: "paused"}, _runs, _zone), do: ""

  def next_time(entry, runs, zone) do
    case split_stamp(entry, runs, zone) do
      nil -> ""
      {_date, time} -> time
    end
  end

  def long_instruction?(entry), do: String.length(entry.instruction || "") > 160

  def instruction_class(entry, open) do
    ["schedule-instruction", long_instruction?(entry) and not open and "is-clamped"]
  end

  def conversation_title(entry, titles) do
    case Map.get(titles, entry.conversation_id) do
      title when is_binary(title) and title != "" -> title
      _ -> gettext("对话")
    end
  end

  def run_kind_label("scheduled"), do: gettext("定时")
  def run_kind_label("manual"), do: gettext("手动")
  def run_kind_label(kind), do: to_string(kind)

  def run_status_label("completed"), do: gettext("成功")
  def run_status_label("failed"), do: gettext("失败")
  def run_status_label("stalled"), do: gettext("停滞")
  def run_status_label("halted"), do: gettext("已停止")
  def run_status_label("skipped"), do: gettext("已跳过")
  def run_status_label("unknown"), do: gettext("结果不明")
  def run_status_label("claimed"), do: gettext("已领取")
  def run_status_label("started"), do: gettext("运行中")
  def run_status_label(status), do: to_string(status)

  def run_label(run, zone) do
    if run.slot_at, do: Rule.format_local(run.slot_at, zone), else: gettext("立即运行")
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

  # Active but the slot never came: the clock is stalled or the run is stuck.
  defp slot_overdue?(entry, now) do
    entry.status == "active" and match?(%DateTime{}, entry.next_run_at) and
      DateTime.compare(DateTime.add(now, -@overdue_grace_seconds, :second), entry.next_run_at) ==
        :gt
  end

  defp attention?(runs, id) do
    runs
    |> Map.get(id, [])
    |> Enum.any?(&(to_string(&1.status) in ["failed", "stalled", "halted", "unknown"]))
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

  defp headline_from(nil), do: nil
  defp headline_from(view), do: Map.get(view, :headline)

  defp status_label("active"), do: gettext("运行中")
  defp status_label("paused"), do: gettext("已暂停")
  defp status_label("completed"), do: gettext("已完成")
  defp status_label("disabled"), do: gettext("已停用")
  defp status_label(status), do: status

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
end
