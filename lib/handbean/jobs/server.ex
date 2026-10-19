defmodule Handbean.Jobs.Server do
  @moduledoc "Application-level job admission, bounded results and backend lifecycle tracking."
  use GenServer

  alias Handbean.Jobs.{Beam, Buffer, Cleaner}
  alias Handbean.Platform.{ProcessManager, ProcessRunner}

  @terminal [:completed, :failed, :cancelled, :timed_out]
  @retention_ms 900_000
  @retained_per_conversation 32
  @retained_globally 256

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    Process.send_after(self(), :prune, 60_000)

    {:ok,
     %{
       scopes: %{},
       jobs: %{},
       waiters: %{},
       cleaner_alive?: true,
       cleaner_monitor: Process.monitor(Process.whereis(Cleaner))
     }}
  end

  @impl true
  def handle_call({:open, _owner, _runner}, _from, %{cleaner_alive?: false} = state) do
    {:reply, {:error, "Cleanup ledger failed; job admission disabled until service restart"},
     state}
  end

  def handle_call({:open, owner, runner}, _from, state) do
    case state.scopes[owner] do
      %{runner: ^runner, open?: true} ->
        {:reply, :ok, state}

      nil when map_size(state.scopes) < 128 ->
        scope = %{runner: runner, monitor: Process.monitor(runner), open?: true}
        {:reply, :ok, put_in(state.scopes[owner], scope)}

      _ ->
        {:reply, {:error, "Run scope closed or capacity exhausted"}, state}
    end
  end

  def handle_call({:close, owner}, _from, state) do
    {:reply, :ok, close_scope(state, owner)}
  end

  def handle_call({:start, owner, call_id, command, cwd, timeout, deadline}, from, state) do
    duplicate =
      Enum.find_value(state.jobs, fn {_id, job} ->
        if job.owner == owner and job.call_id == call_id, do: job
      end)

    cond do
      duplicate != nil ->
        reply_or_wait(state, duplicate, 0, deadline, from, :terminal)

      not match?(%{open?: true}, state.scopes[owner]) ->
        {:reply, {:error, "Run scope is not open"}, state}

      not Process.alive?(state.scopes[owner].runner) ->
        {:reply, {:error, "Run owner has exited"}, close_scope(state, owner)}

      deadline <= now() ->
        {:reply, {:error, "Job admission deadline expired"}, state}

      active_capacity?(state, owner) ->
        {:reply, {:error, "Job capacity exhausted"}, state}

      true ->
        launch(state, owner, call_id, command, cwd, timeout, deadline, from)
    end
  end

  def handle_call({:status, owner, nil, _cursor, _deadline}, _from, state) do
    jobs =
      state.jobs
      |> Map.values()
      |> Enum.filter(&visible?(&1, owner))
      |> Enum.sort_by(&{&1.created_at, Map.get(&1, :sequence, 0)}, :desc)
      |> Enum.take(@retained_per_conversation)
      |> Enum.map(
        &Map.take(snapshot(&1, &1.buffer.total), [
          :job_id,
          :state,
          :cursor,
          :cleanup_error,
          :exit_code,
          :elapsed_ms,
          :output_idle_ms,
          :remaining_ms,
          :timeout_ms,
          :total_output_bytes
        ])
      )

    {:reply, {:ok, %{jobs: jobs, limit: @retained_per_conversation}}, state}
  end

  def handle_call({:status, owner, id, cursor, deadline}, from, state) do
    case authorized_job(state, owner, id) do
      {:ok, job} -> reply_or_wait(state, job, cursor, deadline, from, :activity)
      error -> {:reply, error, state}
    end
  end

  def handle_call({:cancel, owner, id}, _from, state) do
    case authorized_job(state, owner, id) do
      {:ok, job} ->
        state = cancel_job(state, job, :cancelled)
        {:reply, {:ok, snapshot(state.jobs[id], 0)}, state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:beam_output, id, text}, _from, state) do
    case state.jobs[id] do
      %{state: status} = job when status in [:running, :cancelling] and is_binary(text) ->
        job = append_output(job, text)
        state = put_in(state.jobs[id], job)
        {:reply, :ok, notify_output_waiters(state, id)}

      _ ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:beam_finished, id, result}, state) do
    case state.jobs[id] do
      %{beam: _} = job ->
        Process.cancel_timer(job.timer)

        {status, text} =
          case result do
            {:ok, text, _} -> {:completed, text}
            {:ok, text} -> {:completed, text}
            {:error, text, %{timed_out: true}} -> {:timed_out, text}
            {:error, text, %{cancelled: true}} -> {:cancelled, text}
            {:error, text, _} -> {:failed, text}
            {:error, text} -> {:failed, text}
          end

        details =
          case result do
            {_, _, details} when is_map(details) ->
              Map.take(details, [:stdout_truncated?, :return_truncated?, :error_truncated?])

            _ ->
              %{}
          end

        result = Handbean.Utils.Truncate.truncate(text, :head, max_bytes: 50_000)

        job =
          Map.merge(job, %{
            state: job.target || status,
            result: result.content,
            result_truncated: result.truncated,
            result_details: details,
            cleanup_error: nil,
            finished_at: now()
          })

        {:noreply, state |> put_in([:jobs, id], job) |> notify_terminal_waiters(id)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({port, {:data, data}}, state) when is_port(port) do
    case job_for_port(state, port) do
      nil ->
        {:noreply, state}

      job ->
        job = append_output(job, data)
        state = put_in(state.jobs[job.id], job)
        {:noreply, notify_output_waiters(state, job.id)}
    end
  end

  def handle_info({port, {:exit_status, code}}, state) when is_port(port) do
    case job_for_port(state, port) do
      nil ->
        {:noreply, state}

      job ->
        job = %{job | exit_code: code}
        state = put_in(state.jobs[job.id], job)
        target = if code == 0, do: :completed, else: :failed
        {:noreply, cancel_job(state, job, target)}
    end
  end

  def handle_info({:EXIT, port, reason}, state) when is_port(port) do
    case job_for_port(state, port) do
      nil -> {:noreply, state}
      job when reason != :normal -> {:noreply, cancel_job(state, job, :failed)}
      _ -> {:noreply, state}
    end
  end

  def handle_info({:expire, id}, state) do
    case state.jobs[id] do
      nil -> {:noreply, state}
      job -> {:noreply, cancel_job(state, job, :timed_out)}
    end
  end

  def handle_info({:job_cleanup, id, result}, state) do
    case state.jobs[id] do
      nil ->
        {:noreply, state}

      job ->
        job =
          case result do
            :ok ->
              Process.cancel_timer(job.timer)
              close_port(job.port)
              %{job | state: job.target, finished_at: now(), cleanup_error: nil}

            {:error, reason} ->
              %{job | cleanup_error: reason}
          end

        state = put_in(state.jobs[id], job)
        state = if job.state in @terminal, do: notify_terminal_waiters(state, id), else: state
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{cleaner_monitor: ref} = state) do
    # Reciprocal supervision: if the cleanup owner dies, the surviving Port owner
    # closes admission and takes over its registered groups. Never silently resume.
    state = %{state | cleaner_alive?: false}

    state =
      Enum.reduce(state.scopes, state, fn {owner, _scope}, acc -> close_scope(acc, owner) end)

    Enum.each(state.jobs, fn {id, job} ->
      if job.state not in @terminal, do: send(self(), {:fallback_clean, id})
    end)

    {:noreply, state}
  end

  def handle_info({:fallback_clean, id}, state) do
    case state.jobs[id] do
      %{state: :cancelling, beam: pid} ->
        Beam.cancel(pid)

      %{state: :cancelling} = job ->
        result = ProcessManager.cleanup_job_group(job.group)
        send(self(), {:job_cleanup, id, result})
        if result != :ok, do: Process.send_after(self(), {:fallback_clean, id}, 1_000)

      _ ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    state =
      Enum.reduce(state.jobs, state, fn {id, job}, acc ->
        if job[:beam_monitor] == ref and job.state not in @terminal do
          put_in(acc.jobs[id], %{
            job
            | state: :cancelling,
              cleanup_error:
                "BEAM owner exited before cleanup confirmation; execution will not restart"
          })
        else
          acc
        end
      end)

    state =
      Enum.reduce(state.scopes, state, fn {owner, scope}, acc ->
        if scope.monitor == ref do
          acc = close_scope(acc, owner)
          %{acc | scopes: Map.delete(acc.scopes, owner)}
        else
          acc
        end
      end)

    {:noreply, state}
  end

  def handle_info({:wait_done, ref}, state) do
    case Map.pop(state.waiters, ref) do
      {nil, _} ->
        {:noreply, state}

      {{from, id, cursor, _mode, _timer}, waiters} ->
        GenServer.reply(from, {:ok, snapshot(state.jobs[id], cursor)})
        {:noreply, %{state | waiters: waiters}}
    end
  end

  def handle_info(:prune, state) do
    jobs =
      Map.reject(state.jobs, fn {_id, job} ->
        job.state in @terminal and job.finished_at + @retention_ms < now() and
          not match?(%{open?: true}, state.scopes[job.owner])
      end)

    Process.send_after(self(), :prune, 60_000)
    {:noreply, %{state | jobs: jobs}}
  end

  defp launch(state, owner, call_id, {:beam, kind, fun}, _cwd, timeout, deadline, from) do
    id = "job_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

    case DynamicSupervisor.start_child(
           Handbean.Jobs.BeamSupervisor,
           {Beam, [id: id, kind: kind, fun: fun, server: self()]}
         ) do
      {:ok, pid} ->
        job = %{
          id: id,
          owner: owner,
          call_id: call_id,
          beam: pid,
          beam_monitor: Process.monitor(pid),
          buffer: %Buffer{},
          state: :running,
          target: nil,
          exit_code: nil,
          cleanup_error: nil,
          created_at: now(),
          sequence: System.unique_integer([:positive, :monotonic]),
          finished_at: nil,
          timeout_ms: timeout,
          last_output_at: nil,
          timer: Process.send_after(self(), {:expire, id}, timeout)
        }

        state = state |> make_retention_room(owner) |> put_in([:jobs, id], job)

        if now() < deadline and Process.alive?(state.scopes[owner].runner) do
          GenServer.cast(pid, :go)
          reply_or_wait(state, job, 0, deadline, from, :terminal)
        else
          state = cancel_job(state, job, :cancelled)
          {:reply, {:ok, snapshot(state.jobs[id], 0)}, state}
        end

      {:error, _} ->
        {:reply, {:error, "BEAM job owner unavailable"}, state}
    end
  end

  defp launch(state, owner, call_id, command, cwd, timeout, deadline, from) do
    {_, _, workspace} = owner

    case ProcessRunner.open_gated_bash(command, cwd,
           workspace_path: workspace,
           startup_timeout: min(1_000, max(0, deadline - now()))
         ) do
      {:ok, port, group} ->
        id = "job_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

        case Cleaner.register(id, group, self(), deadline - now()) do
          {:ok, identity} ->
            job = %{
              id: id,
              owner: owner,
              call_id: call_id,
              port: port,
              group: identity,
              buffer: %Buffer{},
              state: :running,
              target: nil,
              exit_code: nil,
              cleanup_error: nil,
              created_at: now(),
              sequence: System.unique_integer([:positive, :monotonic]),
              finished_at: nil,
              timeout_ms: timeout,
              last_output_at: nil,
              timer: Process.send_after(self(), {:expire, id}, timeout)
            }

            state = state |> make_retention_room(owner) |> put_in([:jobs, id], job)

            if now() < deadline and Process.alive?(state.scopes[owner].runner) do
              Port.command(port, "go\n")
              reply_or_wait(state, job, 0, deadline, from, :terminal)
            else
              state = cancel_job(state, job, :cancelled)
              {:reply, {:ok, snapshot(state.jobs[id], 0)}, state}
            end

          {:error, reason} ->
            close_port(port)
            Cleaner.cancel(id)
            {:reply, {:error, reason}, state}
        end

      error ->
        {:reply, error, state}
    end
  end

  defp reply_or_wait(state, job, cursor, deadline, from, mode)
       when mode in [:terminal, :activity] do
    remaining = deadline - now()
    result = snapshot(job, cursor)

    if remaining <= 1 or job.state in @terminal or map_size(state.waiters) >= 128 or
         (mode == :activity and result.cursor != cursor) do
      {:reply, {:ok, result}, state}
    else
      ref = make_ref()
      # Leave a small reply margin inside the caller's absolute deadline.
      timer = Process.send_after(self(), {:wait_done, ref}, max(remaining - 10, 0))
      waiter = {from, job.id, cursor, mode, timer}
      {:noreply, put_in(state.waiters[ref], waiter)}
    end
  end

  defp notify_output_waiters(state, id) do
    {ready, pending} =
      Enum.split_with(state.waiters, fn
        {_ref, {_from, ^id, cursor, :activity, _timer}} ->
          output_available?(state.jobs[id], cursor)

        _ ->
          false
      end)

    reply_waiters(%{state | waiters: Map.new(pending)}, ready, id)
  end

  defp notify_terminal_waiters(state, id) do
    {ready, pending} =
      Enum.split_with(state.waiters, fn {_ref, {_from, job_id, _cursor, _mode, _timer}} ->
        job_id == id
      end)

    reply_waiters(%{state | waiters: Map.new(pending)}, ready, id)
  end

  defp reply_waiters(state, waiters, id) do
    Enum.each(waiters, fn {_ref, {from, _job_id, cursor, _mode, timer}} ->
      Process.cancel_timer(timer)
      GenServer.reply(from, {:ok, snapshot(state.jobs[id], cursor)})
    end)

    state
  end

  defp output_available?(job, cursor) do
    Buffer.read(job.buffer, cursor, false).cursor != cursor
  end

  defp append_output(job, data) when byte_size(data) > 0 do
    %{job | buffer: Buffer.append(job.buffer, data), last_output_at: now()}
  end

  defp append_output(job, _data), do: job

  defp close_scope(state, owner) do
    state =
      case state.scopes[owner] do
        nil -> state
        scope -> put_in(state.scopes[owner], %{scope | open?: false})
      end

    Enum.reduce(state.jobs, state, fn {_id, job}, acc ->
      if job.owner == owner, do: cancel_job(acc, job, :cancelled), else: acc
    end)
  end

  defp cancel_job(state, %{state: status}, _target)
       when status in @terminal or status == :cancelling, do: state

  defp cancel_job(state, job, target) do
    if job[:beam], do: Beam.cancel(job.beam), else: Cleaner.cancel(job.id)
    put_in(state.jobs[job.id], %{job | state: :cancelling, target: target})
  end

  defp authorized_job(state, owner, id) do
    job = state.jobs[id]

    if job && visible?(job, owner),
      do: {:ok, job},
      else: {:error, "Job unknown, expired or unavailable to this workspace/conversation"}
  end

  defp visible?(%{owner: {conversation, _run, workspace}}, {conversation, _run2, workspace}),
    do: true

  defp visible?(_, _), do: false

  defp job_for_port(state, port),
    do: Enum.find_value(state.jobs, fn {_id, job} -> if job[:port] == port, do: job end)

  defp snapshot(job, cursor) do
    now_ms = now()
    observed_until = job.finished_at || now_ms

    timing = %{
      elapsed_ms: max(observed_until - job.created_at, 0),
      output_idle_ms: max(observed_until - (job.last_output_at || job.created_at), 0),
      remaining_ms:
        if(job.state in @terminal,
          do: 0,
          else: max(job.created_at + job.timeout_ms - now_ms, 0)
        ),
      timeout_ms: job.timeout_ms,
      total_output_bytes: job.buffer.total
    }

    Buffer.read(job.buffer, cursor, job.state in @terminal)
    |> Map.merge(%{job_id: job.id, state: job.state, cleanup_error: job.cleanup_error})
    |> Map.merge(timing)
    |> Map.merge(Map.take(job, [:result, :result_truncated]))
    |> Map.merge(Map.get(job, :result_details, %{}))
    |> then(fn result ->
      if is_integer(job.exit_code), do: Map.put(result, :exit_code, job.exit_code), else: result
    end)
  end

  defp active_capacity?(state, owner) do
    jobs = Map.values(state.jobs)

    Enum.count(jobs, &(&1.state not in @terminal)) >= 16 or
      Enum.count(jobs, &(&1.owner == owner and &1.state not in @terminal)) >= 4
  end

  defp make_retention_room(state, owner) do
    terminal_order = &{&1.finished_at, Map.get(&1, :sequence, 0)}

    jobs =
      state.jobs
      |> prune_terminal_jobs(
        @retained_per_conversation,
        &visible?(&1, owner),
        terminal_order
      )
      |> prune_terminal_jobs(@retained_globally, fn _job -> true end, fn job ->
        {scope_open?(state, job.owner), terminal_order.(job)}
      end)

    %{state | jobs: jobs}
  end

  defp prune_terminal_jobs(jobs, limit, visible?, order) do
    matching_count = Enum.count(jobs, fn {_id, job} -> visible?.(job) end)
    remove_count = max(matching_count - limit + 1, 0)

    ids =
      jobs
      |> Map.values()
      |> Enum.filter(&(&1.state in @terminal and visible?.(&1)))
      |> Enum.sort_by(order)
      |> Enum.take(remove_count)
      |> Enum.map(& &1.id)

    Map.drop(jobs, ids)
  end

  defp scope_open?(state, owner), do: match?(%{open?: true}, state.scopes[owner])

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp now, do: System.monotonic_time(:millisecond)
end
