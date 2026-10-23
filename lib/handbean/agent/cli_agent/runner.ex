defmodule Handbean.Agent.CliAgent.Runner do
  @moduledoc """
  Supervised lifecycle and persistence owner for one external CLI run.

  The Runner outlives any LiveView that admitted it. Backend tasks only perform
  CLI I/O and send normalized events here; this GenServer serializes every
  transcript mutation and matching Session broadcast from one process.
  """

  use GenServer

  alias Handbean.Agent.{CandidateQueue, Message, TranscriptPersistence}
  alias Handbean.Agent.CliAgent.{Binding, Run}
  alias Handbean.PubSub.Session

  require Logger

  defstruct [
    :conversation_id,
    :content,
    :display_text,
    :opts,
    :queue_pid,
    :task,
    :status,
    :status_detail,
    :pending,
    :active_module,
    :active_session,
    :session_id,
    turns: 0,
    terminal?: false
  ]

  @type ack :: %{action: :started, run_id: String.t(), run_pid: pid()}

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :conversation_id)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def start_link(opts) do
    conversation_id = Keyword.fetch!(opts, :conversation_id)
    run_id = opts |> Keyword.fetch!(:run_opts) |> Keyword.fetch!(:run_id)
    metadata = %{run_id: run_id, active?: true, loop_owner: :cli_agent}

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {Handbean.AgentRunRegistry, conversation_id, metadata}}
    )
  end

  @doc "Admit a CLI run and acknowledge only after its inbound message is durable."
  @spec start(String.t(), Handbean.Agent.CliAgent.input(), String.t(), keyword()) ::
          {:ok, ack()} | {:error, term()}
  def start(conversation_id, content, display_text, opts)
      when is_binary(conversation_id) and is_binary(display_text) and is_list(opts) do
    run_id = Keyword.get(opts, :run_id) || Ecto.UUID.generate()
    opts = Keyword.put(opts, :run_id, run_id)

    with {:ok, _module} <- Run.validate_input(content, opts) do
      child_opts = [
        conversation_id: conversation_id,
        content: content,
        display_text: display_text,
        run_opts: opts
      ]

      case DynamicSupervisor.start_child(Handbean.AgentRunSupervisor, {__MODULE__, child_opts}) do
        {:ok, pid} -> {:ok, %{action: :started, run_id: run_id, run_pid: pid}}
        {:error, {:already_started, _pid}} -> {:error, :run_in_progress}
        {:error, {:shutdown, reason}} -> normalize_start_error(reason)
        {:error, reason} -> normalize_start_error(reason)
      end
    end
  end

  @doc "Resume an approval-suspended CLI run with an explicit backend decision."
  def resume(conversation_id, decision) when is_binary(conversation_id) do
    call(conversation_id, {:resume_cli, decision})
  end

  @doc false
  def await_stop(conversation_id) when is_binary(conversation_id) do
    case Registry.lookup(Handbean.AgentRunRegistry, conversation_id) do
      [{pid, _metadata}] ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          5_000 ->
            Process.demonitor(ref, [:flush])
            {:error, :run_in_progress}
        end

      [] ->
        :ok
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    conversation_id = Keyword.fetch!(opts, :conversation_id)
    content = Keyword.fetch!(opts, :content)
    display_text = Keyword.fetch!(opts, :display_text)
    run_opts = Keyword.fetch!(opts, :run_opts)
    queue_name = {:via, Registry, {Handbean.AgentRunQueueRegistry, conversation_id}}

    with {:ok, _session} <-
           Session.start_or_get(
             session_id: conversation_id,
             model: run_opts[:model],
             workspace_path: run_opts[:cwd]
           ),
         {:ok, _registry} <-
           Registry.register(Handbean.AgentRunSupervisorRegistry, conversation_id, :cli_agent),
         {:ok, queue_pid} <-
           Handbean.Agent.CandidateQueue.start_link(
             session_id: conversation_id,
             owner: self(),
             name: queue_name
           ) do
      finish_init(conversation_id, content, display_text, run_opts, queue_pid)
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp finish_init(conversation_id, content, display_text, run_opts, queue_pid) do
    result =
      with {:ok, _entry} <-
             accept_initial(queue_pid, conversation_id, content, run_opts),
           :ok <-
             Session.attach_run(conversation_id, self(), queue_pid,
               run_id: run_opts[:run_id],
               run_supervisor: self(),
               workspace_path: run_opts[:cwd]
             ) do
        state = %__MODULE__{
          conversation_id: conversation_id,
          content: content,
          display_text: display_text,
          opts: run_opts,
          queue_pid: queue_pid,
          status: :starting
        }

        :ok = persist_and_broadcast_start(state)
        Binding.record_run_start(conversation_id, run_opts[:backend], run_opts[:run_id], run_opts)
        {:ok, state, {:continue, :start_turn}}
      end

    case result do
      {:error, reason} ->
        stop_queue(queue_pid)
        {:stop, reason}

      success ->
        success
    end
  end

  @impl true
  def handle_continue(:start_turn, state), do: {:noreply, launch_turn(state, state.opts)}

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     {:ok,
      %{
        conversation_id: state.conversation_id,
        running?: state.status in [:starting, :running, :awaiting_approval, :cancelling],
        status: state.status,
        status_detail: state.status_detail,
        loop_owner: :cli_agent,
        backend: state.opts[:backend],
        session_id: state.session_id,
        interrupt_type: if(state.status == :awaiting_approval, do: :tool_approval),
        interrupt_data: state.pending,
        approval_batch_id: state.pending && state.pending[:approval_batch_id],
        run_pid: self(),
        run_id: state.opts[:run_id],
        run_supervisor: self(),
        queue_pid: state.queue_pid
      }}, state}
  end

  def handle_call({:cli_event, event}, _from, state) do
    :ok = Run.project(state.conversation_id, event, state.opts)
    {:reply, :ok, track_event(state, event)}
  end

  def handle_call({:cancel, expected_run_id}, _from, state) do
    cond do
      not is_nil(expected_run_id) and expected_run_id != state.opts[:run_id] ->
        {:reply, {:error, :stale_run}, state}

      state.terminal? ->
        {:reply, :ok, state}

      state.status == :cancelling ->
        {:reply, :ok, state}

      true ->
        :ok = CandidateQueue.seal(state.queue_pid)
        send(self(), :cancel_cli_run)
        {:reply, :ok, %{state | status: :cancelling, pending: nil}}
    end
  end

  def handle_call({:resume_cli, decision}, _from, %{status: :awaiting_approval} = state) do
    {:reply, :ok, do_resume_cli(state, decision)}
  end

  def handle_call({:resume_cli, _decision}, _from, state),
    do: {:reply, {:error, :not_awaiting_approval}, state}

  def handle_call(
        {:resume, decision, expected_run_id, expected_batch_id},
        _from,
        %{status: :awaiting_approval} = state
      ) do
    cond do
      not is_nil(expected_run_id) and expected_run_id != state.opts[:run_id] ->
        {:reply, {:error, {:run_mismatch, state.opts[:run_id]}}, state}

      not is_nil(expected_batch_id) and
          expected_batch_id != (state.pending && state.pending[:approval_batch_id]) ->
        {:reply, {:error, :stale_approval}, state}

      true ->
        case normalize_resume_decision(decision) do
          {:ok, normalized} ->
            {:reply, :ok, do_resume_cli(state, normalized)}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:resume, _decision, _expected_run_id, _expected_batch_id}, _from, state),
    do: {:reply, {:error, :not_awaiting_approval}, state}

  @impl true
  def handle_info({:cli_session, {:started, module, session}}, state) do
    Binding.record_session(state.conversation_id, session, state.opts)

    {:noreply,
     %{
       state
       | active_module: module,
         active_session: session,
         session_id: session.session_id || state.session_id
     }}
  end

  def handle_info({:cli_session, {:stopped, module, session}}, state) do
    state =
      if state.active_module == module and state.active_session == session,
        do: %{state | active_module: nil, active_session: nil},
        else: state

    {:noreply, state}
  end

  def handle_info(:cancel_cli_run, %{task: nil} = state) do
    state = finish(state, :cancelled)
    {:stop, :normal, state}
  end

  def handle_info(:cancel_cli_run, %{task: %Task{}, active_session: nil} = state) do
    # start_session reports asynchronously. Give that message one mailbox turn
    # before falling back to task termination so an opened OS session is stopped
    # through its backend owner first.
    Process.send_after(self(), {:force_cancel_cli_run, state.task.pid}, 50)
    {:noreply, state}
  end

  def handle_info(:cancel_cli_run, state) do
    request_cleanup(state)
    {:noreply, state}
  end

  def handle_info(
        {:force_cancel_cli_run, task_pid},
        %{status: :cancelling, task: %Task{pid: task_pid}} = state
      ) do
    request_cleanup(state)
    {:noreply, state}
  end

  def handle_info({:force_cancel_cli_run, _task_pid}, state), do: {:noreply, state}

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | task: nil}

    if state.status == :cancelling do
      state = finish(state, :cancelled)
      {:stop, :normal, state}
    else
      handle_turn_result(result, state)
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    state = %{state | task: nil}

    if state.status == :cancelling do
      state = finish(state, :cancelled)
      {:stop, :normal, state}
    else
      Logger.warning("[CliAgent.Runner] CLI task exited: #{inspect(reason)}")
      state = finish(state, :error, reason)
      {:stop, :normal, state}
    end
  end

  def handle_info({:EXIT, pid, _reason}, %{task: %Task{pid: pid}} = state), do: {:noreply, state}
  def handle_info({:EXIT, pid, reason}, %{queue_pid: pid} = state), do: {:stop, reason, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    request_cleanup(state)

    if not state.terminal? and reason not in [:normal, :shutdown] do
      _state = finish(state, :error, reason)
    end

    stop_queue(state.queue_pid)
    :ok
  end

  defp launch_turn(state, opts) do
    owner = self()
    event_sink = fn event -> GenServer.call(owner, {:cli_event, event}, 15_000) end
    session_observer = fn event -> send(owner, {:cli_session, event}) end

    opts =
      opts
      |> Keyword.put(:event_sink, event_sink)
      |> Keyword.put(:session_observer, session_observer)

    task =
      Task.Supervisor.async(Handbean.AgentRunTaskSupervisor, fn ->
        Run.turn(state.content, opts)
      end)

    %{state | task: task, status: :running}
  end

  defp handle_turn_result({:ok, _text, meta}, state) do
    remember_session(state.conversation_id, meta, state.opts)
    state = %{state | session_id: meta[:session_id] || state.session_id}
    continue_or_finish(state)
  end

  defp handle_turn_result({:awaiting, kind, meta}, state) do
    pending = pending_payload(state, kind, meta)

    Binding.record_awaiting(
      state.conversation_id,
      state.opts[:run_id],
      kind,
      meta,
      pending[:approval_batch_id]
    )

    Session.broadcast_event(state.conversation_id, :tool_approval_requested, pending)

    {:noreply,
     %{
       state
       | status: :awaiting_approval,
         pending: pending,
         session_id: meta[:session_id] || state.session_id
     }}
  end

  defp handle_turn_result({:error, reason}, state) do
    Logger.warning("[CliAgent.Runner] CLI turn failed: #{inspect(reason)}")
    state = finish(state, :error, reason)
    {:stop, :normal, state}
  end

  defp continue_or_finish(state) do
    case CandidateQueue.take_next_or_seal(state.queue_pid) do
      :sealed ->
        state = finish(state, :completed)
        {:stop, :normal, state}

      {:pending, deliver_as, message} ->
        :ok = consume_candidate(state, deliver_as, message)

        opts =
          state.opts
          |> Keyword.put(:session_id, state.session_id)
          |> Keyword.delete(:decision)

        state = %{state | content: candidate_input(message), status_detail: nil}
        {:noreply, launch_turn(state, opts)}
    end
  end

  defp consume_candidate(state, deliver_as, message) do
    payload = %{
      deliver_as: deliver_as,
      count: 1,
      message_ids: [message.id],
      run_id: state.opts[:run_id]
    }

    with :ok <-
           TranscriptPersistence.handle_event(
             state.conversation_id,
             {:candidate_message_injected, payload},
             state.opts
           ) do
      Session.broadcast_event(state.conversation_id, :candidate_message_injected, payload)
      :ok
    end
  end

  defp candidate_input(%Message{content: content}) when is_binary(content), do: content
  defp candidate_input(%Message{} = message), do: message

  defp track_event(state, {:turn_end, _payload}), do: %{state | turns: state.turns + 1}

  defp track_event(state, {:status, %{state: detail}}) when is_binary(detail),
    do: %{state | status_detail: detail}

  defp track_event(state, _event), do: state

  defp do_resume_cli(state, decision) do
    opts =
      state.opts
      |> Keyword.put(:decision, decision)
      |> Keyword.put(:session_id, state.pending.session_id)

    Binding.record_resumed(state.conversation_id, state.opts[:run_id])
    Session.broadcast_event(state.conversation_id, :run_resumed, lifecycle_payload(state))
    launch_turn(%{state | pending: nil, status_detail: nil}, opts)
  end

  defp normalize_resume_decision({kind, _value} = decision)
       when kind in [:permission, :ask_user],
       do: {:ok, decision}

  defp normalize_resume_decision([decision | _]) when is_map(decision) do
    cond do
      is_binary(decision[:option] || decision["option"]) ->
        {:ok, {:permission, decision[:option] || decision["option"]}}

      is_list(decision[:answers] || decision["answers"]) ->
        {:ok, {:ask_user, decision[:answers] || decision["answers"]}}

      true ->
        {:error, :invalid_decision}
    end
  end

  defp normalize_resume_decision(_decision), do: {:error, :invalid_decision}

  defp pending_payload(state, kind, meta) do
    request = meta.request || %{}
    batch_id = request[:id] || Ecto.UUID.generate()

    %{
      kind: :cli_agent,
      request_kind: kind,
      conversation_id: state.conversation_id,
      backend: meta.backend,
      session_id: meta.session_id,
      run_id: state.opts[:run_id],
      approval_batch_id: batch_id,
      options: meta.options || request[:options] || [],
      action_requests: action_requests(kind, request)
    }
  end

  defp action_requests(:permission, request) do
    options = request[:options] || []

    requests =
      Enum.map(request[:tools] || [], fn tool ->
        %{
          tool_name: tool[:name] || "cli",
          tool_call_id: tool[:id] || request[:id],
          arguments: tool_arguments(tool, options)
        }
      end)

    if requests == [] do
      [
        %{
          tool_name: "cli",
          tool_call_id: request[:id],
          arguments: %{options: options}
        }
      ]
    else
      requests
    end
  end

  defp action_requests(:ask_user, request) do
    [
      %{
        tool_name: "ask_user",
        tool_call_id: request[:id],
        arguments: %{questions: request[:questions] || []}
      }
    ]
  end

  defp tool_arguments(tool, options) when is_map(tool) do
    input =
      case Map.get(tool, :input) || Map.get(tool, "input") do
        map when is_map(map) -> map
        _ -> %{}
      end

    if map_size(input) > 0, do: input, else: %{options: options}
  end

  defp accept_initial(queue_pid, conversation_id, content, opts) do
    with :ok <- CandidateQueue.begin_initial(queue_pid, opts),
         {:ok, _entry} = accepted <- persist_inbound(conversation_id, content, opts),
         :ok <- CandidateQueue.commit_initial(queue_pid, opts) do
      accepted
    else
      {:error, _reason} = error ->
        :ok = CandidateQueue.abort_initial(queue_pid, opts)
        error
    end
  end

  defp persist_inbound(conversation_id, content, opts) do
    receipt = %{action: :started, run_id: opts[:run_id]}

    if Keyword.get(opts, :persist_inbound?, true) do
      TranscriptPersistence.accept_inbound(conversation_id, content, receipt, opts)
    else
      with true <- Handbean.ConversationStore.active?(conversation_id),
           :ok <-
             Handbean.Agent.OperationReceipt.complete(
               {:message, conversation_id},
               opts[:request_id],
               receipt
             ) do
        {:ok, nil}
      else
        false -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp persist_and_broadcast_start(state) do
    code_baseline =
      Handbean.Git.collect_code_baseline(state.opts[:cwd] || state.opts[:working_directory])

    payload =
      lifecycle_payload(state)
      |> Map.merge(%{model: state.opts[:model], code_baseline: code_baseline})

    with :ok <-
           TranscriptPersistence.handle_event(
             state.conversation_id,
             {:run_start, payload},
             state.opts
           ) do
      Session.broadcast_event(state.conversation_id, :run_start, payload)
      :ok
    end
  end

  defp finish(state, status, reason \\ nil)

  defp finish(%{terminal?: true} = state, _status, _reason), do: state

  defp finish(state, status, reason) do
    :ok = CandidateQueue.seal(state.queue_pid)

    payload =
      lifecycle_payload(state)
      |> Map.merge(%{status: status, turns: state.turns, session_id: state.session_id})
      |> maybe_put_error(reason)

    if status == :cancelled do
      :ok = TranscriptPersistence.cancel_running_tools(state.conversation_id, state.opts)
    end

    :ok =
      TranscriptPersistence.handle_event(state.conversation_id, {:run_end, payload}, state.opts)

    Binding.record_run_end(state.conversation_id, state.opts[:run_id], status)
    Session.broadcast_event(state.conversation_id, :run_end, payload)
    Session.mark_run_finished(state.conversation_id, state.opts[:run_id])
    %{state | terminal?: true, status: status, status_detail: nil, pending: nil}
  end

  defp lifecycle_payload(state) do
    %{
      run_id: state.opts[:run_id],
      loop_owner: :cli_agent,
      backend: state.opts[:backend]
    }
  end

  defp maybe_put_error(payload, nil), do: payload
  defp maybe_put_error(payload, reason), do: Map.put(payload, :error, reason_text(reason))

  defp remember_session(conversation_id, %{backend: backend, session_id: session_id}, opts)
       when is_binary(backend) and is_binary(session_id) do
    Binding.put(conversation_id, %{
      backend: backend,
      session_id: session_id,
      cwd: opts[:cwd],
      model: opts[:model],
      reasoning_effort: opts[:reasoning_effort],
      active_run_id: opts[:run_id],
      status: :running
    })

    :ok
  end

  defp remember_session(_conversation_id, _meta, _opts), do: :ok

  # Cancellation never waits inside the Runner loop. One supervised cleanup
  # process stops the backend session and another bounds task termination.
  defp request_cleanup(state) do
    cond do
      is_atom(state.active_module) and not is_nil(state.active_session) and
          match?(%Task{}, state.task) ->
        start_cleanup(fn ->
          safe_stop_session(state.active_module, state.active_session)
          terminate_task(state.task.pid)
        end)

      is_atom(state.active_module) and not is_nil(state.active_session) ->
        start_cleanup(fn -> safe_stop_session(state.active_module, state.active_session) end)

      match?(%Task{}, state.task) ->
        start_cleanup(fn -> terminate_task(state.task.pid) end)

      true ->
        :ok
    end

    :ok
  end

  defp start_cleanup(fun) do
    case Task.Supervisor.start_child(Handbean.AgentRunTaskSupervisor, fun) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning("[CliAgent.Runner] cleanup start failed: #{inspect(reason)}")
    end
  end

  defp terminate_task(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      Process.exit(pid, :shutdown)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        2_000 ->
          Process.exit(pid, :kill)

          receive do
            {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
          after
            500 -> Process.demonitor(ref, [:flush])
          end
      end
    end

    :ok
  end

  defp safe_stop_session(module, session) do
    module.stop_session(session)
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp stop_queue(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp stop_queue(_pid), do: :ok

  defp call(conversation_id, message) do
    case Registry.lookup(Handbean.AgentRunRegistry, conversation_id) do
      [{pid, %{loop_owner: :cli_agent}}] -> GenServer.call(pid, message)
      _ -> {:error, :not_running}
    end
  catch
    :exit, _reason -> {:error, :not_running}
  end

  defp normalize_start_error({:failed_to_start_child, _child, reason}),
    do: normalize_start_error(reason)

  defp normalize_start_error({:already_registered, _pid}), do: {:error, :run_in_progress}
  defp normalize_start_error(reason), do: {:error, reason}

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(reason), do: inspect(reason)
end
