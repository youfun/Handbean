defmodule HandbeanWeb.WorkspaceLiveTest do
  use HandbeanWeb.WorkspaceLiveCase

  test "stopping a run tears down its run-local provider task before runtime cleanup" do
    {:ok, conversation} = Handbean.ConversationStore.create("default")
    id = conversation["id"]

    assert {:ok, %{action: :started}} =
             Handbean.Agent.Coordinator.add_message(id, "hold",
               provider: CleanupProvider,
               provider_config: %{notify: self()},
               model: "cleanup-fixture",
               workspace_path: File.cwd!(),
               source: :cli,
               streaming: false,
               tools: []
             )

    assert_receive {:cleanup_provider_waiting, task}, 1_000
    ref = Process.monitor(task)
    :ok = Handbean.AgentRunSupervisor.stop_run(id)
    assert_receive {:DOWN, ^ref, :process, ^task, _}, 1_000
    :ok = stop_test_runtime!(Process.get(:workspace_live_test_tracker))
  end

  test "cleanup waits for queued lifecycle consumers before removing their HOME" do
    {:ok, conversation} = Handbean.ConversationStore.create("default", title: "Cleanup barrier")
    id = conversation["id"]
    {:ok, _session} = Handbean.PubSub.Session.start_or_get(session_id: id)
    consumer = Process.whereis(Handbean.Runtime.TaskTracker)
    tracker = Process.get(:workspace_live_test_tracker)
    :ok = :sys.suspend(consumer)
    :erlang.trace(consumer, true, [:receive])

    try do
      Handbean.PubSub.Session.broadcast_event(id, :run_start, %{run_id: "cleanup-barrier"})
      Handbean.PubSub.Session.snapshot(id)
      cleanup = Task.async(fn -> stop_test_runtime!(tracker) end)

      # The ordinary call is queued behind lifecycle work. A system get_state
      # call would be served while suspended and would not provide this barrier.
      assert_receive {:trace, ^consumer, :receive, {:"$gen_call", _, :snapshot}}, 1_000
      ref = cleanup.ref
      refute_received {^ref, _}
      :ok = :sys.resume(consumer)
      assert :ok = Task.await(cleanup)

      File.rm_rf!(System.get_env("HOME"))
      GenServer.call(Handbean.Runtime.TaskTracker, :snapshot)

      refute File.exists?(System.get_env("HOME"))
    after
      :erlang.trace(consumer, false, [:receive])
      :sys.resume(consumer)
    end
  end

  test "cleanup tolerates a process exiting between the liveness check and stop call" do
    {:ok, pid} = Agent.start(fn -> :waiting end)

    stop_and_wait(pid, fn ->
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
      GenServer.stop(pid)
    end)

    refute Process.alive?(pid)
  end
end
