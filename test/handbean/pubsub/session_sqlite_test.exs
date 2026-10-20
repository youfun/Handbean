defmodule Handbean.PubSub.SessionSQLiteTest do
  use Handbean.DataCase, async: false

  alias Handbean.PubSub.{AgentEvent, Session}

  setup do
    id = "stored-session-#{System.unique_integer([:positive])}"
    {:ok, _conversation} = Handbean.ConversationStore.create("default", id: id)

    on_exit(fn ->
      sync_task_tracker()
      if Session.whereis(id), do: Handbean.SessionSupervisor.stop_session(id)
      sync_task_tracker()
    end)

    %{id: id}
  end

  test "turn bursts are throttled until run_end persists the terminal snapshot", %{id: id} do
    {:ok, pid} =
      Session.start_or_get(session_id: id, model: "fake", session_store_enabled?: true)

    {:ok, queue} = Handbean.Agent.CandidateQueue.start_link(session_id: id, owner: self())
    :ok = Session.attach_run(id, self(), queue, run_id: "run-1")
    Session.broadcast_event(id, :run_start, %{run_id: "run-1", model: "fake"})
    assert %{last_seq: 1} = Session.snapshot(id)

    :sys.replace_state(pid, &%{&1 | last_throttle: System.monotonic_time(:millisecond)})

    for turn <- 1..20 do
      Session.broadcast_event(id, :turn_end, %{
        run_id: "run-1",
        turn: turn,
        status: :completed
      })
    end

    assert %{last_seq: 21} = Session.snapshot(id)
    assert {:ok, %{"seq" => 1}} = Handbean.SessionStore.SQLite.load(id)

    Session.append_event(
      id,
      AgentEvent.new(
        Session.session_topic(id),
        :run_end,
        %{run_id: "run-1", status: :completed, turns: 20},
        22
      )
    )

    assert %{last_seq: 22} = Session.snapshot(id)

    assert {:ok, %{"seq" => 22, "events" => [%{"kind" => "run_end"} | _]}} =
             Handbean.SessionStore.SQLite.load(id)

    assert :ok = Session.mark_run_finished(id, "run-1")
  end

  test "restart restores persisted events and next-turn messages without runtime handles", %{
    id: id
  } do
    {:ok, pid1} =
      Session.start_or_get(session_id: id, model: "fake", session_store_enabled?: true)

    Session.broadcast_event(id, :run_start, %{model: "fake"})
    :ok = Session.enqueue_candidate(id, "remember me", deliver_as: :next_turn)
    assert %{last_seq: 2, epoch: epoch1} = Session.snapshot(id)
    sync_task_tracker()
    :ok = Handbean.SessionSupervisor.stop_session(id)
    refute Process.alive?(pid1)

    {:ok, pid2} =
      Session.start_or_get(session_id: id, model: "fake", session_store_enabled?: true)

    assert pid2 != pid1

    %{
      last_seq: 2,
      events: [
        %AgentEvent{kind: :candidate_message_injected},
        %AgentEvent{kind: :run_start}
      ],
      meta: meta,
      epoch: epoch2
    } = Session.snapshot(id)

    assert epoch2 != epoch1

    assert meta.running? == false
    assert meta.agent_pid == nil
    assert meta.queue_pid == nil

    assert [%Handbean.Agent.Message{role: :user, content: "remember me"}] =
             Session.drain_next_turn(id)
  end

  test "restart restores tool output from transcript without losing control state", %{id: id} do
    run_id = "run-tool-recovery"
    tool_use_id = "tool-recovery"

    output =
      String.duplicate("complete tool output\n", 650) <>
        "api_key=tool-secret password=pass-secret"

    restored_output = Handbean.Log.Redactor.redact(output)

    assert :ok =
             Handbean.Agent.TranscriptPersistence.handle_event(
               id,
               {:tool_start,
                %{
                  run_id: run_id,
                  tool: "read",
                  tool_use_id: tool_use_id,
                  input: %{file_path: "restored.txt"}
                }},
               run_id: run_id
             )

    assert :ok =
             Handbean.Agent.TranscriptPersistence.handle_event(
               id,
               {:tool_end,
                %{
                  run_id: run_id,
                  tool: "read",
                  tool_use_id: tool_use_id,
                  output: output
                }},
               run_id: run_id
             )

    {:ok, pid1} =
      Session.start_or_get(session_id: id, model: "fake", session_store_enabled?: true)

    {:ok, queue} = Handbean.Agent.CandidateQueue.start_link(session_id: id, owner: self())
    :ok = Session.attach_run(id, self(), queue, run_id: run_id)

    Session.broadcast_event(id, :run_start, %{run_id: run_id, model: "fake"})

    Session.broadcast_event(id, :tool_start, %{
      run_id: run_id,
      tool: "read",
      tool_use_id: tool_use_id,
      input: %{file_path: "restored.txt"}
    })

    Session.broadcast_event(id, :tool_end, %{
      run_id: run_id,
      tool: "read",
      tool_use_id: tool_use_id,
      output: output
    })

    Session.broadcast_event(id, :tool_start, %{
      run_id: run_id,
      tool: "bash",
      tool_use_id: "still-running",
      input: %{command: "pending"}
    })

    Session.broadcast_event(id, :tool_approval_requested, %{
      run_id: run_id,
      action_requests: [%{tool_call_id: "approval", tool_name: "edit"}]
    })

    Session.broadcast_event(id, :candidate_message_injected, %{
      run_id: run_id,
      message_id: "queued-message",
      deliver_as: :steer
    })

    Session.update_extension_state(id, "recovery-test", "checkpoint", "kept")
    :ok = Session.enqueue_candidate(id, "next turn", deliver_as: :next_turn)
    assert %{last_seq: 7} = Session.snapshot(id)

    sync_task_tracker()
    :ok = Handbean.SessionSupervisor.stop_session(id)
    refute Process.alive?(pid1)

    {:ok, _pid2} =
      Session.start_or_get(session_id: id, model: "fake", session_store_enabled?: true)

    snapshot = Session.snapshot(id)
    completed = Enum.find(snapshot.events, &(&1.kind == :tool_end))

    assert completed.payload["tool_use_id"] == tool_use_id
    assert completed.payload["run_id"] == run_id
    assert completed.payload["output"] == restored_output
    refute inspect(snapshot) =~ "tool-secret"
    refute inspect(snapshot) =~ "pass-secret"
    assert snapshot.extension_state == %{"recovery-test" => %{"checkpoint" => "kept"}}

    assert Enum.any?(snapshot.control_events, fn event ->
             event.kind == :tool_start and event.payload["tool_use_id"] == "still-running"
           end)

    assert Enum.any?(snapshot.control_events, &(&1.kind == :tool_approval_requested))

    assert Enum.any?(snapshot.control_events, fn event ->
             event.kind == :candidate_message_injected and
               event.payload["message_id"] == "queued-message"
           end)

    assert [%Handbean.Agent.Message{content: "next turn"}] = Session.drain_next_turn(id)
  end

  defp sync_task_tracker do
    case Process.whereis(Handbean.Runtime.TaskTracker) do
      nil -> :ok
      pid -> :sys.get_state(pid)
    end
  end
end
