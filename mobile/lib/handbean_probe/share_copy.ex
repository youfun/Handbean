defmodule HandbeanProbe.ShareCopy do
  @moduledoc """
  Supervised workspace-copy and dest-rollback jobs. One job per intake id.
  Rollback is a persisted phase; review is restored only after a successful
  rollback. Success waits for an explicit projection ack.
  """

  use GenServer

  alias HandbeanProbe.{ShareIntake, ShareWorkspaceImport}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def ensure_started do
    case Process.whereis(__MODULE__) do
      nil ->
        spec = {__MODULE__, []}

        case Process.whereis(Handbean.Supervisor) do
          nil ->
            case start_link([]) do
              {:ok, _} -> :ok
              {:error, {:already_started, _}} -> :ok
              {:error, reason} -> {:error, reason}
            end

          _pid ->
            case Supervisor.start_child(Handbean.Supervisor, spec) do
              {:ok, _} -> :ok
              {:ok, _, _} -> :ok
              {:error, {:already_started, _}} -> :ok
              {:error, :already_present} -> :ok
              {:error, {:already_present, _}} -> :ok
              {:error, reason} -> {:error, reason}
            end
        end

      _pid ->
        :ok
    end
  end

  def begin(intake_id, rec, workspace, owner, opts \\ [])
      when is_binary(intake_id) and is_map(rec) and is_map(workspace) do
    case ensure_started() do
      :ok -> GenServer.call(__MODULE__, {:begin, intake_id, rec, workspace, owner, opts})
      other -> other
    end
  end

  def request_rollback(intake_id, workspace, opts \\ [])
      when is_binary(intake_id) and is_map(workspace) do
    case ensure_started() do
      :ok -> GenServer.call(__MODULE__, {:rollback, intake_id, workspace, opts})
      other -> other
    end
  end

  def ack(intake_id) when is_binary(intake_id) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.call(pid, {:ack, intake_id})
    end
  end

  def reconcile(opts \\ []) do
    case Process.whereis(__MODULE__) do
      nil ->
        ShareIntake.list_copy_unresolved()
        |> Enum.each(&enroll_orphan_standalone(&1, opts))

        :ok

      pid ->
        GenServer.call(pid, {:reconcile, opts})
    end
  end

  @impl true
  def init(_opts), do: {:ok, %{jobs: %{}}}

  @impl true
  def handle_call({:begin, id, rec, workspace, owner, opts}, _from, state) do
    cond do
      Map.has_key?(state.jobs, id) ->
        {:reply, {:error, :busy}, state}

      ShareIntake.busy?(id) ->
        {:reply, {:error, :busy}, state}

      true ->
        target = %{
          "intake_id" => id,
          "workspace_id" => workspace["id"],
          "workspace_path" => workspace["path"],
          "conversation_id" => Keyword.get(opts, :conversation_id)
        }

        case ShareIntake.mark_copy_running(id, target) do
          :ok -> start_copy_job(state, id, rec, workspace, owner, target, opts)
          other -> {:reply, other, state}
        end
    end
  end

  def handle_call({:rollback, id, workspace, opts}, _from, state) do
    {reply, state} = enroll_rollback(state, id, workspace, opts)
    {:reply, reply, state}
  end

  def handle_call({:ack, id}, _from, state) do
    case state.jobs[id] do
      %{phase: :awaiting_ack} = job ->
        flush_monitor(job.owner_ref)
        flush_monitor(job.task_ref)
        {:reply, :ok, %{state | jobs: Map.delete(state.jobs, id)}}

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:reconcile, opts}, _from, state) do
    {_, state} =
      Enum.reduce(orphans(state, opts), {nil, state}, fn rec, {_, acc} ->
        workspace = %{"id" => rec["workspace_id"], "path" => rec["workspace_path"]}
        enroll_rollback(acc, rec["intake_id"], workspace, opts)
      end)

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:share_copy_done, id, result}, state) do
    case state.jobs[id] do
      %{phase: :copy} = job ->
        _ = ShareIntake.mark_copy_outcome(id, result)
        job = %{job | done: true}
        flush_monitor(job.task_ref)
        {:noreply, finish_copy(state, id, %{job | task_ref: nil}, result)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:share_rollback_done, id, result}, state) do
    case state.jobs[id] do
      %{phase: :rollback} = job ->
        flush_monitor(job.task_ref)
        _ = finish_rollback(id, job, result)
        {:noreply, %{state | jobs: Map.delete(state.jobs, id)}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    cond do
      job = find_job(state, :task_ref, ref) ->
        {id, job} = job

        cond do
          job.phase == :copy and not job.done ->
            result = {:error, {:worker_down, reason}}
            _ = ShareIntake.mark_copy_outcome(id, result)
            {:noreply, finish_copy(state, id, %{job | done: true, task_ref: nil}, result)}

          job.phase == :rollback and not job.done ->
            _ = ShareIntake.mark_rollback_failed(id)
            notify(job, {:share_rollback, id, {:error, {:worker_down, reason}}})
            {:noreply, %{state | jobs: Map.delete(state.jobs, id)}}

          true ->
            {:noreply, state}
        end

      job = find_job(state, :owner_ref, ref) ->
        {id, job} = job

        cond do
          job.phase == :awaiting_ack ->
            {_, state} = enroll_rollback(state, id, job.workspace, notify: job.notify)
            {:noreply, state}

          job.phase == :copy ->
            {:noreply, put_in(state.jobs[id].owner_alive, false)}

          true ->
            {:noreply, state}
        end

      true ->
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp start_copy_job(state, id, rec, workspace, owner, target, opts) do
    watcher = self()
    copy = Keyword.get(opts, :copy, &ShareWorkspaceImport.accept/2)
    supervisor = Keyword.get(opts, :supervisor, HandbeanProbe.TaskSupervisor)

    case Task.Supervisor.start_child(supervisor, fn ->
           result = copy.(rec, workspace)
           send(watcher, {:share_copy_done, id, result})
         end) do
      {:ok, task} ->
        job = %{
          phase: :copy,
          task: task,
          task_ref: Process.monitor(task),
          owner: owner,
          owner_ref: if(is_pid(owner), do: Process.monitor(owner)),
          owner_alive: is_pid(owner) and Process.alive?(owner),
          target: target,
          notify: Keyword.get(opts, :notify, owner),
          workspace: workspace,
          rollback: Keyword.get(opts, :rollback),
          dest_only: false,
          rollback_after: false,
          done: false
        }

        {:reply, {:ok, task}, put_in(state.jobs[id], job)}

      {:error, reason} ->
        _ = ShareIntake.return_to_review(id)
        {:reply, {:error, reason}, state}
    end
  end

  defp finish_copy(state, id, job, result) do
    state = put_in(state.jobs[id], job)
    payload = %{intake_id: id, target: job.target, result: result}
    owner_alive? = is_pid(job.owner) and Process.alive?(job.owner)
    crashed? = match?({:error, {:worker_down, _}}, result)

    cond do
      crashed? or not owner_alive? or job[:rollback_after] or ShareIntake.terminal?(id) ->
        if not owner_alive? and not crashed? do
          notify(job, {:share_copy_abandoned, payload, :owner_down})
        end

        if crashed? do
          notify(job, {:share_workspace_result, payload})
        end

        {_, state} =
          enroll_rollback(state, id, job.workspace, notify: job.notify, rollback: job.rollback)

        state

      true ->
        _ = ShareIntake.mark_awaiting_ack(id)
        notify(job, {:share_workspace_result, payload})
        put_in(state.jobs[id], %{job | phase: :awaiting_ack})
    end
  end

  defp enroll_rollback(state, id, workspace, opts) do
    cond do
      match?(%{phase: :rollback}, state.jobs[id]) ->
        {{:ok, :already}, state}

      match?(%{phase: :copy, done: false}, state.jobs[id]) ->
        {{:ok, :pending}, put_in(state.jobs[id].rollback_after, true)}

      true ->
        prev = state.jobs[id]
        if prev, do: flush_monitor(prev.owner_ref)
        if prev, do: flush_monitor(prev.task_ref)

        dest_only? = ShareIntake.terminal?(id)

        case maybe_mark_rolling_back(id, dest_only?) do
          :ok ->
            start_rollback_job(state, id, workspace, opts, dest_only?, prev)

          {:error, :terminal} ->
            start_rollback_job(state, id, workspace, opts, true, prev)

          other ->
            {other, %{state | jobs: Map.delete(state.jobs, id)}}
        end
    end
  end

  defp maybe_mark_rolling_back(_id, true), do: :ok
  defp maybe_mark_rolling_back(id, false), do: ShareIntake.mark_rolling_back(id)

  defp start_rollback_job(state, id, workspace, opts, dest_only?, prev) do
    watcher = self()

    rollback =
      Keyword.get(opts, :rollback) || (prev && prev[:rollback]) ||
        (&ShareWorkspaceImport.rollback/2)

    supervisor = Keyword.get(opts, :supervisor, HandbeanProbe.TaskSupervisor)
    notify = Keyword.get(opts, :notify) || (prev && prev.notify)

    job = %{
      phase: :rollback,
      task: nil,
      task_ref: nil,
      owner: prev && prev.owner,
      owner_ref: nil,
      owner_alive: false,
      target: (prev && prev.target) || %{"workspace_path" => workspace["path"]},
      notify: notify,
      workspace: workspace,
      rollback: rollback,
      dest_only: dest_only?,
      done: false
    }

    state = put_in(state.jobs[id], job)

    case Task.Supervisor.start_child(supervisor, fn ->
           result = rollback.(workspace, id)
           send(watcher, {:share_rollback_done, id, result})
         end) do
      {:ok, task} ->
        case state.jobs[id] do
          %{phase: :rollback} = current ->
            {{:ok, task},
             put_in(state.jobs[id], %{current | task: task, task_ref: Process.monitor(task)})}

          _ ->
            {{:ok, task}, state}
        end

      {:error, reason} ->
        unless dest_only?, do: _ = ShareIntake.mark_rollback_failed(id)
        {{:error, reason}, %{state | jobs: Map.delete(state.jobs, id)}}
    end
  end

  defp finish_rollback(id, job, result) do
    case result do
      :ok ->
        unless job.dest_only, do: _ = ShareIntake.return_to_review(id)
        notify(job, {:share_rollback, id, :ok})
        :ok

      {:error, reason} ->
        unless job.dest_only, do: _ = ShareIntake.mark_rollback_failed(id)
        notify(job, {:share_rollback, id, {:error, reason}})
        {:error, reason}
    end
  end

  defp orphans(state, opts) do
    force? = Keyword.get(opts, :abandon_all, false)
    live = Map.keys(state.jobs)

    ShareIntake.list_copy_unresolved()
    |> Enum.reject(fn rec -> rec["intake_id"] in live end)
    |> Enum.filter(fn rec ->
      force? or rec["state"] == "rolling_back" or
        rec["copy_status"] in [nil, "running", "rollback_failed"]
    end)
  end

  defp enroll_orphan_standalone(rec, opts) do
    id = rec["intake_id"]
    workspace = %{"id" => rec["workspace_id"], "path" => rec["workspace_path"]}

    unless ShareIntake.terminal?(id) do
      _ = ShareIntake.mark_rolling_back(id)
    end

    _ = ShareWorkspaceImport.schedule_rollback(workspace, id, opts)
  end

  defp notify(job, message) do
    if is_pid(job.notify) and Process.alive?(job.notify) do
      send(job.notify, message)
    end
  end

  defp flush_monitor(nil), do: :ok
  defp flush_monitor(ref), do: Process.demonitor(ref, [:flush])

  defp find_job(state, key, ref) do
    Enum.find(state.jobs, fn {_id, job} -> job[key] == ref end)
  end
end
