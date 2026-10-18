defmodule Handbean.Schedule.Dispatch do
  @moduledoc """
  Turns a claimed schedule slot into one idle run, or a visible skip.

  Nothing here retries. A busy conversation, a missing model, or an unknown
  delivery stays that way until the next planned slot.
  """

  alias Handbean.Agent.{Coordinator, Runner, RunOpts}
  alias Handbean.ArtifactDelivery
  alias Handbean.ConversationStore
  alias Handbean.Schedule.{Notice, Rule, Store}
  alias Handbean.WorkspaceStore

  @spec busy?(String.t()) :: boolean()
  def busy?(conversation_id) when is_binary(conversation_id) do
    coordinator_busy?(conversation_id)
  end

  @spec run(map()) :: :ok
  def run(%{schedule: schedule, run: run} = claim) do
    cond do
      not conversation_ok?(schedule) ->
        if run.kind != "manual", do: Store.disable(schedule)
        record_skip(schedule, run, "conversation_unavailable")

      not model_ok?(schedule) ->
        close_skipped(schedule, run, "model_not_allowed")

      busy?(schedule.conversation_id) ->
        on_busy(schedule, run)

      true ->
        maybe_catch_up(claim)
        dispatch(claim)
    end
  end

  defp dispatch(%{schedule: schedule, run: run}) do
    case build_opts(schedule, run) do
      {:ok, content, opts} ->
        case Coordinator.add_message(schedule.conversation_id, content, opts) do
          {:ok, ack} ->
            _ =
              Store.record(run, "started",
                run_id: ack.run_id,
                reason: if(ack[:replayed], do: "replayed")
              )

            :ok

          {:error, :busy} ->
            on_busy(schedule, run)

          {:error, :run_in_progress} ->
            if planned_once?(schedule, run),
              do: close_unknown(schedule, run),
              else: record_skip(schedule, run, "busy")

          {:error, :delivery_unknown} ->
            close_unknown(schedule, run)

          {:error, reason} ->
            close_failed(schedule, run, inspect(reason))
        end

      {:error, :model_not_allowed} ->
        close_skipped(schedule, run, "model_not_allowed")

      {:error, reason} ->
        close_failed(schedule, run, inspect(reason))
    end
  end

  defp build_opts(schedule, run) do
    with :ok <- model_gate(schedule),
         {:ok, workspace_path} <- workspace_path(schedule),
         {:ok, checkout_path} <-
           ConversationStore.effective_checkout_path(schedule.conversation_id),
         {:ok, built} <-
           RunOpts.for_workspace(workspace_path, schedule.model,
             reasoning_level: schedule.reasoning_level
           ) do
      opts =
        built
        |> Keyword.merge(
          tools: schedule_tools(),
          source: :schedule,
          channel: :schedule,
          require_idle?: true,
          request_id: run.request_id,
          workspace_id: schedule.workspace_id,
          workspace_path: workspace_path,
          working_directory: checkout_path,
          streaming: true,
          origin: %{
            "kind" => "automatic",
            "source" => "schedule",
            "schedule_id" => schedule.id,
            "slot_at" => slot_iso(run)
          }
        )

      {:ok, message(schedule, run), opts}
    else
      {:error, "Model " <> _} -> {:error, :model_not_allowed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp message(schedule, run) do
    title =
      case run.slot_at do
        %DateTime{} = slot ->
          "[定时任务「#{schedule.name}」· 计划时间 #{Rule.format_local(slot, schedule.time_zone)} #{schedule.time_zone}]"

        _ ->
          "[定时任务「#{schedule.name}」· 立即运行]"
      end

    title <> "\n" <> schedule.instruction
  end

  defp schedule_tools do
    excluded = MapSet.new(["computer" | ArtifactDelivery.tool_names()])

    Enum.reject(Handbean.Agent.default_tools(), fn module ->
      function_exported?(module, :name, 0) and module.name() in excluded
    end)
  end

  defp conversation_ok?(schedule) do
    case ConversationStore.get_meta(schedule.conversation_id) do
      {:ok, meta} ->
        meta["workspace_id"] == schedule.workspace_id and
          meta["visibility"] != "internal" and
          meta["scope"] != "free" and
          not ConversationStore.archived_conversation?(meta)

      _ ->
        false
    end
  end

  defp model_ok?(schedule) do
    case workspace_path(schedule) do
      {:ok, path} -> Handbean.Agent.ModelConfig.model_allowed_for_workspace?(path, schedule.model)
      _ -> false
    end
  end

  defp model_gate(schedule) do
    if model_ok?(schedule), do: :ok, else: {:error, :model_not_allowed}
  end

  defp workspace_path(schedule) do
    case WorkspaceStore.get(schedule.workspace_id) do
      {:ok, %{"path" => path}} when is_binary(path) and path != "" -> {:ok, path}
      _ -> {:error, :conversation_unavailable}
    end
  end

  defp on_busy(schedule, run) do
    if planned_once?(schedule, run),
      do: release_once(schedule, run),
      else: record_skip(schedule, run, "busy")
  end

  defp release_once(schedule, run) do
    case Store.release_claim(run) do
      {:ok, _entry} -> :ok
      {:error, :not_releasable} -> :ok
      {:error, _reason} -> close_unknown(schedule, run)
    end
  end

  defp close_unknown(schedule, run) do
    if planned_once?(schedule, run) do
      _ = Store.finish_run(run, "unknown", reason: "delivery_unknown")
    else
      _ = Store.record(run, "unknown", reason: "delivery_unknown")
    end

    Notice.unknown(schedule, run)
    :ok
  end

  defp close_failed(schedule, run, reason) do
    if planned_once?(schedule, run) do
      _ = Store.finish_run(run, "failed", reason: reason)
    else
      _ = Store.record(run, "failed", reason: reason)
    end

    :ok
  end

  defp close_skipped(schedule, run, reason) do
    if planned_once?(schedule, run) do
      _ = Store.finish_run(run, "skipped", reason: reason)
      Notice.skip(schedule, run, reason)
      :ok
    else
      record_skip(schedule, run, reason)
    end
  end

  defp coordinator_busy?(conversation_id) do
    case Runner.status(conversation_id) do
      {:ok, status} -> busy_status?(status)
      _ -> false
    end
  end

  defp busy_status?(status) do
    status[:running?] == true or
      status[:status] in [:running, :awaiting_approval, :interrupted] or
      status[:interrupt_type] in [:stall_check, "stall_check"]
  end

  defp record_skip(schedule, run, reason) do
    _ = Store.record(run, "skipped", reason: reason)
    Notice.skip(schedule, run, reason)
    :ok
  end

  defp planned_once?(schedule, run) do
    Rule.once?(schedule.rule) and run.kind == "scheduled" and not is_nil(run.slot_at)
  end

  defp maybe_catch_up(%{missed: missed} = claim) when is_integer(missed) and missed > 0 do
    Notice.catch_up(
      claim.schedule,
      claim.skipped || claim.run,
      missed,
      claim.missed_from,
      claim.missed_to
    )
  end

  defp maybe_catch_up(_claim), do: :ok

  defp slot_iso(%{slot_at: %DateTime{} = slot}), do: DateTime.to_iso8601(slot)
  defp slot_iso(_run), do: nil
end
