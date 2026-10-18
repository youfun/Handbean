defmodule Handbean.Schedule.Presentation do
  @moduledoc false

  alias Handbean.Schedule.{Entry, Rule}

  @spec once(Entry.t(), [map()], DateTime.t()) :: map() | nil
  def once(%Entry{} = entry, runs, %DateTime{} = now) when is_list(runs) do
    run = Enum.find(runs, &planned_run?/1)
    if Rule.once?(entry.rule), do: view(entry, run, now), else: nil
  end

  def once(_entry, _runs, _now), do: nil

  @spec deleted() :: map()
  def deleted do
    %{switch: :off, enabled: false, action: nil, headline: "已删除", lines: ["已删除"]}
  end

  defp view(entry, run, now) do
    at = once_at(entry)
    deadline = busy_deadline(entry)
    future? = not is_nil(at) and DateTime.compare(at, now) == :gt
    due? = not is_nil(entry.next_run_at) and DateTime.compare(entry.next_run_at, now) != :gt

    cond do
      entry.status == "active" and not is_nil(entry.next_run_at) and not due? ->
        armed(entry, at)

      entry.status == "active" and due? and is_nil(run) ->
        waiting(entry, deadline)

      entry.status == "active" and is_nil(entry.next_run_at) and running?(run) ->
        off("运行中", ["没有下次", "运行中"])

      entry.status == "completed" ->
        finished(entry, run)

      entry.status == "paused" and future? ->
        %{
          switch: :off,
          enabled: true,
          action: :resume,
          headline: "已暂停",
          lines: ["已暂停", format_at(at, entry.time_zone)]
        }

      entry.status == "paused" ->
        off("时刻已过，保持暂停", ["时刻已过，保持暂停"])

      entry.status == "disabled" ->
        off("对话不可用", ["对话不可用"])

      true ->
        off(entry.status, [entry.status])
    end
  end

  defp armed(entry, at) do
    due_lines = waiting(entry, busy_deadline(entry)).lines

    %{
      switch: :on,
      enabled: true,
      action: :pause,
      headline: Rule.describe(entry.rule),
      lines: [Rule.describe(entry.rule), "下次还要", format_at(at, entry.time_zone)],
      countdown_at: iso(entry.next_run_at),
      due_lines: due_lines
    }
  end

  defp waiting(entry, deadline) do
    %{
      switch: :on,
      enabled: true,
      action: :pause,
      headline: Rule.describe(entry.rule),
      lines: [
        Rule.describe(entry.rule),
        "对话正忙，空闲后开始",
        "最迟到 #{format_at(deadline, entry.time_zone)}"
      ]
    }
  end

  defp finished(_entry, nil), do: off("已完成", ["没有下次", "已完成"])

  defp finished(entry, run) do
    headline = run_headline(run)
    when_run = format_at(run.updated_at, entry.time_zone)

    lines =
      if run.status == "unknown" do
        ["没有下次", "结果不明，不会自动重跑", when_run]
      else
        ["没有下次", headline, when_run]
      end

    off(headline, lines)
  end

  defp off(headline, lines) do
    %{switch: :off, enabled: false, action: nil, headline: headline, lines: lines}
  end

  defp running?(nil), do: false
  defp running?(run), do: run.status in ["claimed", "started"]

  defp planned_run?(run) do
    Map.get(run, :kind) == "scheduled" and not is_nil(Map.get(run, :slot_at))
  end

  defp run_headline(%{status: "completed"}), do: "已完成"
  defp run_headline(%{status: "failed"}), do: "失败"
  defp run_headline(%{status: "stalled"}), do: "停滞"
  defp run_headline(%{status: "halted"}), do: "已停止"
  defp run_headline(%{status: "cancelled"}), do: "已取消"
  defp run_headline(%{status: "skipped"}), do: "已跳过"
  defp run_headline(%{status: "unknown"}), do: "结果不明，不会自动重跑"
  defp run_headline(%{status: status}), do: to_string(status)

  defp once_at(entry) do
    case Rule.once_at(entry.rule) do
      {:ok, at} -> at
      :error -> nil
    end
  end

  defp busy_deadline(entry) do
    case Rule.busy_deadline(entry.rule) do
      {:ok, at} -> at
      :error -> nil
    end
  end

  defp format_at(nil, _zone), do: ""

  defp format_at(%DateTime{} = dt, zone) when is_binary(zone) and zone != "" do
    Rule.format_local(dt, zone)
  end

  defp format_at(%DateTime{} = dt, _zone), do: Rule.format_local(dt, "Etc/UTC")

  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(_), do: nil
end
