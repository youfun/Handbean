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

  test "lifecycle reads one summary and preserves notification metadata" do
    {:ok, conversation} =
      Handbean.ConversationStore.create("default", title: "Summary notification")

    sid = conversation["id"]

    {snapshot, queries} = capture_event_queries(sid, :run_start, %{run_id: "summary-run"})

    assert [task] = snapshot.tasks
    assert task.title == "Summary notification"
    assert task.workspace_id == "default"
    assert task.scope == "workspace"
    assert task.conversation_id == sid
    assert task.run_id == "summary-run"
    assert_received {:notify_action, {:update_running, ^snapshot}}

    {finished, end_queries} =
      capture_event_queries(sid, :run_end, %{run_id: "summary-run", status: "completed"})

    assert finished.tasks == []
    assert_received {:notify_action, {:system_ended, ^task, :completed}}
    assert length(end_queries) == 1

    assert length(queries) == 1,
           "Expected one summary SELECT, got #{length(queries)}: #{inspect(queries)}"
  end

  test "free conversation scope survives through the completion notification" do
    {:ok, conversation} = Handbean.ConversationStore.create_free(title: "Free notification")
    sid = conversation["id"]
    {snapshot, _queries} = capture_event_queries(sid, :run_start, %{run_id: "free-run"})

    assert [%{conversation_id: ^sid, scope: "free", workspace_id: nil} = task] = snapshot.tasks
    assert task.title == "Free notification"

    capture_event_queries(sid, :run_end, %{run_id: "free-run", status: "completed"})
    assert_received {:notify_action, {:system_ended, ^task, :completed}}
  end

  test "internal conversations do not produce task notifications" do
    {:ok, conversation} = Handbean.ConversationStore.create("default", visibility: "internal")

    for kind <- [
          :run_start,
          :tool_approval_requested,
          :stall_check_requested,
          :run_resumed,
          :run_end
        ] do
      {snapshot, queries} =
        capture_event_queries(conversation["id"], kind, %{run_id: "hidden", status: "completed"})

      assert snapshot.tasks == []
      assert length(queries) == 1
      refute_received {:notify_action, _}
    end
  end

  test "persisted internal conversations with non-metadata IDs remain hidden" do
    for sid <- ["n1:internal", "internal-" <> String.duplicate("x", 300)] do
      {:ok, _conversation} =
        Handbean.ConversationStore.create_free(id: sid, visibility: "internal")

      for kind <- [
            :run_start,
            :tool_approval_requested,
            :stall_check_requested,
            :run_resumed,
            :run_end
          ] do
        {snapshot, queries} =
          capture_event_queries(sid, kind, %{run_id: "hidden", status: "completed"})

        assert snapshot.tasks == []
        assert length(queries) == 1
        refute_received {:notify_action, _}
      end
    end
  end

  test "persisted public conversations with non-metadata IDs retain notification metadata" do
    for sid <- ["n1:public", "public-" <> String.duplicate("x", 300)] do
      {:ok, _conversation} =
        Handbean.ConversationStore.create("default", id: sid, title: "Public notification")

      {snapshot, queries} = capture_event_queries(sid, :run_start, %{run_id: sid})
      assert [task] = snapshot.tasks
      assert task.title == "Public notification"
      assert task.workspace_id == "default"
      assert task.conversation_id == sid
      assert length(queries) == 1
      assert_received {:notify_action, {:update_running, ^snapshot}}

      {finished, _queries} =
        capture_event_queries(sid, :run_end, %{run_id: sid, status: "completed"})

      assert finished.tasks == []
      assert_received {:notify_action, {:system_ended, ^task, :completed}}
    end
  end

  test "missing and pending-delete conversations retain metadata-free task tracking" do
    {:ok, deleted} = Handbean.ConversationStore.create("default", visibility: "internal")

    Repo.update_all(from(c in Handbean.Storage.Conversation, where: c.id == ^deleted["id"]),
      set: [status: "pending_delete"]
    )

    for sid <- ["task-missing-#{System.unique_integer([:positive])}", deleted["id"]] do
      {snapshot, _queries} = capture_event_queries(sid, :run_start, %{run_id: sid})

      assert [%{title: nil, workspace_id: nil, scope: nil, conversation_id: ^sid} = task] =
               snapshot.tasks

      capture_event_queries(sid, :run_end, %{run_id: sid, status: "completed"})
      assert_received {:notify_action, {:system_ended, ^task, :completed}}
    end
  end

  test "unavailable storage suppresses lifecycle notifications and recovers" do
    {:ok, conversation} = Handbean.ConversationStore.create("default", visibility: "internal")
    tracker = Process.whereis(TaskTracker)
    parent = self()

    :sys.replace_state(tracker, fn state ->
      send(parent, {:previous_repo, Repo.put_dynamic_repo(:task_tracker_unavailable_repo)})
      state
    end)

    assert_receive {:previous_repo, previous_repo}

    try do
      {snapshot, _queries} =
        capture_event_queries(conversation["id"], :run_start, %{run_id: "unavailable"})

      assert snapshot.tasks == []
      refute_received {:notify_action, _}
      assert Process.alive?(tracker)
    after
      :sys.replace_state(tracker, fn state ->
        Repo.put_dynamic_repo(previous_repo)
        state
      end)
    end

    {snapshot, queries} =
      capture_event_queries("task-recovered-#{System.unique_integer([:positive])}", :run_start, %{
        run_id: "recovered"
      })

    assert [%{run_id: "recovered"}] = snapshot.tasks
    assert length(queries) == 1
  end

  test "stale lifecycle events cannot change a newer projected run" do
    {:ok, conversation} = Handbean.ConversationStore.create("default")
    sid = conversation["id"]
    {snapshot, _queries} = capture_event_queries(sid, :run_start, %{run_id: "new"})
    assert_received {:notify_action, {:update_running, ^snapshot}}

    for {kind, status} <- [tool_approval_requested: nil, run_end: "completed"] do
      {unchanged, queries} = capture_event_queries(sid, kind, %{run_id: "old", status: status})
      assert unchanged == snapshot
      assert length(queries) == 1
      refute_received {:notify_action, _}
    end

    {waiting, _queries} = capture_event_queries(sid, :tool_approval_requested, %{run_id: "new"})
    assert [%{status: :waiting_confirmation}] = waiting.tasks
    assert_received {:notify_action, {:update_running, ^waiting}}

    {unchanged, queries} = capture_event_queries(sid, :run_resumed, %{run_id: "old"})
    assert unchanged == waiting
    assert length(queries) == 1
    refute_received {:notify_action, _}

    {resumed, _queries} = capture_event_queries(sid, :run_resumed, %{run_id: "new"})
    assert resumed == snapshot
    assert_received {:notify_action, {:update_running, ^resumed}}
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

  test "switching viewed conversations reuses a single viewer monitor and cleans up on exit" do
    tracker = Process.whereis(TaskTracker)
    parent = self()

    viewer =
      spawn(fn ->
        for index <- 1..5 do
          TaskTracker.viewing(self(), "conv-#{index}")
        end

        send(parent, :viewer_switched)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :viewer_switched, 500
    _ = TaskTracker.snapshot()

    state = :sys.get_state(tracker)
    assert state.viewers[viewer] == "conv-5"
    assert is_reference(state.viewer_monitors[viewer])
    assert {:monitors, monitors} = Process.info(tracker, :monitors)
    assert Enum.count(monitors, fn {:process, pid} -> pid == viewer end) == 1

    send(viewer, :stop)
    ref = Process.monitor(viewer)
    assert_receive {:DOWN, ^ref, :process, ^viewer, :normal}, 500
    _ = TaskTracker.snapshot()

    state = :sys.get_state(tracker)
    refute Map.has_key?(state.viewers, viewer)
    refute Map.has_key?(state.viewer_monitors, viewer)
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

  test "browser pushes follow normalized transitions independently of the native foreground" do
    Phoenix.PubSub.subscribe(Handbean.PubSub, "runtime:web_push")
    Application.put_env(:handbean, :runtime_notify_visible, true)
    {:ok, conversation} = Handbean.ConversationStore.create_free()
    sid = conversation["id"]
    TaskTracker.viewing(self(), sid)

    capture_event_queries(sid, :run_start, %{run_id: "push-run"})
    assert_received {:web_push_event, {:started, %{run_id: "push-run"}}}

    for kind <- [:tool_approval_requested, :stall_check_requested, :tool_approval_requested] do
      capture_event_queries(sid, kind, %{run_id: "push-run"})
    end

    assert_received {:web_push_event, {:waiting, %{run_id: "push-run"}}}
    refute_received {:web_push_event, {:waiting, _}}

    capture_event_queries(sid, :run_resumed, %{run_id: "push-run"})
    assert_received {:web_push_event, {:started, %{run_id: "push-run"}}}
    capture_event_queries(sid, :tool_approval_requested, %{run_id: "push-run"})
    assert_received {:web_push_event, {:waiting, %{run_id: "push-run"}}}

    capture_event_queries(sid, :run_end, %{run_id: "push-run", status: "completed"})
    assert_received {:web_push_event, {:ended, %{run_id: "push-run"}, :completed}}
    refute_received {:notify_action, {:system_ended, _, _}}
    refute_received {:notify_action, {:in_app_ended, _, _}}

    capture_event_queries(sid, :run_end, %{run_id: "push-run", status: "completed"})
    refute_received {:web_push_event, _}
  end

  test "browser pushes omit internal and stale runs but publish cancellation to invalidate waiting" do
    Phoenix.PubSub.subscribe(Handbean.PubSub, "runtime:web_push")
    {:ok, hidden} = Handbean.ConversationStore.create_free(visibility: "internal")
    capture_event_queries(hidden["id"], :run_start, %{run_id: "hidden"})
    capture_event_queries(hidden["id"], :run_end, %{run_id: "hidden", status: "completed"})
    refute_received {:web_push_event, _}

    {:ok, conversation} = Handbean.ConversationStore.create_free()
    sid = conversation["id"]
    capture_event_queries(sid, :run_start, %{run_id: "current"})
    assert_received {:web_push_event, {:started, _}}
    capture_event_queries(sid, :run_end, %{run_id: "old", status: "completed"})
    refute_received {:web_push_event, _}
    capture_event_queries(sid, :tool_approval_requested, %{run_id: "current"})
    assert_received {:web_push_event, {:waiting, _}}
    capture_event_queries(sid, :run_end, %{run_id: "current", status: "cancelled"})
    assert_received {:web_push_event, {:ended, %{run_id: "current"}, :cancelled}}
  end

  def capture_tracker_query(_event, _measurements, metadata, {tracker, recipient, ref}) do
    if self() == tracker and String.starts_with?(metadata.query, "SELECT") do
      send(recipient, {ref, metadata.query})
    end
  end

  defp capture_event_queries(sid, kind, payload) do
    tracker = Process.whereis(TaskTracker)
    ref = make_ref()
    handler = {__MODULE__, ref}

    :ok =
      :telemetry.attach(
        handler,
        [:handbean, :repo, :query],
        &__MODULE__.capture_tracker_query/4,
        {tracker, self(), ref}
      )

    try do
      send(tracker, {:run_lifecycle, sid, kind, payload})
      snapshot = TaskTracker.snapshot()
      {snapshot, collect_queries(ref)}
    after
      :telemetry.detach(handler)
    end
  end

  defp collect_queries(ref) do
    receive do
      {^ref, query} -> [query | collect_queries(ref)]
    after
      0 -> []
    end
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
