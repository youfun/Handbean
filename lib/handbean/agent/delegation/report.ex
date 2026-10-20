defmodule Handbean.Agent.Delegation.Report do
  @moduledoc false

  require Logger

  alias Handbean.Agent.{Coordinator, ErrorReporter}

  def progress(job, tool, now, interval_ms) do
    job = %{job | current_tool: tool}

    if now - job.last_progress_at >= interval_ms do
      Handbean.PubSub.Session.broadcast_event(job.parent_id, :subagent_progress, %{
        tool_use_id: job.tool_call_id,
        child_conversation_id: job.id,
        turn: job.turn,
        current_tool: tool,
        usage: job.usage
      })

      %{job | last_progress_at: now}
    else
      job
    end
  end

  def report(job, status) do
    data = public_details(job, status)
    text = "Delegated report (requires parent review):\n" <> Handbean.JSON.encode!(data)
    if status in [:completed, "completed"], do: {:ok, text, data}, else: {:error, text, data}
  end

  def finished(job) do
    %{
      status: job.status,
      report: job.text,
      report_truncated?: job.truncated?,
      usage: job.usage,
      diff_stat: job.diff && job.diff.stat,
      error: public_error(job.error),
      text: report_text(job)
    }
  end

  def public_details(job, status) do
    %{
      status: status,
      subagent_type: job.profile.name,
      child_conversation_id: job.id,
      child_run_id: job.run_id,
      mode: job.mode,
      usage: job.usage,
      report: job.text,
      report_truncated?: job.truncated?,
      usage_complete?: status in [:completed, "completed"]
    }
    |> put_if(public_error(job.error), :error, & &1)
    |> put_if(job.diff, :diff_stat, & &1.stat)
    |> put_if(job.diff, :worktree_base, & &1.base)
  end

  def public_session(session, job, opts \\ []) do
    base = %{
      child_conversation_id: session.id,
      subagent_type: session.profile.name,
      mode: session.mode,
      status: (job && job.status) || session.status,
      child_run_id: session.run_id,
      runs: session.runs,
      usage: (job && job.usage) || session.usage,
      current_tool: job && job.current_tool,
      worktree: session.worktree,
      worktree_status: session.worktree_status,
      diff_stat: session.diff_stat
    }

    base = put_if(base, (job && public_error(job.error)) || session.error, :error, & &1)

    if Keyword.get(opts, :report, false) do
      Map.merge(base, %{report: session.report, report_truncated?: session.report_truncated?})
    else
      base
    end
  end

  def background_ack(job) do
    "Subagent started in the background. Its report arrives later as a follow-up message; " <>
      "do not assume its findings before then.\n" <>
      Handbean.JSON.encode!(%{
        child_conversation_id: job.id,
        status: :running,
        subagent_type: job.profile.name,
        mode: :background
      })
  end

  def end_payload(job) do
    %{
      tool_use_id: job.tool_call_id,
      child_conversation_id: job.id,
      child_run_id: job.run_id,
      subagent_type: job.profile.name,
      kind: job.kind,
      status: job.status,
      usage: job.usage,
      report: job.text
    }
    |> put_if(public_error(job.error), :error, & &1)
  end

  def child_stopped(job, session, reason) do
    child_opts = (session && session.child_opts) || []

    ErrorReporter.report(
      {:child_stopped, reason},
      %{
        "source" => "delegation",
        "conversation_id" => job.parent_id,
        "run_id" => job.parent_run_id,
        "child_conversation_id" => job.id,
        "child_run_id" => job.run_id,
        "subagent_type" => job.profile.name,
        "subagent_mode" => job.mode,
        "model" => child_opts[:model]
      },
      failure_class: :subagent_stopped,
      provider: child_opts[:provider],
      provider_config: child_opts[:provider_config]
    )
  end

  def startup_failure(job, reason) do
    stage = startup_stage(reason)
    message = public_error(reason)

    Logger.warning(
      "[Delegation] subagent startup failed parent=#{job.parent_id} " <>
        "parent_run=#{job.parent_run_id} child=#{job.id} child_run=#{job.run_id} " <>
        "type=#{job.profile.name} mode=#{job.mode} stage=#{stage}: #{message}"
    )

    ErrorReporter.report(
      startup_reason(reason),
      %{
        "source" => "delegation",
        "conversation_id" => job.parent_id,
        "run_id" => job.parent_run_id,
        "child_conversation_id" => job.id,
        "child_run_id" => job.run_id,
        "subagent_type" => job.profile.name,
        "subagent_mode" => job.mode,
        "startup_stage" => stage
      },
      failure_class: :subagent_startup_failed
    )
  end

  def queue(state, session, text, owner, flush_ms) do
    case state.reports[session.parent_id] do
      nil ->
        Process.send_after(owner, {:flush_reports, session.parent_id}, flush_ms)
        put_in(state.reports[session.parent_id], {session.wake_opts, [text]})

      {wake_opts, texts} ->
        put_in(
          state.reports[session.parent_id],
          {wake_opts || session.wake_opts, texts ++ [text]}
        )
    end
  end

  def deliver(parent_id, {wake_opts, texts}) do
    text = Enum.join(texts, "\n\n")

    if wake_opts do
      opts =
        Keyword.merge(wake_opts,
          deliver_as: :follow_up,
          source: :delegation,
          channel: :internal,
          require_running?: not Application.get_env(:handbean, :subagent_wake_parent, true)
        )

      Task.Supervisor.start_child(Handbean.AgentRunTaskSupervisor, fn ->
        case Coordinator.add_message(parent_id, text, opts) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.info(
              "[Delegation] report not delivered parent=#{parent_id}: #{inspect(reason)}"
            )
        end
      end)
    end

    :ok
  end

  def public_error(nil), do: nil

  def public_error({:startup_failed, stage, reason}) do
    "Subagent failed to start during #{stage}: #{public_error_reason(reason)}"
  end

  def public_error(reason), do: public_error_reason(reason)

  defp report_text(job) do
    data = public_details(job, job.status)

    "Background subagent report for child_conversation_id #{job.id} (requires your review; " <>
      "use task_status to follow up):\n" <> Handbean.JSON.encode!(data)
  end

  defp startup_stage({:startup_failed, stage, _reason}) when is_atom(stage), do: stage
  defp startup_stage(_reason), do: :unknown

  defp startup_reason({:startup_failed, _stage, reason}), do: startup_reason(reason)

  defp startup_reason({exception, stacktrace}) when is_exception(exception),
    do: {exception, stacktrace}

  defp startup_reason({_kind, reason, _stacktrace}), do: reason
  defp startup_reason(reason), do: reason

  defp public_error_reason(reason) do
    case Handbean.Storage.ErrorClassifier.classify(reason) do
      :busy ->
        "Local database was busy"

      category when category in [:full, :ioerr, :corrupt] ->
        "Local storage was unavailable (#{category})"

      _ ->
        reason
        |> render_public_error()
        |> Handbean.Log.Redactor.redact()
        |> String.slice(0, 500)
    end
  end

  defp render_public_error(reason) when is_binary(reason), do: reason
  defp render_public_error(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp render_public_error({exception, _stacktrace}) when is_exception(exception),
    do: Exception.message(exception)

  defp render_public_error({_kind, reason, _stacktrace}), do: render_public_error(reason)
  defp render_public_error(reason), do: inspect(reason, limit: 20, printable_limit: 500)

  defp put_if(map, nil, _key, _fun), do: map
  defp put_if(map, value, key, fun), do: Map.put(map, key, fun.(value))
end
