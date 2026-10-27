defmodule Handbean.PubSub.Session do
  @moduledoc """
  Session GenServer — manages agent session lifecycle and event snapshot.

  One Session per conversation. Maintains:
  - Event sequence counter
  - Event snapshot for reconnection replay
  - Agent state reference

  ## Design

  All events for a session go through a single PubSub topic.
  The Session maintains a snapshot of the last N events for reconnection.
  """

  use GenServer

  alias Handbean.PubSub.AgentEvent

  alias Handbean.PubSub.Session.{
    CandidateMessages,
    ModelProjection,
    Persistence,
    RecoveryProjection,
    SnapshotCodec
  }

  require Logger

  @max_snapshot_events 500
  @throttle_default_ms 50

  # Disk-save throttle window for bursty streaming and per-turn events.
  # Run lifecycle, approval and candidate-message boundaries always force-save.
  @save_throttle_ms 500

  # Events that are emitted at high frequency during streaming.
  # These are broadcast via cast (no waiting) and their disk snapshot is throttled.
  @high_freq_events [:message_delta, :thinking_delta]

  # Per-turn events are already held in memory and their canonical transcript
  # data is persisted separately. Re-encoding the full reconnect snapshot for
  # each one makes long tool runs monopolize the Session process. Lifecycle,
  # approval and candidate-message boundaries still force-save immediately.
  @throttled_snapshot_events @high_freq_events ++
                               [
                                 :turn_start,
                                 :provider_items,
                                 :usage_updated,
                                 :tool_start,
                                 :tool_end,
                                 :turn_end
                               ]

  @doc false
  def throttle_default_ms, do: @throttle_default_ms

  @doc "Start a new session or return existing one."
  def start_or_get(opts \\ []) do
    case Handbean.SessionSupervisor.start_session(opts) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  @doc "Start a new session."
  def start_link(opts \\ []) do
    session_id = Keyword.get(opts, :session_id, Ecto.UUID.generate())
    GenServer.start_link(__MODULE__, opts, name: via_tuple(session_id))
  end

  @doc "Get session PID by id."
  def whereis(session_id) do
    case Registry.lookup(Handbean.SessionRegistry, session_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Broadcast a pre-built AgentEvent to the session topic and append to snapshot."
  @spec broadcast(String.t(), AgentEvent.t()) :: :ok
  def broadcast(session_id, %AgentEvent{} = event) do
    topic = session_topic(session_id)
    Phoenix.PubSub.broadcast(Handbean.PubSub, topic, {:agent_event, event})

    pid = whereis(session_id)
    if pid, do: GenServer.cast(pid, {:append, event})

    :ok
  end

  @doc """
  Broadcast an event with auto-incrementing seq.

  The Session GenServer manages the seq counter internally,
  ensuring monotonic ordering. Creates an AgentEvent struct
  and broadcasts via Phoenix.PubSub + appends to snapshot.

  All events use `GenServer.cast` so the agent task is never blocked by
  disk IO. High-frequency events (`#{inspect(@high_freq_events)}`) have
  their on-disk snapshot throttled (see `@save_throttle_ms`). All other
  events force-save to guarantee durability at run boundaries.
  """
  @spec broadcast_event(String.t(), AgentEvent.kind(), map()) :: :ok
  def broadcast_event(session_id, kind, payload) do
    log_broadcast_request(session_id, kind, payload)

    case whereis(session_id) do
      nil ->
        Logger.debug(
          "[Session] broadcast skipped; no session pid session=#{session_id} kind=#{kind}"
        )

        :ok

      pid ->
        GenServer.cast(pid, {:broadcast_event, kind, payload})
    end

    :ok
  end

  @doc "Subscribe to a session topic."
  def subscribe(session_id) do
    Phoenix.PubSub.subscribe(Handbean.PubSub, session_topic(session_id))
  end

  @doc "Unsubscribe from a session topic."
  def unsubscribe(session_id) do
    Phoenix.PubSub.unsubscribe(Handbean.PubSub, session_topic(session_id))
  end

  @doc "PubSub topic for a session."
  def session_topic(session_id), do: "session:#{session_id}"

  @doc "Get the current snapshot for reconnection."
  def snapshot(session_id) do
    GenServer.call(via_tuple(session_id), :snapshot)
  end

  @doc "Return the compact checkpoint needed to restore a connected client."
  def recovery_snapshot(session_id) do
    GenServer.call(via_tuple(session_id), :recovery_snapshot)
  end

  @doc "Append an event to the snapshot."
  def append_event(session_id, %AgentEvent{} = event) do
    GenServer.cast(via_tuple(session_id), {:append, event})
  end

  @doc "Update session metadata."
  def update_meta(session_id, key, value) do
    GenServer.cast(via_tuple(session_id), {:update_meta, key, value})
  end

  @doc "Update a key in extension state."
  def update_extension_state(session_id, extension_name, key, value) do
    GenServer.cast(via_tuple(session_id), {:update_extension_state, extension_name, key, value})
  end

  @doc "Delete a key from extension state."
  def delete_extension_state(session_id, extension_name, key) do
    GenServer.cast(via_tuple(session_id), {:delete_extension_state, extension_name, key})
  end

  @doc "Attach an active agent run and its candidate queue to this session."
  def attach_run(session_id, agent_pid, queue_pid, opts \\ []) do
    GenServer.call(via_tuple(session_id), {:attach_run, agent_pid, queue_pid, opts})
  end

  @doc "Enqueue a candidate message for the active run or next turn."
  def enqueue_candidate(session_id, content, opts \\ []) do
    GenServer.call(via_tuple(session_id), {:enqueue_candidate, content, opts})
  end

  @doc "Get all pending messages in candidate queue or next turn."
  @spec get_pending_messages(String.t()) :: [map()]
  def get_pending_messages(session_id) do
    case whereis(session_id) do
      nil -> []
      pid -> GenServer.call(pid, :get_pending_messages)
    end
  end

  @doc "Promote a pending follow-up message to the active run's steer queue."
  @spec promote_pending_message(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def promote_pending_message(session_id, message_id) do
    case whereis(session_id) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, {:promote_pending_message, message_id})
    end
  end

  @doc "Delete a pending message from candidate queue or next turn."
  @spec delete_pending_message(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def delete_pending_message(session_id, message_id) do
    case whereis(session_id) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, {:delete_pending_message, message_id})
    end
  end

  @doc "Drain messages that should be prepended to the next user turn."
  def drain_next_turn(session_id) do
    GenServer.call(via_tuple(session_id), :drain_next_turn)
  end

  @doc "Finish a legacy untracked run; identified runs require mark_run_finished/2."
  def mark_run_finished(session_id) do
    mark_run_finished(session_id, nil)
  end

  def mark_run_finished(session_id, run_id) do
    GenServer.call(via_tuple(session_id), {:mark_run_finished, run_id})
  end

  @doc "Project an active-run model switch without blocking execution."
  def project_model_switch(session_id, run_id, status, payload)
      when is_binary(run_id) and is_atom(status) and is_map(payload) do
    case whereis(session_id) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:transition_model_switch, run_id, status, payload})
    end
  end

  # ── Server Callbacks ──

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    model = Keyword.get(opts, :model, "unknown")

    {session_store, store_opts, recorder_opts} = Persistence.options(opts)
    loaded = Persistence.load(session_id, session_store, store_opts)

    state = %{
      session_id: session_id,
      model: model,
      epoch: Ecto.UUID.generate(),
      seq: Map.get(loaded, "seq", 0),
      events: SnapshotCodec.events(Map.get(loaded, "events", [])),
      control_events:
        loaded
        |> Map.get("control_events", Map.get(loaded, "events", []))
        |> SnapshotCodec.events()
        |> Enum.reject(&(&1.kind in @high_freq_events)),
      latest_usage_event:
        loaded
        |> Map.get("latest_usage_event")
        |> List.wrap()
        |> SnapshotCodec.events()
        |> List.first(),
      meta: %{
        created_at: DateTime.utc_now(),
        status: :active,
        running?: false,
        agent_pid: nil,
        queue_pid: nil,
        run_id: nil,
        run_supervisor: nil,
        model: Map.get(loaded, "model", model),
        active_model: nil,
        pending_model: nil,
        model_switch_status: nil,
        model_switch_revision: 0,
        workspace_path: Keyword.get(opts, :workspace_path)
      },
      agent_pid: nil,
      queue_pid: nil,
      next_turn_messages: SnapshotCodec.messages(Map.get(loaded, "next_turn_messages", [])),
      extension_state: Map.get(loaded, "extension_state", %{}),
      last_throttle: 0,
      save_timer: nil,
      session_store: session_store,
      store_opts: store_opts,
      recorder_opts: recorder_opts
    }

    Logger.debug("[Session] Created #{session_id} (model: #{model})")
    {:ok, restore_active_run(state)}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply,
     %{
       last_seq: state.seq,
       epoch: state.epoch,
       events: state.events,
       control_events: state.control_events,
       meta: state.meta,
       extension_state: state.extension_state
     }, state}
  end

  def handle_call(:recovery_snapshot, _from, state) do
    recovery_events =
      [state.latest_usage_event | state.control_events]
      |> Enum.reject(&is_nil/1)
      |> RecoveryProjection.events(state.meta.run_id)

    {:reply,
     %{
       last_seq: state.seq,
       epoch: state.epoch,
       control_events: recovery_events,
       pending_events: RecoveryProjection.pending_events(state.control_events),
       meta: state.meta,
       extension_state: state.extension_state
     }, state}
  end

  def handle_call({:attach_run, agent_pid, queue_pid, opts}, _from, state) do
    Process.monitor(agent_pid)
    Process.monitor(queue_pid)
    run_id = Keyword.get(opts, :run_id)
    active_model = ModelProjection.normalize(Keyword.get(opts, :model), state.meta.model)

    meta = %{
      state.meta
      | running?: true,
        agent_pid: agent_pid,
        queue_pid: queue_pid,
        run_id: run_id,
        run_supervisor: Keyword.get(opts, :run_supervisor),
        model: active_model.model,
        active_model: active_model,
        pending_model: nil,
        model_switch_status: nil,
        workspace_path: Keyword.get(opts, :workspace_path, state.meta.workspace_path)
    }

    new_state = %{
      state
      | agent_pid: agent_pid,
        queue_pid: queue_pid,
        model: active_model.model,
        latest_usage_event: usage_event_for_run(state.latest_usage_event, run_id),
        meta: meta
    }

    new_state = maybe_save(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call({:enqueue_candidate, content, opts}, _from, state) do
    deliver_as = Keyword.get(opts, :deliver_as, :steer)

    case deliver_as do
      :next_turn ->
        {content, opts} = CandidateMessages.stamp_ids(content, opts)
        opts = Keyword.put(opts, :run_id, state.meta.run_id)
        message = CandidateMessages.normalize(content, opts)
        receipt = %{action: :enqueued, run_id: state.meta.run_id}
        new_state = %{state | next_turn_messages: state.next_turn_messages ++ [message]}

        with true <- opts[:expected_run_id] in [nil, state.meta.run_id],
             {:ok, snapshot_saved?} <-
               Persistence.accept_next_turn(new_state, content, receipt, opts) do
          new_state =
            if snapshot_saved?, do: mark_snapshot_saved(new_state), else: maybe_save(new_state)

          broadcast_event(state.session_id, :candidate_message_injected, %{
            message_id: message.id,
            content: message.content,
            deliver_as: :next_turn,
            run_id: state.meta.run_id
          })

          reply =
            if opts[:expected_run_id],
              do: {:ok, %{action: :enqueued, run_id: state.meta.run_id, run_pid: nil}},
              else: :ok

          {:reply, reply, new_state}
        else
          false -> {:reply, {:error, :stale_run}, state}
          error -> {:reply, error, state}
        end

      kind when kind in [:steer, :follow_up] ->
        expected_run = Keyword.get(opts, :expected_run_id)

        cond do
          is_binary(expected_run) and expected_run != state.meta.run_id ->
            {:reply, {:error, :stale_run}, state}

          is_nil(state.queue_pid) ->
            {:reply, {:error, :no_active_run}, state}

          true ->
            {content, opts} = CandidateMessages.stamp_ids(content, opts)
            opts = Keyword.put(opts, :run_id, state.meta.run_id)

            case Handbean.Agent.CandidateQueue.enqueue(state.queue_pid, content, opts) do
              :ok ->
                broadcast_event(state.session_id, :candidate_message_injected, %{
                  message_id: Keyword.fetch!(opts, :message_id),
                  content: CandidateMessages.text(content),
                  deliver_as: kind,
                  run_id: state.meta.run_id
                })

                reply =
                  if Keyword.has_key?(opts, :expected_run_id),
                    do: {:ok, %{action: :enqueued, run_id: state.meta.run_id, run_pid: nil}},
                    else: :ok

                {:reply, reply, state}

              other ->
                {:reply, other, state}
            end
        end

      _ ->
        {:reply, {:error, :invalid_deliver_as}, state}
    end
  end

  def handle_call(:get_pending_messages, _from, state) do
    messages = CandidateMessages.pending(state.queue_pid, state.next_turn_messages)
    {:reply, messages, state}
  end

  def handle_call({:promote_pending_message, message_id}, _from, state) do
    case state.queue_pid do
      nil ->
        {:reply, {:error, :not_found}, state}

      queue_pid ->
        case Handbean.Agent.CandidateQueue.promote_message(queue_pid, message_id) do
          {:ok, info} ->
            broadcast_event(state.session_id, :candidate_message_injected, %{
              message_id: message_id,
              deliver_as: :steer,
              run_id: state.meta.run_id
            })

            {:reply, {:ok, info}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:delete_pending_message, message_id}, _from, state) do
    case Enum.split_with(state.next_turn_messages, &(&1.id == message_id)) do
      {[_deleted], remaining} ->
        new_state = %{state | next_turn_messages: remaining}

        case Persistence.delete_next_turn(new_state, message_id) do
          {:ok, snapshot_saved?} ->
            new_state =
              if snapshot_saved?, do: mark_snapshot_saved(new_state), else: maybe_save(new_state)

            broadcast_event(state.session_id, :candidate_message_deleted, %{
              message_id: message_id
            })

            {:reply, {:ok, %{deliver_as: :next_turn}}, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {[], _} ->
        case state.queue_pid do
          nil ->
            {:reply, {:error, :not_found}, state}

          queue_pid ->
            case Handbean.Agent.CandidateQueue.delete_message(queue_pid, message_id) do
              {:ok, _count} ->
                broadcast_event(state.session_id, :candidate_message_deleted, %{
                  message_id: message_id
                })

                {:reply, {:ok, %{deliver_as: :steer}}, state}

              {:error, reason} ->
                {:reply, {:error, reason}, state}
            end
        end
    end
  end

  def handle_call(:drain_next_turn, _from, state) do
    new_state = %{state | next_turn_messages: []}
    new_state = maybe_save(new_state)
    {:reply, state.next_turn_messages, new_state}
  end

  def handle_call({:mark_run_finished, run_id}, from, state) do
    if run_id == state.meta.run_id,
      do: handle_call(:mark_run_finished, from, state),
      else: {:reply, {:error, :stale_run}, state}
  end

  def handle_call(:mark_run_finished, _from, state) do
    CandidateMessages.seal(state.queue_pid)

    state =
      if state.meta.pending_model do
        payload = %{
          run_id: state.meta.run_id,
          status: :expired,
          revision: state.meta.model_switch_revision,
          model_ref: state.meta.pending_model[:model_ref],
          model: state.meta.pending_model[:model]
        }

        do_broadcast_event(state, :model_switch_expired, payload, force_save?: true)
      else
        state
      end

    meta = %{
      state.meta
      | running?: false,
        agent_pid: nil,
        queue_pid: nil,
        run_id: nil,
        pending_model: nil,
        model_switch_status: nil
    }

    new_state = %{
      state
      | agent_pid: nil,
        queue_pid: nil,
        latest_usage_event: nil,
        meta: meta
    }

    new_state = maybe_save(new_state)
    Logger.debug("[Session] run finished session=#{state.session_id}")
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_cast({:transition_model_switch, run_id, status, payload}, state) do
    case transition_model_switch_state(state, run_id, status, payload) do
      {:ok, new_state} -> {:noreply, new_state}
      {:error, :stale_run} -> {:noreply, state}
    end
  end

  def handle_cast({:broadcast_event, kind, payload}, state) do
    if stale_run_event?(state, kind, payload) do
      Logger.debug(
        "[Session] dropped stale #{kind} session=#{state.session_id} " <>
          "event_run=#{payload_run_id(payload)} active_run=#{state.meta.run_id}"
      )

      {:noreply, state}
    else
      # Cast path: used for high-frequency events; throttle disk saves to avoid
      # blocking the agent task on slow filesystems.
      force? = kind not in @throttled_snapshot_events
      new_state = do_broadcast_event(state, kind, payload, force_save?: force?)
      {:noreply, new_state}
    end
  end

  def handle_cast({:append, %AgentEvent{} = event}, state) do
    new_events = Enum.take([event | state.events], @max_snapshot_events)

    new_state =
      %{
        state
        | seq: max(state.seq, event.seq),
          events: new_events,
          control_events: append_control(state.control_events, event)
      }
      |> remember_latest_usage(event)

    Persistence.record_event(new_state, event)

    new_state =
      maybe_save_throttled(new_state, force?: event.kind not in @throttled_snapshot_events)

    {:noreply, new_state}
  end

  def handle_cast({:update_meta, key, value}, state) do
    new_state = put_in(state.meta[key], value)
    new_state = maybe_save(new_state)
    {:noreply, new_state}
  end

  def handle_cast({:update_extension_state, extension_name, key, value}, state) do
    new_state =
      put_in(
        state,
        [:extension_state, Access.key(extension_name, %{}), key],
        value
      )

    new_state = maybe_save(new_state)
    {:noreply, new_state}
  end

  def handle_cast({:delete_extension_state, extension_name, key}, state) do
    ext_state =
      case Map.get(state.extension_state, extension_name) do
        nil -> state.extension_state
        inner -> %{state.extension_state | extension_name => Map.delete(inner, key)}
      end

    # Clean up empty extension maps
    ext_state =
      case Map.get(ext_state, extension_name) do
        m when m == %{} -> Map.delete(ext_state, extension_name)
        _ -> ext_state
      end

    new_state = %{state | extension_state: ext_state}
    new_state = maybe_save(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:save_snapshot, save_ref}, %{save_timer: {_timer_ref, save_ref}} = state) do
    {:noreply, maybe_save(%{state | save_timer: nil})}
  end

  def handle_info({:save_snapshot, _save_ref}, state) do
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    cond do
      pid == state.agent_pid ->
        Process.demonitor(ref, [:flush])

        Logger.warning(fn ->
          "[Session] agent process down session=#{state.session_id} reason=#{inspect(reason)}"
        end)

        CandidateMessages.seal(state.queue_pid)
        meta = %{state.meta | running?: false, agent_pid: nil, queue_pid: nil, run_id: nil}

        new_state = %{
          state
          | agent_pid: nil,
            queue_pid: nil,
            latest_usage_event: nil,
            meta: meta
        }

        new_state = maybe_save(new_state)
        {:noreply, new_state}

      pid == state.queue_pid ->
        Process.demonitor(ref, [:flush])
        {:noreply, %{state | queue_pid: nil}}

      true ->
        {:noreply, state}
    end
  end

  # ── Helpers ──

  defp mark_snapshot_saved(state) do
    %{state | last_throttle: System.monotonic_time(:millisecond)}
  end

  defp stale_run_event?(state, _kind, payload) do
    event_run = payload_run_id(payload)
    active_run = state.meta.run_id
    is_binary(event_run) and event_run != active_run
  end

  defp payload_run_id(payload) when is_map(payload) do
    Handbean.Utils.SafeMap.get_any(payload, :run_id, "run_id")
  end

  defp payload_run_id(_payload), do: nil

  defp do_broadcast_event(state, kind, payload, opts) do
    seq = state.seq + 1
    topic = session_topic(state.session_id)
    event = %{AgentEvent.new(topic, kind, payload, seq) | epoch: state.epoch}

    log_broadcast_event(state.session_id, event)
    Phoenix.PubSub.broadcast(Handbean.PubSub, topic, {:agent_event, event})
    maybe_broadcast_run_lifecycle(state.session_id, event)

    new_events = Enum.take([event | state.events], @max_snapshot_events)

    new_state =
      %{
        state
        | seq: seq,
          events: new_events,
          control_events: append_control(state.control_events, event)
      }
      |> remember_latest_usage(event)

    Persistence.record_event(new_state, event)
    maybe_save_throttled(new_state, force?: Keyword.get(opts, :force_save?, true))
  end

  # Streaming text has its own durable owner and must not evict approvals or
  # queue consumption controls needed for reconnect.
  defp append_control(events, %{kind: kind}) when kind in @high_freq_events, do: events

  defp append_control(events, event),
    do: Enum.take([event | events], @max_snapshot_events)

  defp remember_latest_usage(state, %{kind: :usage_updated} = event),
    do: %{state | latest_usage_event: event}

  defp remember_latest_usage(state, _event), do: state

  defp usage_event_for_run(%{payload: payload} = event, run_id) do
    if payload_run_id(payload) == run_id, do: event, else: nil
  end

  defp usage_event_for_run(_event, _run_id), do: nil

  # Read registry metadata, never call Runner from Session init: Runner may be
  # waiting for this Session. Only a still-live, identified run is restored.
  defp restore_active_run(state) do
    id = state.session_id

    with [{pid, %{run_id: run_id, active?: true} = registry_meta}] when is_binary(run_id) <-
           Registry.lookup(Handbean.AgentRunRegistry, id),
         [{queue, _}] <- Registry.lookup(Handbean.AgentRunQueueRegistry, id),
         [{supervisor, _}] <- Registry.lookup(Handbean.AgentRunSupervisorRegistry, id) do
      Process.monitor(pid)
      Process.monitor(queue)

      meta = %{
        state.meta
        | running?: true,
          agent_pid: pid,
          queue_pid: queue,
          run_id: run_id,
          run_supervisor: supervisor,
          model: ModelProjection.registry_model(registry_meta[:model], state.meta.model),
          active_model: ModelProjection.normalize(registry_meta[:model], state.meta.model),
          pending_model: registry_meta[:pending_model],
          model_switch_status: registry_meta[:model_switch_status],
          model_switch_revision:
            registry_meta[:model_switch_revision] || state.meta.model_switch_revision
      }

      %{
        state
        | agent_pid: pid,
          queue_pid: queue,
          model: meta.model,
          latest_usage_event: usage_event_for_run(state.latest_usage_event, run_id),
          meta: meta
      }
    else
      _ -> %{state | latest_usage_event: nil}
    end
  end

  defp transition_model_switch_state(state, run_id, status, payload) do
    if run_id == state.meta.run_id and state.meta.running? do
      event_payload =
        payload
        |> Map.put(:run_id, run_id)
        |> Map.put(:status, status)

      {meta, model} = ModelProjection.transition(state.meta, state.model, status, payload)
      new_state = %{state | meta: meta, model: model}

      {:ok,
       do_broadcast_event(new_state, ModelProjection.event_kind(status), event_payload,
         force_save?: true
       )}
    else
      {:error, :stale_run}
    end
  end

  defp log_broadcast_request(_session_id, :message_delta, %{chunk: chunk})
       when is_binary(chunk) do
    :ok
  end

  defp log_broadcast_request(_session_id, kind, _payload) when kind in @high_freq_events do
    :ok
  end

  defp log_broadcast_request(session_id, kind, _payload) do
    if kind not in [:message_delta, :user_on_chunk] do
      Logger.debug("[Session] broadcast_event request #{kind} session=#{session_id}")
    end
  end

  defp log_broadcast_event(_session_id, %{
         kind: :message_delta,
         seq: _seq,
         payload: %{chunk: chunk}
       })
       when is_binary(chunk) do
    :ok
  end

  defp log_broadcast_event(_session_id, %{kind: kind}) when kind in @high_freq_events do
    :ok
  end

  defp log_broadcast_event(session_id, %{kind: kind, seq: seq}) do
    Logger.debug("[Session] broadcasting #{kind} session=#{session_id} seq=#{seq}")
  end

  defp maybe_save(state) do
    state = cancel_scheduled_save(state)

    Persistence.save(state)

    %{state | last_throttle: System.monotonic_time(:millisecond)}
  end

  # Skip disk save for high-frequency events unless the throttle window has
  # elapsed. This is the main mitigation against per-chunk fsync stalls on
  # slow filesystems (notably WSL2 -> Windows /mnt/*).
  defp maybe_save_throttled(state, opts) do
    force? = Keyword.get(opts, :force?, true)
    now = System.monotonic_time(:millisecond)
    elapsed = now - (state.last_throttle || 0)

    cond do
      force? ->
        maybe_save(state)

      elapsed >= @save_throttle_ms ->
        maybe_save(state)

      true ->
        schedule_save(state, @save_throttle_ms - elapsed)
    end
  end

  defp schedule_save(%{save_timer: nil} = state, delay) do
    save_ref = make_ref()
    timer_ref = Process.send_after(self(), {:save_snapshot, save_ref}, delay)
    %{state | save_timer: {timer_ref, save_ref}}
  end

  defp schedule_save(state, _delay), do: state

  defp cancel_scheduled_save(%{save_timer: {timer_ref, _save_ref}} = state) do
    Process.cancel_timer(timer_ref)
    %{state | save_timer: nil}
  end

  defp cancel_scheduled_save(state), do: state

  defp maybe_broadcast_run_lifecycle(session_id, %{kind: kind, payload: payload})
       when kind in [
              :run_start,
              :run_resumed,
              :run_end,
              :tool_approval_requested,
              :stall_check_requested
            ] do
    Phoenix.PubSub.broadcast(
      Handbean.PubSub,
      "runtime:runs",
      {:run_lifecycle, session_id, kind, payload}
    )
  end

  defp maybe_broadcast_run_lifecycle(_session_id, _event), do: :ok

  defp via_tuple(session_id), do: {:via, Registry, {Handbean.SessionRegistry, session_id}}
end
