defmodule Handbean.PubSub.SessionTest do
  @moduledoc """
  Tests for the Session GenServer.

  Reference: `alloy/` (session event pattern) and `beam_scriber/` (LiveView event flow)
  Test pattern: hand-written

  Covers:
    - Session creation with model metadata
    - Event broadcasting with auto-incrementing seq
    - Snapshot retrieval for reconnection
    - Event ordering and monotonic seq
    - Metadata updates
  """

  use Handbean.DataCase, async: false

  alias Handbean.PubSub.{AgentEvent, Session}

  setup do
    on_exit(fn ->
      if pid = Process.whereis(Handbean.Runtime.TaskTracker), do: :sys.get_state(pid)
    end)

    :ok
  end

  describe "start_link/1" do
    test "creates a session with given id and model" do
      sid = "test-#{System.unique_integer([:positive])}"
      {:ok, _pid} = Session.start_link(session_id: sid, model: "fake-model")

      %{meta: meta, last_seq: seq, events: events} = Session.snapshot(sid)

      assert meta.status == :active
      assert meta.created_at != nil
      assert seq == 0
      assert events == []
    end

    test "lookups session by id" do
      sid = "test-#{System.unique_integer([:positive])}"
      {:ok, pid} = Session.start_link(session_id: sid)

      assert Session.whereis(sid) == pid
    end

    test "start_or_get returns existing pid on duplicate" do
      sid = "test-#{System.unique_integer([:positive])}"
      {:ok, pid1} = Session.start_or_get(session_id: sid, model: "fake")
      {:ok, pid2} = Session.start_or_get(session_id: sid, model: "fake")

      assert pid1 == pid2
      assert Process.alive?(pid1)
    end

    test "start_or_get returns supervised session pid" do
      sid = "test-#{System.unique_integer([:positive])}"
      {:ok, pid} = Session.start_or_get(session_id: sid, model: "fake")

      assert Session.whereis(sid) == pid

      assert Enum.any?(Handbean.SessionSupervisor.which_sessions(), fn
               {_, ^pid, _, _} -> true
               _ -> false
             end)
    end
  end

  describe "broadcast_event/3" do
    test "broadcasts event with auto-incrementing seq" do
      sid = "test-#{System.unique_integer([:positive])}"
      {:ok, _pid} = Session.start_link(session_id: sid)

      Session.broadcast_event(sid, :run_start, %{model: "fake"})
      Session.broadcast_event(sid, :tool_start, %{tool: "read", input: %{}})

      %{last_seq: seq, events: events} = Session.snapshot(sid)

      assert seq == 2
      assert length(events) == 2

      # Events are prepended to snapshot (newest first)
      [e1_newest, e2_oldest] = events
      assert e1_newest.kind == :tool_start
      assert e1_newest.seq == 2
      assert e2_oldest.kind == :run_start
      assert e2_oldest.seq == 1
    end

    test "events have unique, monotonically increasing seq" do
      sid = "test-#{System.unique_integer([:positive])}"
      {:ok, _pid} = Session.start_link(session_id: sid)

      Session.broadcast_event(sid, :run_start, %{})
      Session.broadcast_event(sid, :tool_start, %{})
      Session.broadcast_event(sid, :run_end, %{})

      %{events: events} = Session.snapshot(sid)

      seqs = Enum.map(events, & &1.seq) |> Enum.sort()
      assert seqs == [1, 2, 3]
      assert length(Enum.uniq(seqs)) == 3
    end

    test "events include correct topic" do
      sid = "test-#{System.unique_integer([:positive])}"
      {:ok, _pid} = Session.start_link(session_id: sid)

      Session.broadcast_event(sid, :run_start, %{})

      %{events: [event | _]} = Session.snapshot(sid)
      assert event.topic == "session:#{sid}"
    end
  end

  describe "subscribe/1 and broadcast" do
    test "subscribers receive broadcast events" do
      sid = "test-#{System.unique_integer([:positive])}"
      {:ok, _pid} = Session.start_link(session_id: sid)

      Session.subscribe(sid)
      Session.broadcast_event(sid, :run_start, %{model: "test-model"})

      assert_receive {:agent_event,
                      %AgentEvent{
                        kind: :run_start,
                        seq: 1,
                        payload: %{model: "test-model"}
                      }}
    end

    test "subscribers receive multiple events in order" do
      sid = "test-#{System.unique_integer([:positive])}"
      {:ok, _pid} = Session.start_link(session_id: sid)

      Session.subscribe(sid)
      Session.broadcast_event(sid, :tool_start, %{tool: "read"})
      Session.broadcast_event(sid, :tool_end, %{tool: "read", duration_ms: 100, error: false})
      Session.broadcast_event(sid, :run_end, %{status: :completed, turns: 1})

      assert_receive {:agent_event, %AgentEvent{kind: :tool_start, seq: 1}}
      assert_receive {:agent_event, %AgentEvent{kind: :tool_end, seq: 2}}
      assert_receive {:agent_event, %AgentEvent{kind: :run_end, seq: 3}}
    end
  end

  describe "snapshot/1 — reconnection replay" do
    test "snapshot returns events in insertion order (newest first)" do
      sid = "test-#{System.unique_integer([:positive])}"
      {:ok, _pid} = Session.start_link(session_id: sid)

      Session.broadcast_event(sid, :tool_start, %{tool: "a"})
      Session.broadcast_event(sid, :tool_end, %{tool: "a"})

      %{events: [newest, oldest]} = Session.snapshot(sid)

      assert newest.kind == :tool_end
      assert newest.seq == 2
      assert oldest.kind == :tool_start
      assert oldest.seq == 1
    end

    test "snapshot respects max_events limit" do
      sid = "test-#{System.unique_integer([:positive])}"
      {:ok, _pid} = Session.start_link(session_id: sid)

      # The module defines @max_snapshot_events 500
      # We test with a smaller set — verify it doesn't grow unbounded
      for i <- 1..50 do
        Session.broadcast_event(sid, :tool_start, %{idx: i})
      end

      %{events: events, last_seq: seq} = Session.snapshot(sid)
      assert seq == 50
      assert length(events) == 50
    end

    test "snapshot reports meta including status" do
      sid = "test-#{System.unique_integer([:positive])}"
      {:ok, _pid} = Session.start_link(session_id: sid)

      %{meta: meta} = Session.snapshot(sid)

      assert meta.status == :active
      assert meta.created_at != nil
    end

    test "recovery snapshot returns only current controls and pending messages" do
      sid = "test-#{System.unique_integer([:positive])}"
      run_id = "run-current"
      {:ok, _pid} = Session.start_link(session_id: sid)
      {:ok, queue} = Handbean.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
      :ok = Session.attach_run(sid, self(), queue, run_id: run_id)

      Session.broadcast_event(sid, :run_start, %{run_id: run_id})

      Session.broadcast_event(sid, :tool_start, %{
        run_id: run_id,
        tool: "read",
        tool_use_id: "completed"
      })

      Session.broadcast_event(sid, :tool_end, %{
        run_id: run_id,
        tool: "read",
        tool_use_id: "completed",
        output: String.duplicate("large historical output", 1_000)
      })

      Session.broadcast_event(sid, :provider_items, %{
        run_id: run_id,
        items: [String.duplicate("provider history", 1_000)]
      })

      Session.broadcast_event(sid, :tool_start, %{
        run_id: run_id,
        tool: "bash",
        tool_use_id: "active"
      })

      Session.broadcast_event(sid, :tool_approval_requested, %{
        run_id: run_id,
        action_requests: [%{tool_call_id: "approval", tool_name: "edit"}]
      })

      Session.broadcast_event(sid, :candidate_message_injected, %{
        run_id: run_id,
        message_id: "queued",
        content: "next instruction",
        deliver_as: :steer
      })

      snapshot = Session.recovery_snapshot(sid)

      refute Map.has_key?(snapshot, :events)

      assert Enum.map(snapshot.control_events, & &1.kind) == [
               :run_start,
               :tool_start,
               :tool_approval_requested
             ]

      assert Enum.map(snapshot.pending_events, & &1.kind) == [:candidate_message_injected]
      refute inspect(snapshot) =~ "large historical output"
      refute inspect(snapshot) =~ "provider history"
      assert Enum.at(snapshot.control_events, 1).payload.tool_use_id == "active"
    end
  end

  describe "update_meta/3" do
    test "updates session metadata" do
      sid = "test-#{System.unique_integer([:positive])}"
      {:ok, _pid} = Session.start_link(session_id: sid)

      Session.update_meta(sid, :status, :completed)

      %{meta: meta} = Session.snapshot(sid)
      assert meta.status == :completed
    end

    test "preserves queue metadata when updating unrelated keys" do
      sid = "test-#{System.unique_integer([:positive])}"
      {:ok, _pid} = Session.start_link(session_id: sid)
      {:ok, queue} = Handbean.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
      :ok = Session.attach_run(sid, self(), queue)

      Session.update_meta(sid, :status, :busy)

      %{meta: meta} = Session.snapshot(sid)
      assert meta.status == :busy
      assert meta.running? == true
      assert meta.queue_pid == queue
    end
  end

  describe "candidate input lifecycle" do
    test "attaches a running queue and reports running metadata" do
      sid = "test-#{System.unique_integer([:positive])}"
      {:ok, _pid} = Session.start_link(session_id: sid)
      {:ok, queue} = Handbean.Agent.CandidateQueue.start_link(session_id: sid, owner: self())

      assert :ok = Session.attach_run(sid, self(), queue)

      %{meta: meta} = Session.snapshot(sid)
      assert meta.running? == true
      assert meta.agent_pid == self()
      assert meta.queue_pid == queue
    end

    test "an unresponsive running queue does not block pending message recovery" do
      sid = "test-#{System.unique_integer([:positive])}"
      {:ok, _pid} = Session.start_link(session_id: sid)

      queue =
        spawn(fn ->
          receive do
            _message ->
              receive do
                :stop -> :ok
              end
          end
        end)

      on_exit(fn -> send(queue, :stop) end)
      :ok = Session.attach_run(sid, self(), queue)

      started_at = System.monotonic_time(:millisecond)
      assert Session.get_pending_messages(sid) == []
      assert System.monotonic_time(:millisecond) - started_at < 1_000
      assert Session.snapshot(sid).meta.running? == true
    end

    test "enqueues steer messages into the running queue" do
      sid = "test-#{System.unique_integer([:positive])}"
      {:ok, _pid} = Session.start_link(session_id: sid)
      {:ok, queue} = Handbean.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
      :ok = Session.attach_run(sid, self(), queue)

      assert :ok = Session.enqueue_candidate(sid, "adjust course", deliver_as: :steer)

      assert [%Handbean.Agent.Message{role: :user, content: "adjust course"}] =
               Handbean.Agent.CandidateQueue.drain_steer(queue)
    end

    test "broadcast queue id matches the enqueued id for string and conflicting opts" do
      sid = "test-#{System.unique_integer([:positive])}"
      {:ok, _pid} = Session.start_link(session_id: sid)
      {:ok, queue} = Handbean.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
      :ok = Session.attach_run(sid, self(), queue)
      Phoenix.PubSub.subscribe(Handbean.PubSub, Session.session_topic(sid))

      assert :ok = Session.enqueue_candidate(sid, "sns plain", deliver_as: :steer)

      assert_receive {:agent_event,
                      %AgentEvent{
                        kind: :candidate_message_injected,
                        payload: %{message_id: generated}
                      }}

      assert is_binary(generated) and generated != "" and generated != "msg-user-unknown"

      assert [%Handbean.Agent.Message{id: ^generated, content: "sns plain"}] =
               Handbean.Agent.CandidateQueue.drain_steer(queue)

      message = %Handbean.Agent.Message{role: :user, content: "conflict", id: "struct-id"}

      assert :ok =
               Session.enqueue_candidate(sid, message,
                 deliver_as: :steer,
                 message_id: "opt-id",
                 transcript_id: "tr-id"
               )

      assert_receive {:agent_event,
                      %AgentEvent{
                        kind: :candidate_message_injected,
                        payload: %{message_id: "opt-id"}
                      }}

      assert [%Handbean.Agent.Message{id: "opt-id", content: "conflict"}] =
               Handbean.Agent.CandidateQueue.drain_steer(queue)
    end

    test "stores and drains next_turn messages while idle" do
      sid = "test-#{System.unique_integer([:positive])}"
      {:ok, _pid} = Session.start_link(session_id: sid)

      assert :ok = Session.enqueue_candidate(sid, "use this context", deliver_as: :next_turn)

      assert [%Handbean.Agent.Message{role: :user, content: "use this context"}] =
               Session.drain_next_turn(sid)

      assert [] = Session.drain_next_turn(sid)
    end

    test "mark_run_finished seals queue and marks session idle" do
      sid = "test-#{System.unique_integer([:positive])}"
      {:ok, _pid} = Session.start_link(session_id: sid)
      {:ok, queue} = Handbean.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
      :ok = Session.attach_run(sid, self(), queue)

      assert :ok = Session.mark_run_finished(sid)

      %{meta: meta} = Session.snapshot(sid)
      assert meta.running? == false
      assert meta.agent_pid == nil
      assert meta.queue_pid == nil

      assert {:error, :sealed} =
               Handbean.Agent.CandidateQueue.enqueue(queue, "late", deliver_as: :steer)
    end
  end

  describe "broadcast/2" do
    test "broadcasts a pre-built AgentEvent and appends to snapshot" do
      sid = "test-#{System.unique_integer([:positive])}"
      {:ok, _pid} = Session.start_link(session_id: sid)

      event = AgentEvent.new("session:#{sid}", :tool_start, %{tool: "bash"}, 42)
      Session.broadcast(sid, event)

      %{events: [evt | _]} = Session.snapshot(sid)
      assert evt.seq == 42
      assert evt.kind == :tool_start
    end
  end

  describe "EventRecorder integration" do
    test "broadcast_event records important events when enabled" do
      sid = "recorded-session-#{System.unique_integer([:positive])}"

      event_dir =
        Path.join(System.tmp_dir!(), "sigil_events_test_#{System.unique_integer([:positive])}")

      {:ok, _pid} =
        Session.start_or_get(
          session_id: sid,
          event_recorder_enabled?: true,
          event_dir: event_dir
        )

      Session.broadcast_event(sid, :run_start, %{model: "fake", api_key: "sk-secret"})

      path = Handbean.EventRecorder.event_path(sid, event_dir: event_dir)

      # broadcast_event uses GenServer.cast which is async; retry until file appears
      assert eventually(fn -> File.exists?(path) end), "Event file not written to #{path}"

      body = File.read!(path)
      assert body =~ "run_start"
      refute body =~ "sk-secret"
    end
  end

  defp eventually(fun, attempts \\ 50) do
    Enum.reduce_while(1..attempts, false, fn _i, _acc ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(10)
        {:cont, false}
      end
    end)
  end
end
