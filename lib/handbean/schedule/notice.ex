defmodule Handbean.Schedule.Notice do
  @moduledoc """
  Writes schedule outcomes into the conversation transcript.

  IDs are stable, so a replay does not append a second copy.
  """

  alias Handbean.ConversationTranscriptStore
  alias Handbean.Schedule.Rule

  @topic "runtime:schedules"

  @spec skip(map(), map(), String.t()) :: :ok
  def skip(schedule, run, reason) do
    write(
      schedule.conversation_id,
      "msg-sched-skip-#{run.id}",
      "定时任务「#{schedule.name}」本次（#{when_label(schedule, run)}）已跳过：#{reason_text(reason)}"
    )
  end

  @spec catch_up(map(), map(), non_neg_integer(), DateTime.t() | nil, DateTime.t() | nil) :: :ok
  def catch_up(schedule, run, missed, from, to) when missed > 0 do
    write(
      schedule.conversation_id,
      "msg-sched-catchup-#{run.id}",
      "错过 #{missed} 次（从 #{stamp(from, schedule.time_zone)} 到 #{stamp(to, schedule.time_zone)}），只补跑最近一次"
    )
  end

  def catch_up(_schedule, _run, _missed, _from, _to), do: :ok

  @spec unknown(map(), map()) :: :ok
  def unknown(schedule, run) do
    write(
      schedule.conversation_id,
      "msg-sched-unknown-#{run.id}",
      "定时任务「#{schedule.name}」本次（#{when_label(schedule, run)}）结果不明，不会自动重跑"
    )
  end

  defp write(conversation_id, id, text) do
    entry = %{
      "id" => id,
      "conversation_id" => conversation_id,
      "content_type" => "system_msg",
      "message_type" => "system",
      "role" => "system",
      "direction" => "outbound",
      "content" => text,
      "status" => "final",
      "source" => "schedule"
    }

    case ConversationTranscriptStore.list(conversation_id) do
      {:ok, entries} ->
        if Enum.any?(entries, &(&1["id"] == id)) do
          :ok
        else
          persist(conversation_id, entry)
        end

      _ ->
        persist(conversation_id, entry)
    end
  end

  defp persist(conversation_id, entry) do
    case ConversationTranscriptStore.append(conversation_id, entry) do
      {:ok, saved} ->
        Phoenix.PubSub.broadcast(
          Handbean.PubSub,
          @topic,
          {:schedule_notice, conversation_id, saved}
        )

        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp when_label(schedule, %{slot_at: %DateTime{} = slot}),
    do: stamp(slot, schedule.time_zone)

  defp when_label(_schedule, _run), do: "立即运行"

  defp stamp(%DateTime{} = dt, zone), do: Rule.format_local(dt, zone)
  defp stamp(_, _), do: "未知时间"

  defp reason_text("busy"), do: "对话正忙"
  defp reason_text("model_not_allowed"), do: "没有可用的已保存模型"
  defp reason_text("conversation_unavailable"), do: "对话不可用"
  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason), do: inspect(reason)
end
