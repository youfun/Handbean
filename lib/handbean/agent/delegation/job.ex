defmodule Handbean.Agent.Delegation.Job do
  @moduledoc false

  alias Handbean.Agent.{Coordinator, Subagent.Worktree}

  def open(id, profile, mode, budget, context, from, table, owner, now) do
    run_id = Ecto.UUID.generate()
    :ets.insert(table, {id, run_id})
    sync? = mode == :sync

    reply_timer =
      if sync? do
        Process.send_after(
          owner,
          {:reply_deadline, id, run_id},
          budget + div(context.tool_timeout, 4)
        )
      end

    %{
      id: id,
      run_id: run_id,
      parent_id: context.conversation_id,
      parent_run_id: context[:run_id],
      workspace: context[:working_directory],
      tool_call_id: context[:tool_call_id],
      profile: profile,
      mode: mode,
      kind: :initial,
      forward?: false,
      from: if(sync?, do: from),
      reply_to: nil,
      parent_ref: if(sync?, do: Process.monitor(context.runner_pid)),
      caller_ref: if(sync?, do: Process.monitor(elem(from, 0))),
      parent_context: if(sync?, do: Map.take(context, [:conversation_id, :run_id, :runner_pid])),
      budget: budget,
      deadline_at: now + budget,
      remaining_ms: budget,
      timer: Process.send_after(owner, {:deadline, id, run_id}, budget),
      reply_timer: reply_timer,
      approval_timer: nil,
      runner: nil,
      runner_ref: nil,
      task: nil,
      starter_ref: nil,
      cleanup_ref: nil,
      text: "",
      truncated?: false,
      usage: %{},
      turn: nil,
      current_tool: nil,
      last_progress_at: 0,
      started?: false,
      cleaned?: false,
      status: :running,
      error: nil,
      diff: nil
    }
  end

  def run_opts(job, owner) do
    id = job.id
    run_id = job.run_id

    [
      run_id: run_id,
      delegation_owner: owner,
      on_event: fn event -> send(owner, {:child_event, id, run_id, event}) end
    ]
  end

  def put(state, job), do: %{state | jobs: Map.put(state.jobs, job.id, job)}

  def remove(state, id, table) do
    :ets.delete(table, id)
    %{state | jobs: Map.delete(state.jobs, id)}
  end

  def finish_removed(state, jobs, table) do
    Enum.each(Map.keys(state.jobs) -- Map.keys(jobs), &:ets.delete(table, &1))
    %{state | jobs: jobs}
  end

  def put_session(state, session, session_limit) do
    sessions = Map.put(state.sessions, session.id, session)

    sessions =
      if map_size(sessions) > session_limit do
        {oldest, _} =
          sessions
          |> Enum.reject(fn {id, _} -> Map.has_key?(state.jobs, id) or id == session.id end)
          |> Enum.min_by(fn {_, stored} -> stored.seq end, fn -> {nil, nil} end)

        Map.delete(sessions, oldest)
      else
        sessions
      end

    %{state | sessions: sessions}
  end

  def owned_session(state, parent_id, ref) when is_binary(ref) do
    owned = state.sessions |> Map.values() |> Enum.filter(&(&1.parent_id == parent_id))

    case Enum.find(owned, &(&1.id == ref)) do
      nil ->
        owned
        |> Enum.filter(&(&1.profile.name == ref))
        |> Enum.max_by(& &1.seq, fn -> nil end)
        |> case do
          nil -> {:error, "No subagent #{inspect(ref)} in this conversation"}
          session -> {:ok, session}
        end

      session ->
        {:ok, session}
    end
  end

  def owned_session(_state, _parent_id, _ref),
    do: {:error, "child_conversation_id is required"}

  def messageable(%{child_opts: nil}), do: {:error, "Subagent never started"}

  def messageable(%{worktree_status: status}) when status != nil,
    do: {:error, "Subagent worktree was #{status}; start a new subagent"}

  def messageable(_session), do: :ok

  def cleanup(job, owner) do
    worktree = job.profile.isolation == :worktree

    {:ok, pid} =
      Task.Supervisor.start_child(Handbean.AgentRunTaskSupervisor, fn ->
        Coordinator.cancel(job.id)

        case Handbean.AgentRunSupervisor.stop_run(job.id) do
          :ok -> :ok
          {:error, :not_found} -> :ok
          other -> exit({:cleanup_unconfirmed, other})
        end

        if job.task do
          ref = Process.monitor(job.task)
          Process.exit(job.task, :kill)

          receive do
            {:DOWN, ^ref, :process, _, _} -> :ok
          end
        end

        diff =
          if worktree do
            case Worktree.diff(job.workspace, job.id) do
              {:ok, info} -> Map.delete(info, :patch)
              {:error, _} -> nil
            end
          end

        # DynamicSupervisor termination is synchronous: all child processes stopped.
        send(owner, {:cleaned, job.id, job.run_id, diff})
      end)

    %{job | cleanup_ref: Process.monitor(pid)}
  end
end
