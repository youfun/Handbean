defmodule Handbean.Agent.RunSupervisorTest do
  use Handbean.DataCase, async: false

  import Handbean.TestSupport.RuntimeLifecycle

  alias Handbean.Agent.Coordinator
  alias Handbean.Agent.CandidateQueue

  setup do
    old_home = System.get_env("HOME")
    home_dir = Path.join(System.tmp_dir!(), "sigil_run_supervisor_home_#{Ecto.UUID.generate()}")
    File.mkdir_p!(home_dir)
    System.put_env("HOME", home_dir)
    {:ok, conversation} = Handbean.ConversationStore.create("default", timeline: [])
    sid = conversation["id"]

    on_exit(fn ->
      try do
        stop_run!(sid)
        drain_terminal_callbacks!()
        sync_runtime_observers!()
      after
        if old_home, do: System.put_env("HOME", old_home), else: System.delete_env("HOME")

        Enum.reduce_while(1..8, :error, fn attempt, _ ->
          case File.rm_rf(home_dir) do
            {:ok, _} ->
              {:halt, :ok}

            {:error, reason, _path} ->
              if attempt == 8, do: raise("failed to remove #{home_dir}: #{inspect(reason)}")
              Process.sleep(25 * attempt)
              {:cont, :error}
          end
        end)
      end
    end)

    %{sid: sid}
  end

  defmodule BlockingProvider do
    @behaviour Handbean.Agent.Provider

    @impl true
    def complete(_messages, _tool_defs, config) do
      send(Map.fetch!(config, :notify), {:run_supervisor_provider_started, self()})

      receive do
        :finish ->
          {:ok, %{stop_reason: :end_turn, messages: [], usage: %{}, response_metadata: %{}}}
      after
        5_000 -> raise "timeout"
      end
    end

    @impl true
    def stream(messages, tool_defs, config, _on_chunk), do: complete(messages, tool_defs, config)
  end

  defp opts(extra \\ []) do
    Keyword.merge(
      [
        workspace_path: File.cwd!(),
        model: "fake-model",
        provider: BlockingProvider,
        provider_config: %{notify: self()},
        tools: [],
        source: :cli,
        streaming: false,
        max_turns: 3
      ],
      extra
    )
  end

  test "queue lifecycle is bound to run and stale queue is sealed after cancel", %{sid: sid} do
    assert {:ok, %{action: :started}} = Coordinator.add_message(sid, "hello", opts())
    assert_receive {:run_supervisor_provider_started, _task_pid}, 2_000
    assert {:ok, %{queue_pid: queue, run_pid: runner}} = Coordinator.status(sid)
    run_ref = Process.monitor(runner)

    assert :ok = CandidateQueue.enqueue(queue, "while running", deliver_as: :steer)
    assert :ok = Coordinator.cancel(sid)
    assert_receive {:DOWN, ^run_ref, :process, ^runner, _reason}, 2_000

    assert_eventually(fn ->
      assert {:error, :sealed} = CandidateQueue.enqueue(queue, "late", deliver_as: :steer)
    end)
  end

  test "same conversation allows at most one active run", %{sid: sid} do
    assert {:ok, %{action: :started, run_pid: runner}} =
             Coordinator.start_run(sid, "one", opts())

    assert_receive {:run_supervisor_provider_started, _task_pid}

    assert {:ok, %{run_supervisor: run_supervisor}} = Coordinator.status(sid)
    assert {:error, :run_in_progress} = Coordinator.start_run(sid, "two", opts())
    stop_run!(sid)
    refute Process.alive?(runner)
    refute Process.alive?(run_supervisor)
  end

  test "completed run releases conversation for a later run", %{sid: sid} do
    assert {:ok, %{action: :started, run_pid: first_runner}} =
             Coordinator.start_run(
               sid,
               "one",
               opts(
                 provider: Handbean.TestSupport.FakeProvider,
                 provider_config: %{scenario: :simple_answer}
               )
             )

    first_ref = Process.monitor(first_runner)
    assert_receive {:DOWN, ^first_ref, :process, ^first_runner, _reason}, 2_000
    assert {:ok, %{running?: false}} = Coordinator.status(sid)

    assert {:ok, %{action: :started, run_pid: second_runner}} =
             Coordinator.start_run(
               sid,
               "two",
               opts(
                 provider: Handbean.TestSupport.FakeProvider,
                 provider_config: %{scenario: :simple_answer}
               )
             )

    second_ref = Process.monitor(second_runner)
    assert_receive {:DOWN, ^second_ref, :process, ^second_runner, _reason}, 2_000
    assert {:ok, %{running?: false}} = Coordinator.status(sid)
  end

  test "a runner crash tears down the significant run tree and local tasks", %{sid: sid} do
    assert {:ok, %{run_pid: runner}} = Coordinator.start_run(sid, "one", opts())
    assert_receive {:run_supervisor_provider_started, task}, 1_000

    assert {:ok, %{run_supervisor: run_supervisor, queue_pid: queue}} = Coordinator.status(sid)

    [{task_supervisor, _}] =
      Registry.lookup(Handbean.AgentRunSupervisorRegistry, {:tasks, sid})

    refs =
      for pid <- [runner, run_supervisor, queue, task_supervisor, task], into: %{} do
        {pid, Process.monitor(pid)}
      end

    Process.exit(runner, :kill)

    Enum.each(refs, fn {pid, ref} ->
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
    end)
  end

  defp assert_eventually(fun, attempts \\ 50)
  defp assert_eventually(fun, 0), do: fun.()

  defp assert_eventually(fun, attempts) do
    fun.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(20)
      assert_eventually(fun, attempts - 1)
  end
end
