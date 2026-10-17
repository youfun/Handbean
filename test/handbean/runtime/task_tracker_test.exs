defmodule Handbean.Runtime.TaskTrackerTest do
  use Handbean.DataCase, async: false

  alias Handbean.PubSub.Session
  alias Handbean.Runtime.NotifyAdapter
  alias Handbean.Runtime.TaskTracker

  defmodule CaptureAdapter do
    @behaviour NotifyAdapter

    @impl true
    def app_visible?, do: Application.get_env(:handbean, :runtime_notify_visible, false)

    @impl true
    def apply(action) do
      case Process.whereis(:runtime_notify_capture) do
        pid when is_pid(pid) -> send(pid, {:notify_action, action})
        _ -> :ok
      end
    end
  end

  setup do
    Process.register(self(), :runtime_notify_capture)
    previous = Application.get_env(:handbean, :runtime_notify_adapter)
    Application.put_env(:handbean, :runtime_notify_adapter, CaptureAdapter)
    Application.put_env(:handbean, :runtime_notify_visible, false)
    TaskTracker.reset()

    on_exit(fn ->
      if previous,
        do: Application.put_env(:handbean, :runtime_notify_adapter, previous),
        else: Application.delete_env(:handbean, :runtime_notify_adapter)

      Application.delete_env(:handbean, :runtime_notify_visible)
      TaskTracker.reset()
    end)

    :ok
  end

  test "follow-up stays one task until the runner actually finishes" do
    sid = "task-follow-#{System.unique_integer([:positive])}"
    {:ok, _} = Session.start_or_get(session_id: sid, model: "fake")
    {:ok, queue} = Handbean.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
    :ok = Session.attach_run(sid, self(), queue, run_id: "run-1")

    Session.broadcast_event(sid, :run_start, %{model: "fake"})

    assert_receive {:notify_action, {:update_running, %{running_count: 1, waiting_count: 0}}},
                   500

    Session.broadcast_event(sid, :run_end, %{status: "interrupted", turns: 1})

    assert_receive {:notify_action, {:update_running, %{running_count: 0, waiting_count: 1}}},
                   500

    refute_received {:notify_action, {:system_ended, _, _}}

    Session.broadcast_event(sid, :run_end, %{status: "completed", turns: 2})
    assert_receive {:notify_action, {:update_running, %{running_count: 0, waiting_count: 0}}}, 500
    assert_receive {:notify_action, {:system_ended, task, :completed}}, 500
    assert task.conversation_id == sid
    assert task.run_id == "run-1"
  end

  test "mark_run_finished does not emit a second completion" do
    sid = "task-finish-#{System.unique_integer([:positive])}"
    {:ok, _} = Session.start_or_get(session_id: sid, model: "fake")
    {:ok, queue} = Handbean.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
    :ok = Session.attach_run(sid, self(), queue, run_id: "run-2")

    Session.broadcast_event(sid, :run_start, %{model: "fake"})
    assert_receive {:notify_action, {:update_running, %{running_count: 1}}}

    Session.broadcast_event(sid, :run_end, %{status: "completed", turns: 1})
    assert_receive {:notify_action, {:system_ended, _, :completed}}
    flush_notify()

    Session.mark_run_finished(sid)
    refute_receive {:notify_action, {:system_ended, _, _}}, 50
  end

  test "viewing the conversation suppresses the system completion" do
    sid = "task-view-#{System.unique_integer([:positive])}"
    Application.put_env(:handbean, :runtime_notify_visible, true)
    TaskTracker.viewing(self(), sid)

    {:ok, _} = Session.start_or_get(session_id: sid, model: "fake")
    {:ok, queue} = Handbean.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
    :ok = Session.attach_run(sid, self(), queue, run_id: "run-3")
    Session.broadcast_event(sid, :run_start, %{model: "fake"})
    assert_receive {:notify_action, {:update_running, %{running_count: 1}}}

    Session.broadcast_event(sid, :run_end, %{status: "completed", turns: 1})
    assert_receive {:notify_action, {:update_running, %{running_count: 0}}}
    refute_received {:notify_action, {:system_ended, _, _}}
    refute_received {:notify_action, {:in_app_ended, _, _}}
  end

  defmodule SystemAdapter do
    @behaviour NotifyAdapter

    def app_visible?, do: true
    def prefers_system_notification?, do: true

    def apply(action) do
      case Process.whereis(:runtime_notify_capture) do
        pid when is_pid(pid) -> send(pid, {:notify_action, action})
        _ -> :ok
      end
    end
  end

  test "macOS delivery replaces the page toast with a system notification" do
    sid = "task-mac-#{System.unique_integer([:positive])}"
    Application.put_env(:handbean, :runtime_notify_adapter, SystemAdapter)
    Application.put_env(:handbean, :runtime_notify_visible, true)
    Phoenix.PubSub.subscribe(Handbean.PubSub, "runtime:tasks")

    {:ok, _} = Session.start_or_get(session_id: sid, model: "fake")
    {:ok, queue} = Handbean.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
    :ok = Session.attach_run(sid, self(), queue, run_id: "run-mac")
    Session.broadcast_event(sid, :run_start, %{model: "fake"})
    assert_receive {:notify_action, {:update_running, %{running_count: 1}}}

    Session.broadcast_event(sid, :run_end, %{status: "completed", turns: 1})
    assert_receive {:notify_action, {:system_ended, task, :completed}}
    assert task.conversation_id == sid
    refute_received {:in_app_ended, _, _}
    refute_received {:notify_action, {:in_app_ended, _, _}}
  end

  test "tool events do not update sidebar state or broadcast animation activity" do
    sid = "task-sequence-#{System.unique_integer([:positive])}"
    {:ok, _} = Session.start_or_get(session_id: sid, model: "fake")
    {:ok, queue} = Handbean.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
    :ok = Session.attach_run(sid, self(), queue, run_id: "run-sequence")
    Session.subscribe(sid)
    Phoenix.PubSub.subscribe(Handbean.PubSub, "runtime:runs")
    Phoenix.PubSub.subscribe(Handbean.PubSub, "runtime:activity")
    TaskTracker.subscribe()
    Session.broadcast_event(sid, :run_start, %{})
    assert_receive {:runtime_tasks, %{tasks: [%{status: :running} = task]}}
    refute Map.has_key?(task, :mode)
    refute Map.has_key?(task, :tools)
    flush_notify()

    for tool <- ["read", "grep", "edit", "write", "bash"] do
      Session.broadcast_event(sid, :tool_start, %{tool: tool, tool_use_id: tool})
      Session.broadcast_event(sid, :tool_end, %{tool: tool, tool_use_id: tool})
      Session.snapshot(sid)
      assert_receive {:agent_event, %{kind: :tool_start, payload: %{tool: ^tool}}}
      assert_receive {:agent_event, %{kind: :tool_end, payload: %{tool: ^tool}}}
    end

    assert TaskTracker.snapshot().tasks == [task]
    refute_receive {:runtime_tasks, _}, 30
    refute_received {:tool_lifecycle, _, _, _}
    refute_received {:runtime_activity, _, _}
    refute_received {:notify_action, _}

    Session.broadcast_event(sid, :tool_approval_requested, %{})
    assert_receive {:runtime_tasks, %{tasks: [%{status: :waiting_confirmation}]}}
    Session.broadcast_event(sid, :run_resumed, %{})
    assert_receive {:runtime_tasks, %{tasks: [%{status: :running}]}}
    Session.broadcast_event(sid, :run_end, %{status: "cancelled"})
    assert_receive {:runtime_tasks, %{tasks: []}}
    Handbean.SessionSupervisor.stop_session(sid)
  end

  test "runner DOWN self-heals a task when no terminal event arrives" do
    sid = "task-runner-down-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)
    runner = start_registered_runner(sid, "run-down")

    send(
      Process.whereis(TaskTracker),
      {:run_lifecycle, sid, :run_start, %{run_id: "run-down"}}
    )

    assert_receive {:notify_action, {:update_running, %{running_count: 1}}}, 500
    Process.exit(runner, :kill)
    assert_receive {:notify_action, {:update_running, %{running_count: 0}}}, 500
    assert_receive {:notify_action, {:system_ended, %{run_id: "run-down"}, :failed}}, 500
    assert TaskTracker.snapshot().tasks == []
  end

  test "a stale runner DOWN cannot remove a newer projected run" do
    sid = "task-stale-down-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)
    runner = start_registered_runner(sid, "run-old")
    tracker = Process.whereis(TaskTracker)

    send(tracker, {:run_lifecycle, sid, :run_start, %{run_id: "run-old"}})
    assert_receive {:notify_action, {:update_running, %{running_count: 1}}}, 500

    %{run_monitors: %{^sid => %{ref: old_ref}}} = :sys.get_state(tracker)

    send(tracker, {:run_lifecycle, sid, :run_start, %{run_id: "run-new"}})
    assert_receive {:notify_action, {:update_running, %{running_count: 1}}}, 500
    assert [%{run_id: "run-new"}] = TaskTracker.snapshot().tasks

    send(tracker, {:DOWN, old_ref, :process, runner, :killed})
    assert [%{run_id: "run-new"}] = TaskTracker.snapshot().tasks
    Process.exit(runner, :kill)
  end

  defp start_registered_runner(conversation_id, run_id) do
    parent = self()

    pid =
      spawn(fn ->
        {:ok, _} =
          Registry.register(Handbean.AgentRunRegistry, conversation_id, %{
            run_id: run_id,
            active?: true
          })

        send(parent, {:runner_registered, self()})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:runner_registered, ^pid}, 500
    pid
  end

  defp flush_notify do
    receive do
      {:notify_action, _} -> flush_notify()
    after
      20 -> :ok
    end
  end
end
