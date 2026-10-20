defmodule Handbean.Agent.Runner do
  @moduledoc """
  GenServer owner for one active agent run.

  Runner owns lifecycle state and delegates the expensive agent loop to the
  run-local task supervisor inside `Handbean.Agent.RunSupervisor`.
  """

  use GenServer

  require Logger

  alias Handbean.Agent.{ErrorReporter, StreamBatch}
  alias Handbean.Agent.Middleware.ToolGuard
  alias Handbean.PubSub.Session

  @default_inactivity_timeout_ms 300_000
  @progress_events [
    :message_delta,
    :thinking_delta,
    :provider_items,
    :provider_retry,
    :tool_start,
    :tool_end,
    :turn_start,
    :turn_end,
    :candidate_message_injected,
    :tool_approval_requested,
    :stall_check_requested
  ]

  defstruct [
    :conversation_id,
    :content,
    :opts,
    :queue_pid,
    :task,
    :status,
    :error,
    :result,
    :interrupted_state,
    :delegation_monitor,
    :started_at,
    :deadline,
    :deadline_timer,
    :stream_batch,
    stream_started?: false,
    os_processes: []
  ]

  def start_link(opts) do
    conversation_id = Keyword.fetch!(opts, :conversation_id)

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {Handbean.AgentRunRegistry, conversation_id}}
    )
  end

  def start_run(conversation_id, content, opts) do
    Handbean.AgentRunSupervisor.start_run(conversation_id, content, opts)
  end

  def status(conversation_id) do
    call_runner(conversation_id, :status)
  end

  @doc "Nonblocking identity check for owners monitoring a run scope."
  def active?(conversation_id, run_id, pid) do
    case Registry.lookup(Handbean.AgentRunRegistry, conversation_id) do
      [{^pid, %{run_id: ^run_id, active?: true}}] -> Process.alive?(pid)
      _ -> false
    end
  end

  @doc false
  def owns_run_task?(conversation_id, run_id, runner_pid, reader_pid)
      when is_binary(conversation_id) and is_binary(run_id) and is_pid(runner_pid) and
             is_pid(reader_pid) do
    case Registry.lookup(Handbean.AgentRunRegistry, conversation_id) do
      [{^runner_pid, %{run_id: ^run_id, active?: true}}] ->
        GenServer.call(runner_pid, {:owns_run_task?, reader_pid, run_id})

      _ ->
        false
    end
  catch
    :exit, _reason -> false
  end

  def owns_run_task?(_conversation_id, _run_id, _runner_pid, _reader_pid), do: false

  def cancel(conversation_id, expected_run_id \\ nil) do
    call_runner(conversation_id, {:cancel, expected_run_id})
  end

  def resume(conversation_id, decisions, expected_run_id \\ nil, expected_batch_id \\ nil) do
    call_runner(conversation_id, {:resume, decisions, expected_run_id, expected_batch_id})
  end

  def enqueue(conversation_id, content, opts \\ []) do
    call_runner(conversation_id, {:enqueue, content, opts})
  end

  @impl true
  def init(opts) do
    conversation_id = Keyword.fetch!(opts, :conversation_id)
    queue_pid = resolve_queue_pid!(Keyword.fetch!(opts, :queue_name))
    content = Keyword.fetch!(opts, :content)
    run_opts = Keyword.fetch!(opts, :run_opts)
    :ok = Handbean.WorkspaceSettings.subscribe_permission_policy()

    # Delegated tasks stay linked so killing their Runner also kills the task.
    # Trap task exits so the monitor's DOWN can durably close a crashed child run.
    if run_opts[:delegated?], do: Process.flag(:trap_exit, true)

    state = %__MODULE__{
      conversation_id: conversation_id,
      content: content,
      opts: Keyword.put(run_opts, :runner_pid, self()),
      queue_pid: queue_pid,
      stream_batch: StreamBatch.new(run_opts),
      status: :idle
    }

    with :ok <- attach_delegation(state.opts, conversation_id),
         {:ok, content, opts} <- accept_inbound(conversation_id, content, state.opts) do
      owner = Keyword.get(opts, :delegation_owner)
      monitor = if is_pid(owner), do: Process.monitor(owner)

      {:ok, %{state | content: content, opts: opts, delegation_monitor: monitor},
       {:continue, :start_task}}
    else
      {:error, reason} ->
        report_error({:inbound_persist_failed, reason}, state,
          failure_class: :inbound_persist_failed
        )

        {:stop, {:inbound_persist_failed, reason}}
    end
  end

  defp attach_delegation(opts, conversation_id) do
    case Keyword.get(opts, :delegation_owner) do
      nil -> :ok
      owner -> Handbean.Agent.Delegation.attach(owner, conversation_id, self())
    end
  end

  # Accepted new-run inbound is written here so
  # exclusive RunSupervisor start is the accept gate and the user entry exists
  # before handle_continue starts the provider task.
  defp accept_inbound(conversation_id, content, opts) do
    receipt = %{action: :started, run_id: Keyword.fetch!(opts, :run_id)}

    if Keyword.get(opts, :persist_inbound?, true) do
      inbound_opts = Keyword.put(opts, :deliver_as, :new_run)

      case Handbean.Agent.TranscriptPersistence.accept_inbound(
             conversation_id,
             content,
             receipt,
             inbound_opts
           ) do
        {:ok, entry} ->
          {content, opts} = align_inbound(content, opts, entry)
          {:ok, content, opts}

        :ok ->
          {:ok, content, opts}

        {:error, reason} ->
          {:error, reason}
      end
    else
      with true <- Handbean.ConversationStore.active?(conversation_id),
           :ok <-
             Handbean.Agent.OperationReceipt.complete(
               {:message, conversation_id},
               opts[:request_id],
               receipt
             ) do
        {:ok, content, opts}
      else
        false -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp align_inbound(content, opts, %{"id" => id}) when is_binary(id) do
    previous = opts[:transcript_id] || opts[:message_id]

    cond do
      previous == id ->
        {content, opts}

      is_nil(previous) ->
        {content, Keyword.merge(opts, message_id: id, transcript_id: id)}

      true ->
        content =
          case content do
            %Handbean.Agent.Message{} = message -> %{message | id: id}
            other -> other
          end

        opts = Keyword.merge(opts, message_id: id, transcript_id: id, inbound_id: id)
        {content, opts}
    end
  end

  defp align_inbound(content, opts, _entry), do: {content, opts}

  @impl true
  def handle_continue(:start_task, state) do
    prewarm_search(state)

    Registry.update_value(Handbean.AgentRunRegistry, state.conversation_id, fn _ ->
      %{run_id: state.opts[:run_id], active?: true}
    end)

    if job_context_present?(state) do
      case Handbean.Jobs.open_run(job_context(state), self()) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("[Runner] job scope unavailable: #{reason}")
      end
    end

    :ok =
      Session.attach_run(state.conversation_id, self(), state.queue_pid,
        run_id: Keyword.get(state.opts, :run_id),
        run_supervisor: state.opts[:run_supervisor],
        workspace_path: Keyword.get(state.opts, :workspace_path),
        model: Keyword.get(state.opts, :model)
      )

    started_at = System.monotonic_time(:millisecond)
    {deadline, timer} = arm_timeout(state)

    run_opts =
      state.opts
      |> Keyword.put(:candidate_queue, state.queue_pid)
      |> maybe_put_run_deadline(state, deadline)
      |> put_compaction_callback(self())
      |> put_persistence_callback(state.conversation_id)

    start_task = if state.opts[:delegated?], do: :async, else: :async_nolink

    task =
      apply(Task.Supervisor, start_task, [
        Keyword.fetch!(run_opts, :run_task_supervisor),
        fn ->
          owner = run_opts[:delegation_owner]

          with :ok <-
                 if(owner,
                   do: Handbean.Agent.Delegation.attach_task(owner, state.conversation_id),
                   else: :ok
                 ) do
            Handbean.Agent.run(state.content, run_opts)
          end
        end
      ])

    {:noreply,
     %{
       state
       | status: :running,
         task: task,
         started_at: started_at,
         deadline: deadline,
         deadline_timer: timer
     }}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     {:ok,
      %{
        conversation_id: state.conversation_id,
        running?: state.status in [:running, :awaiting_approval],
        status: state.status,
        run_pid: self(),
        run_id: state.opts[:run_id],
        run_supervisor: state.opts[:run_supervisor],
        queue_pid: state.queue_pid,
        deadline: state.deadline,
        error: state.error,
        interrupt_type: interrupt_type(state),
        interrupt_data: interrupt_data(state),
        approval_batch_id: approval_batch_id(state)
      }}, state}
  end

  def handle_call({:owns_run_task?, reader_pid, run_id}, _from, state) do
    owned? =
      state.status == :running and state.opts[:run_id] == run_id and
        match?(%Task{pid: ^reader_pid}, state.task)

    {:reply, owned?, state}
  end

  def handle_call({:persist_compaction, event}, _from, state) when is_map(event) do
    reply =
      Handbean.Agent.CompactionCheckpoint.persist(
        state.conversation_id,
        event,
        state.opts
      )

    case reply do
      {:ok, checkpoint} ->
        Handbean.Memory.Reflector.maybe_trigger(
          state.conversation_id,
          checkpoint,
          reflection_opts(state.opts)
        )

      _other ->
        :ok
    end

    {:reply, reply, state}
  end

  def handle_call({:persist_event, {:message_delta, payload} = event}, _from, state)
      when is_map(payload) and state.status == :running do
    cond do
      enriched_stream_delta?(payload) ->
        case persist_event_after_flush(state, event) do
          {:ok, projected, state} ->
            {:reply, :ok, %{state | stream_started?: visible_delta?(projected)}}

          {:error, reason, state} ->
            {:reply, {:error, reason}, state}
        end

      empty_stream_chunk?(payload) ->
        {:reply, :ok, state}

      true ->
        case queue_stream_event(state, event) do
          {:ok, state} -> {:reply, :ok, state}
          {:error, reason, state} -> {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:persist_event, event}, _from, state) when state.status == :running do
    state = %{state | stream_started?: false}

    case persist_event_after_flush(state, event) do
      {:ok, _projected, state} -> {:reply, :ok, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:persist_event, _event}, _from, state) do
    {:reply, {:error, :run_not_active}, state}
  end

  def handle_call(:cancel, from, state), do: handle_call({:cancel, nil}, from, state)

  def handle_call({:cancel, expected_run_id}, from, %{status: status, task: task} = state)
      when status in [:running, :awaiting_approval] do
    with :ok <- validate_run_identity(state, expected_run_id) do
      cleanup_os_processes(state)
      close_scope(state)
      shutdown_run_tasks(state, task)
      {state, flush_error} = flush_before_terminal(state)
      persist_cancelled_run(state)
      Handbean.Agent.CandidateQueue.seal(state.queue_pid)

      payload =
        %{status: "cancelled", turns: 0, run_id: state.opts[:run_id]}
        |> maybe_put_stream_flush_error(flush_error)

      Session.broadcast_event(state.conversation_id, :run_end, payload)

      Session.mark_run_finished(state.conversation_id, state.opts[:run_id])
      # Teardown may terminate this Runner immediately; acknowledge after all
      # run-owned tasks are down and before launching tree teardown.
      GenServer.reply(from, terminal_flush_reply(flush_error))
      schedule_terminal_callback(state, %{status: :cancelled})
      stop_run_supervisor(state)
      {:noreply, %{state | status: :cancelled, task: nil, interrupted_state: nil}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:cancel, _expected_run_id}, _from, state) do
    {:reply, {:error, :not_running}, state}
  end

  def handle_call({:resume, decisions}, from, state),
    do: handle_call({:resume, decisions, nil, nil}, from, state)

  def handle_call(
        {:resume, decisions, expected_run_id, expected_batch_id},
        _from,
        %{status: :awaiting_approval} = state
      ) do
    with :ok <- validate_run_identity(state, expected_run_id),
         :ok <- validate_batch_identity(state, expected_batch_id) do
      {:reply, :ok, resume_with_decisions(state, decisions)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:resume, _decisions, _expected_run_id, _expected_batch_id}, _from, state) do
    {:reply, {:error, :not_awaiting_approval}, state}
  end

  def handle_call({:enqueue, content, opts}, _from, state) do
    reply = Handbean.Agent.CandidateQueue.enqueue(state.queue_pid, content, opts)
    {:reply, reply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{delegation_monitor: ref} = state)
      when is_reference(ref) do
    shutdown_run_tasks(state, state.task)
    {state, _flush_error} = flush_before_terminal(state)
    persist_cancelled_run(state)
    Session.mark_run_finished(state.conversation_id, state.opts[:run_id])
    stop_run_supervisor(state)
    {:stop, :normal, %{state | task: nil}}
  end

  def handle_info({ref, {:ok, _result}}, %{task: %{ref: ref}, status: :timeout} = state) do
    Process.demonitor(ref, [:flush])
    Logger.debug("[Runner] dropped late result after run deadline ref=#{inspect(ref)}")
    {:noreply, %{state | task: nil}}
  end

  def handle_info({ref, {:ok, result}}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    case result do
      %Handbean.Agent.State{status: :interrupted} = interrupted ->
        state =
          if absolute_timeout?(state) do
            %{state | status: :awaiting_approval, interrupted_state: interrupted, task: nil}
          else
            cancel_timeout(state.deadline_timer)

            %{
              state
              | status: :awaiting_approval,
                interrupted_state: interrupted,
                task: nil,
                deadline: nil,
                deadline_timer: nil
            }
          end

        {:noreply, reconcile_permission_policy(state)}

      %Handbean.Agent.State{status: :halted} = halted ->
        finish_terminal(state, halted, :halted)

      %Handbean.Agent.State{status: :error, error: reason} = errored ->
        report_error(reason || :agent_error, state)
        finish_terminal(state, errored, :error)

      %Handbean.Agent.State{status: status} = result ->
        finish_terminal(state, result, status)

      _ ->
        finish_terminal(state, result, :completed)
    end
  end

  def handle_info({ref, {:error, reason}}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    Handbean.Agent.Provider.Cursor.Session.stop_for_conversation(state.conversation_id)
    finish_error(state, reason)
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %{ref: ref}} = state) do
    Handbean.Agent.Provider.Cursor.Session.stop_for_conversation(state.conversation_id)
    finish_error(state, reason)
  end

  def handle_info({:os_process_started, os_pid, invocation}, state)
      when is_integer(os_pid) do
    {:noreply, %{state | os_processes: [{os_pid, invocation} | state.os_processes]}}
  end

  def handle_info({:run_progress, run_id, kind}, state)
      when state.status == :running and kind in @progress_events do
    if state.opts[:run_id] == run_id and not absolute_timeout?(state) do
      cancel_timeout(state.deadline_timer)
      {deadline, timer} = arm_timeout(state)
      {:noreply, %{state | deadline: deadline, deadline_timer: timer}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:run_deadline, deadline}, %{deadline: deadline} = state)
      when state.status in [:running, :awaiting_approval] do
    report_error(:run_timeout, state, failure_class: :run_timeout)
    cleanup_os_processes(state)
    shutdown_run_tasks(state, state.task)
    {state, flush_error} = flush_before_terminal(state)

    payload =
      %{
        status: "timeout",
        turns: 0,
        error: "run deadline exceeded",
        reason: :run_timeout,
        execution: :unknown,
        run_id: state.opts[:run_id]
      }
      |> maybe_put_stream_flush_error(flush_error)

    persist_terminal_event(state, payload)
    Handbean.Agent.CandidateQueue.seal(state.queue_pid)
    Session.broadcast_event(state.conversation_id, :run_end, payload)
    Session.mark_run_finished(state.conversation_id, state.opts[:run_id])
    schedule_terminal_callback(state, %{status: :timeout})
    stop_run_supervisor(state)

    {:stop, :shutdown, %{state | status: :timeout, task: nil, deadline_timer: nil}}
  end

  def handle_info({:run_deadline, _stale}, state), do: {:noreply, state}

  def handle_info({:run_inactivity, deadline}, %{deadline: deadline, status: :running} = state) do
    timeout_ms = timeout_ms(state)

    report_error({:run_inactivity_timeout, timeout_ms}, state,
      failure_class: :run_inactivity_timeout
    )

    cleanup_os_processes(state)
    shutdown_run_tasks(state, state.task)
    {state, flush_error} = flush_before_terminal(state)

    payload =
      %{
        status: "timeout",
        turns: 0,
        error: "run stalled: no progress for #{timeout_ms}ms",
        reason: :run_inactivity_timeout,
        execution: :unknown,
        run_id: state.opts[:run_id]
      }
      |> maybe_put_stream_flush_error(flush_error)

    persist_terminal_event(state, payload)
    Handbean.Agent.CandidateQueue.seal(state.queue_pid)
    Session.broadcast_event(state.conversation_id, :run_end, payload)
    Session.mark_run_finished(state.conversation_id, state.opts[:run_id])
    schedule_terminal_callback(state, %{status: :timeout})
    stop_run_supervisor(state)

    {:stop, :shutdown, %{state | status: :timeout, task: nil, deadline_timer: nil}}
  end

  def handle_info({:run_inactivity, _stale}, state), do: {:noreply, state}

  def handle_info({:flush_stream_batch, token}, %{status: :running} = state) do
    case state.stream_batch.timer do
      {_timer_ref, ^token} ->
        case flush_stream_batch(state) do
          {:ok, state} ->
            {:noreply, state}

          {:error, reason, state} ->
            finish_error(state, {:stream_flush_failed, reason})
        end

      _stale ->
        {:noreply, state}
    end
  end

  def handle_info({:flush_stream_batch, _token}, state) do
    {:noreply, discard_stream_batch(state)}
  end

  def handle_info({:EXIT, _pid, reason}, state) when reason not in [:normal, :shutdown] do
    abort_unreplayable(state, {:run_tree_exit, reason})
  end

  def handle_info({:workspace_permission_policy_changed, settings_path}, state) do
    if permission_settings_path(state) == {:ok, settings_path} do
      {:noreply, reconcile_permission_policy(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc false
  def abort_unreplayable(state, reason) do
    report_error(reason, state, failure_class: :run_tree_exit)
    shutdown_run_tasks(state, state.task)
    {state, flush_error} = flush_before_terminal(state)

    payload =
      %{
        status: "error",
        turns: 0,
        error: inspect(reason),
        execution: :unknown,
        replayed: false,
        run_id: state.opts[:run_id]
      }
      |> maybe_put_stream_flush_error(flush_error)

    persist_terminal_event(state, payload)
    Handbean.Agent.CandidateQueue.seal(state.queue_pid)
    Session.broadcast_event(state.conversation_id, :run_end, payload)
    Session.mark_run_finished(state.conversation_id, state.opts[:run_id])
    schedule_terminal_callback(state, %{status: :error})
    Logger.error("[Runner] run aborted without replay: #{inspect(reason)}")
    stop_run_supervisor(state)
    {:stop, :normal, %{state | status: :error, error: reason, task: nil}}
  end

  defp finish_terminal(state, result, status) do
    case flush_stream_batch(state) do
      {:ok, state} ->
        Handbean.Agent.Provider.Cursor.Session.stop_for_conversation(state.conversation_id)
        Handbean.Agent.CandidateQueue.seal(state.queue_pid)
        Session.mark_run_finished(state.conversation_id, state.opts[:run_id])

        schedule_terminal_callback(state, %{status: status})

        stop_run_supervisor(state)
        {:noreply, %{state | status: status, result: result, task: nil}}

      {:error, reason, state} ->
        finish_error(state, {:stream_flush_failed, reason})
    end
  end

  defp schedule_terminal_callback(state, result) do
    source_run_owner =
      case state.opts[:run_supervisor] do
        supervisor when is_pid(supervisor) -> supervisor
        _missing -> self()
      end

    case Task.Supervisor.start_child(Handbean.AgentRunTaskSupervisor, fn ->
           with :ok <- await_process_exit(source_run_owner) do
             Handbean.Conversations.Collaboration.completed(
               state.conversation_id,
               result,
               state.opts
             )
           end
         end) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning("[Runner] terminal callback unavailable: #{inspect(reason)}")
    end
  end

  defp await_process_exit(pid) when is_pid(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      5_000 ->
        Process.demonitor(ref, [:flush])
        Logger.warning("[Runner] terminal callback abandoned before source run exited")
        {:error, :source_run_exit_timeout}
    end
  end

  defp interrupt_type(%{status: :awaiting_approval, interrupted_state: %{interrupt_data: data}})
       when is_map(data) do
    Handbean.Utils.SafeMap.get_any(data, :type, "type")
  end

  defp interrupt_type(_state), do: nil

  defp interrupt_data(%{status: :awaiting_approval, interrupted_state: %{interrupt_data: data}})
       when is_map(data),
       do: data

  defp interrupt_data(_state), do: nil

  defp approval_batch_id(state) do
    case interrupt_data(state) do
      data when is_map(data) ->
        Handbean.Utils.SafeMap.get_any(data, :approval_batch_id, "approval_batch_id")

      _ ->
        nil
    end
  end

  defp validate_run_identity(_state, nil), do: :ok

  defp validate_run_identity(state, expected_run_id) do
    if state.opts[:run_id] == expected_run_id,
      do: :ok,
      else: {:error, {:run_mismatch, state.opts[:run_id]}}
  end

  defp validate_batch_identity(_state, nil), do: :ok

  defp validate_batch_identity(state, expected_batch_id) do
    if approval_batch_id(state) == expected_batch_id,
      do: :ok,
      else: {:error, :stale_approval}
  end

  defp resume_with_decisions(state, decisions) do
    {deadline, timer} = resume_timeout(state)

    run_opts =
      state.opts
      |> Keyword.put(:candidate_queue, state.queue_pid)
      |> maybe_put_run_deadline(state, deadline)
      |> put_compaction_callback(self())
      |> put_persistence_callback(state.conversation_id)

    resume = resume_fun(state)

    Session.broadcast_event(state.conversation_id, :run_resumed, %{run_id: state.opts[:run_id]})

    task =
      Task.Supervisor.async_nolink(Keyword.fetch!(run_opts, :run_task_supervisor), fn ->
        resume.(state.interrupted_state, decisions, run_opts)
      end)

    %{
      state
      | status: :running,
        task: task,
        interrupted_state: nil,
        deadline: deadline,
        deadline_timer: timer,
        stream_started?: false
    }
  end

  defp reconcile_permission_policy(%{status: :awaiting_approval} = state) do
    case ToolGuard.auto_resume_decisions(state.interrupted_state) do
      {:ok, decisions} -> resume_with_decisions(state, decisions)
      :pending -> state
    end
  end

  defp reconcile_permission_policy(state), do: state

  defp permission_settings_path(state) do
    case state.opts[:workspace_path] || state.opts[:working_directory] do
      path when is_binary(path) and path != "" -> Handbean.WorkspaceSettings.resolve_path(path)
      _missing -> :error
    end
  end

  defp resume_fun(state) do
    if interrupt_type(state) == :stall_check do
      &Handbean.Agent.resume_after_stall_check/3
    else
      &Handbean.Agent.resume_after_tool_approval/3
    end
  end

  defp cleanup_os_processes(state) do
    Enum.each(state.os_processes, fn {os_pid, invocation} ->
      Handbean.Platform.ProcessRunner.cleanup_owned(os_pid, invocation)
    end)
  end

  defp shutdown_run_tasks(state, task) do
    shutdown_run_task(task)

    case state.opts[:run_supervisor] do
      supervisor when is_pid(supervisor) ->
        Supervisor.terminate_child(supervisor, Handbean.Agent.RunTaskSupervisor)

      _ ->
        :ok
    end
  catch
    :exit, _reason -> :ok
  end

  defp shutdown_run_task(nil), do: :ok

  defp shutdown_run_task(%Task{} = task) do
    if is_pid(task.pid), do: send(task.pid, :run_cancelled)
    _ = Task.shutdown(task, :brutal_kill)
    :ok
  end

  defp arm_timeout(state) do
    timeout = timeout_ms(state)
    deadline = System.monotonic_time(:millisecond) + timeout

    message =
      if absolute_timeout?(state),
        do: {:run_deadline, deadline},
        else: {:run_inactivity, deadline}

    {deadline, Process.send_after(self(), message, timeout)}
  end

  defp resume_timeout(state) do
    if absolute_timeout?(state),
      do: {state.deadline, state.deadline_timer},
      else: arm_timeout(state)
  end

  defp timeout_ms(state),
    do: Keyword.get(state.opts, :timeout_ms, @default_inactivity_timeout_ms)

  defp absolute_timeout?(state), do: Keyword.get(state.opts, :delegated?, false)

  defp maybe_put_run_deadline(opts, state, deadline) do
    if absolute_timeout?(state),
      do: Keyword.put(opts, :run_deadline, deadline),
      else: Keyword.delete(opts, :run_deadline)
  end

  defp cancel_timeout(ref) when is_reference(ref), do: Process.cancel_timer(ref)
  defp cancel_timeout(_), do: false

  defp persist_cancelled_run(state) do
    payload = %{status: "cancelled", turns: 0, run_id: state.opts[:run_id]}

    payload =
      case state.interrupted_state do
        %{usage: usage, turn: turn} when is_map(usage) ->
          payload |> Map.put(:usage, usage) |> Map.put(:turns, turn)

        _ ->
          payload
      end

    persist_terminal_event(state, payload)
  end

  defp persist_terminal_event(state, payload) do
    case Handbean.Agent.TranscriptPersistence.handle_event(
           state.conversation_id,
           {:run_end, payload},
           state.opts
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "[Runner] terminal transcript persist failed conversation=#{state.conversation_id} " <>
            "reason=#{inspect(reason)}"
        )
    end
  rescue
    error ->
      # An unavailable disk must not crash/restart Runner and execute the run
      # again. Persisted streaming entries remain recoverable on the next boot.
      Logger.error("[Runner] terminal transcript persist failed: #{Exception.message(error)}")
  catch
    :exit, reason ->
      Logger.error("[Runner] terminal transcript owner unavailable: #{inspect(reason)}")
  end

  defp finish_error(state, reason) do
    shutdown_run_tasks(state, state.task)

    {state, flush_error} =
      case reason do
        {:stream_flush_failed, flush_error} ->
          Handbean.Agent.TranscriptPersistence.discard_pending(state.conversation_id)
          {discard_stream_batch(state), flush_error}

        _other ->
          flush_before_terminal(state)
      end

    final_reason =
      cond do
        match?({:stream_flush_failed, _reason}, reason) -> reason
        flush_error -> {:stream_flush_failed, flush_error, reason}
        true -> reason
      end

    report_error(final_reason, state)
    message = inspect(final_reason)

    payload = %{
      status: "error",
      turns: 0,
      error: message,
      run_id: state.opts[:run_id]
    }

    persist_terminal_event(state, payload)
    Handbean.Agent.CandidateQueue.seal(state.queue_pid)
    Session.broadcast_event(state.conversation_id, :run_end, payload)

    Session.mark_run_finished(state.conversation_id, state.opts[:run_id])
    schedule_terminal_callback(state, %{status: :error})
    Logger.error("[Runner] Agent run failed: #{message}")
    stop_run_supervisor(state)
    {:noreply, %{state | status: :error, error: reason, task: nil}}
  end

  defp report_error(reason, state, opts \\ []) do
    ErrorReporter.report(
      reason,
      %{
        "source" => "agent_runner",
        "conversation_id" => state.conversation_id,
        "parent_conversation_id" => parent_conversation_id(state.opts),
        "run_id" => state.opts[:run_id],
        "workspace_id" => state.opts[:workspace_id],
        "workspace_path" => state.opts[:workspace_path],
        "model" => state.opts[:model]
      },
      Keyword.merge(
        [provider: state.opts[:provider], provider_config: state.opts[:provider_config]],
        opts
      )
    )
  end

  defp parent_conversation_id(opts) do
    opts
    |> Keyword.get(:context, %{})
    |> get_in([:delegation_parent, :conversation_id])
  end

  defp stop_run_supervisor(state) do
    close_scope(state)

    case state.opts[:run_supervisor] do
      pid when is_pid(pid) ->
        Task.Supervisor.start_child(Handbean.AgentRunTaskSupervisor, fn ->
          Handbean.AgentRunSupervisor.stop_run(pid)
        end)

      _ ->
        :ok
    end

    :ok
  end

  defp close_scope(state) do
    Handbean.Tool.Builtin.Computer.stop(state.conversation_id, state.opts[:run_id])

    Registry.update_value(Handbean.AgentRunRegistry, state.conversation_id, fn metadata ->
      Map.put(metadata || %{}, :active?, false)
    end)

    if job_context_present?(state), do: Handbean.Jobs.close_run(job_context(state), :completed)
    Handbean.Agent.Provider.Cursor.Session.stop_for_conversation(state.conversation_id)
  end

  defp prewarm_search(state) do
    case state.opts[:working_directory] do
      workspace when is_binary(workspace) and workspace != "" ->
        case Handbean.Search.prewarm(workspace) do
          :ok -> :ok
          {:error, reason} -> Logger.warning("[Runner] search prewarm failed: #{inspect(reason)}")
        end

      _ ->
        :ok
    end
  end

  defp job_context_present?(state) do
    dir = state.opts[:working_directory]
    is_binary(dir) and dir != ""
  end

  defp job_context(state) do
    %{
      conversation_id: state.conversation_id,
      run_id: state.opts[:run_id],
      working_directory: state.opts[:working_directory]
    }
  end

  defp put_persistence_callback(opts, conversation_id) do
    user_on_event = Keyword.get(opts, :on_event)
    progress = fn kind -> notify_progress_owner({kind, %{}}, opts) end
    opts = Keyword.put(opts, :on_progress, progress)

    Keyword.put(opts, :on_event, fn event ->
      {kind, payload} = event

      # 1. Run extension hooks (may block/transform)
      hook_result =
        if Keyword.get(opts, :delegated?, false),
          do: :ok,
          else: Handbean.Extension.HookPipeline.run(conversation_id, event)

      case hook_result do
        {:block, reason} ->
          if Handbean.Extension.Event.blockable?(kind) do
            Logger.debug(
              "[Runner] event blocked by extension hook kind=#{kind} conversation=#{conversation_id} reason=#{reason}"
            )
          else
            Logger.warning(
              "[Runner] extension hook attempted to block read-only event kind=#{kind} conversation=#{conversation_id} reason=#{reason} — ignoring block"
            )

            route_persistence_event(conversation_id, event, opts, user_on_event)
          end

        {:transform, transformed_payload} ->
          if Handbean.Extension.Event.blockable?(kind) do
            transformed_event = {kind, Map.merge(payload, transformed_payload)}
            route_persistence_event(conversation_id, transformed_event, opts, user_on_event)
          else
            Logger.debug(
              "[Runner] extension hook attempted to transform read-only event kind=#{kind} conversation=#{conversation_id} — ignoring transform"
            )

            route_persistence_event(conversation_id, event, opts, user_on_event)
          end

        :ok ->
          route_persistence_event(conversation_id, event, opts, user_on_event)
      end
    end)
  end

  defp put_compaction_callback(opts, runner) when is_pid(runner) do
    Keyword.put(opts, :on_compaction_complete, fn event, state ->
      event =
        Map.merge(event, %{
          context_edited: state.context_edited,
          context_generation: state.context_generation,
          context_window: state.config.max_tokens,
          model: state.config.model,
          run_id: state.config.run_id
        })

      GenServer.call(runner, {:persist_compaction, event}, 30_000)
    end)
  end

  defp reflection_opts(opts) do
    Keyword.take(opts, [
      :builtin_memory_enabled,
      :workspace_id,
      :workspace_path,
      :working_directory,
      :model,
      :reasoning_level,
      :provider_config,
      :om,
      :transcript_store
    ])
  end

  defp persist_and_callback(conversation_id, event, opts, user_on_event) do
    track_search_access(event, opts)

    # 2. Normal persistence + session broadcast
    log_runner_event(conversation_id, event)

    case Handbean.Agent.TranscriptPersistence.handle_event(conversation_id, event, opts) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
    |> case do
      :ok ->
        # 3. User callback (if any)
        if is_function(user_on_event, 1) do
          user_on_event.(event)
        end

        projected = Handbean.Agent.TranscriptPersistence.project_event(conversation_id, event)
        broadcast_session_event(conversation_id, projected, opts)
        {:ok, projected}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp route_persistence_event(conversation_id, event, opts, user_on_event) do
    notify_progress_owner(event, opts)

    case Keyword.get(opts, :runner_pid) do
      pid when is_pid(pid) ->
        case GenServer.call(pid, {:persist_event, event}, :infinity) do
          :ok ->
            :ok

          {:error, reason} ->
            raise "Transcript persistence failed: #{inspect(reason)} conversation=#{conversation_id}"
        end

      _missing ->
        case persist_and_callback(conversation_id, event, opts, user_on_event) do
          {:ok, _projected} ->
            :ok

          {:error, reason} ->
            raise "Transcript persistence failed: #{inspect(reason)} conversation=#{conversation_id}"
        end
    end
  end

  defp queue_stream_event(%{stream_started?: false} = state, event) do
    case persist_event_now(state, event) do
      {:ok, projected} ->
        {:ok, %{state | stream_started?: visible_delta?(projected)}}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp queue_stream_event(state, {:message_delta, payload}) do
    case StreamBatch.append(state.stream_batch, payload) do
      {:boundary, _batch} ->
        with {:ok, state} <- flush_stream_batch(state) do
          queue_stream_event(%{state | stream_started?: false}, {:message_delta, payload})
        end

      {:ok, batch} ->
        batch = if StreamBatch.empty?(batch), do: batch, else: maybe_arm_stream_timer(batch)
        state = %{state | stream_batch: batch}

        if StreamBatch.full?(state.stream_batch) do
          flush_stream_batch(state)
        else
          {:ok, state}
        end
    end
  end

  defp persist_event_after_flush(state, event) do
    case flush_stream_batch(state) do
      {:ok, flushed_state} ->
        case persist_event_now(flushed_state, event) do
          {:ok, projected} -> {:ok, projected, flushed_state}
          {:error, reason} -> {:error, reason, flushed_state}
        end

      {:error, reason, flushed_state} ->
        {:error, reason, flushed_state}
    end
  end

  defp flush_stream_batch(state) do
    batch = state.stream_batch

    if StreamBatch.empty?(batch) do
      cancel_stream_timer(batch.timer)
      {:ok, %{state | stream_batch: StreamBatch.reset(batch)}}
    else
      cancel_stream_timer(batch.timer)
      event = StreamBatch.event(batch)
      state = %{state | stream_batch: StreamBatch.reset(batch)}

      case persist_event_now(state, event) do
        {:ok, _projected} -> {:ok, state}
        {:error, reason} -> {:error, reason, state}
      end
    end
  end

  defp flush_before_terminal(state) do
    case flush_stream_batch(state) do
      {:ok, state} ->
        {state, nil}

      {:error, reason, state} ->
        Handbean.Agent.TranscriptPersistence.discard_pending(state.conversation_id)
        {state, reason}
    end
  end

  defp discard_stream_batch(state) do
    cancel_stream_timer(state.stream_batch.timer)
    %{state | stream_batch: StreamBatch.reset(state.stream_batch)}
  end

  defp maybe_arm_stream_timer(%StreamBatch{timer: nil} = batch) do
    token = make_ref()
    timer_ref = Process.send_after(self(), {:flush_stream_batch, token}, batch.max_wait_ms)
    %{batch | timer: {timer_ref, token}}
  end

  defp maybe_arm_stream_timer(batch), do: batch

  defp cancel_stream_timer({timer_ref, _token}) when is_reference(timer_ref),
    do: Process.cancel_timer(timer_ref)

  defp cancel_stream_timer(_timer), do: false

  defp persist_event_now(state, event) do
    opts = Keyword.put(state.opts, :runner_pid, self())

    result =
      try do
        persist_and_callback(state.conversation_id, event, opts, state.opts[:on_event])
      rescue
        error -> {:error, {:exception, Exception.message(error)}}
      catch
        :exit, reason -> {:error, {:exit, reason}}
        kind, reason -> {:error, {kind, reason}}
      end

    case result do
      {:error, _reason} = error ->
        # TranscriptPersistence may have staged an entry before its store write
        # failed. A later terminal event must not retry that hidden buffer and
        # prevent the durable error record from being written.
        Handbean.Agent.TranscriptPersistence.discard_pending(state.conversation_id)
        error

      success ->
        success
    end
  end

  defp visible_delta?({:message_delta, payload}) do
    text = Map.get(payload, :text, Map.get(payload, "text"))
    is_binary(text) and text != ""
  end

  defp visible_delta?(_event), do: false

  defp empty_stream_chunk?(payload) do
    Map.get(payload, :chunk, Map.get(payload, "chunk")) in [nil, ""]
  end

  defp enriched_stream_delta?(payload) do
    Enum.any?([:thinking, :thinking_delta, :provider_items], fn key ->
      payload
      |> Map.get(key, Map.get(payload, Atom.to_string(key)))
      |> present_stream_metadata?()
    end)
  end

  defp present_stream_metadata?(value) when value in [nil, "", []], do: false
  defp present_stream_metadata?(value) when is_map(value), do: map_size(value) > 0
  defp present_stream_metadata?(_value), do: true

  defp terminal_flush_reply(nil), do: :ok
  defp terminal_flush_reply(reason), do: {:error, {:stream_flush_failed, reason}}

  defp maybe_put_stream_flush_error(payload, nil), do: payload

  defp maybe_put_stream_flush_error(payload, reason) do
    Map.put(payload, :transcript_error, inspect({:stream_flush_failed, reason}))
  end

  defp track_search_access({:tool_end, payload}, opts) do
    tool = Handbean.Utils.SafeMap.get_any(payload, :tool, "tool")
    path = Handbean.Utils.SafeMap.get_any(payload, :file_path, "file_path")
    workspace = opts[:working_directory]
    successful? = is_nil(payload[:error]) and is_nil(payload["error"])
    normalized_tool = if is_binary(tool), do: String.downcase(tool), else: ""

    if successful? and normalized_tool in ["read", "edit", "write"] and
         is_binary(workspace) and is_binary(path) do
      Handbean.Search.touch(workspace, path)

      if normalized_tool in ["edit", "write"] do
        Handbean.Search.notify_path(workspace, path)
      end
    end

    :ok
  end

  defp track_search_access(_event, _opts), do: :ok

  defp notify_progress_owner({kind, _payload}, opts) when kind in @progress_events do
    case Keyword.get(opts, :runner_pid) do
      pid when is_pid(pid) -> send(pid, {:run_progress, Keyword.get(opts, :run_id), kind})
      _ -> :ok
    end
  end

  defp notify_progress_owner(_event, _opts), do: :ok

  defp broadcast_session_event(conversation_id, {kind, payload}, opts) do
    payload = stamp_run_id(payload, opts)
    Session.broadcast_event(conversation_id, kind, payload)
  end

  defp stamp_run_id(payload, opts) when is_map(payload) do
    Map.put_new(payload, :run_id, Keyword.get(opts, :run_id))
  end

  defp stamp_run_id(payload, _opts), do: payload

  defp log_runner_event(_conversation_id, {:message_delta, %{chunk: chunk}})
       when is_binary(chunk) do
    :ok
  end

  defp log_runner_event(_conversation_id, {:thinking_delta, _payload}) do
    :ok
  end

  defp log_runner_event(conversation_id, {kind, _payload}) do
    if kind not in [:message_delta, :user_on_chunk] do
      Logger.debug("[Runner] persistence callback #{kind} conversation=#{conversation_id}")
    end
  end

  defp resolve_queue_pid!({:via, Registry, {registry, key}}) do
    case Registry.lookup(registry, key) do
      [{pid, _}] -> pid
      [] -> raise "candidate queue not started for #{inspect(key)}"
    end
  end

  defp call_runner(conversation_id, message) do
    GenServer.call({:via, Registry, {Handbean.AgentRunRegistry, conversation_id}}, message)
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
    :exit, {:normal, _} -> {:error, :not_found}
    :exit, reason -> {:error, reason}
  end
end
