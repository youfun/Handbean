defmodule Handbean.Agent.RunnerLifecycleCancelTest do
  use Handbean.DataCase, async: false

  alias Handbean.Agent.Coordinator
  alias Handbean.Agent.TranscriptPersistence
  alias Handbean.PubSub.Session

  setup do
    old_home = System.get_env("HOME")
    home_dir = Path.join(System.tmp_dir!(), "sigil_runner_home_#{Ecto.UUID.generate()}")
    File.mkdir_p!(home_dir)
    System.put_env("HOME", home_dir)
    previous_host = Application.get_env(:handbean, :host)
    Handbean.Host.put!(%{data_dir: home_dir})

    on_exit(fn ->
      drain_runtime_tasks()
      sync_runtime_observers()

      if old_home, do: System.put_env("HOME", old_home), else: System.delete_env("HOME")

      if previous_host,
        do: Application.put_env(:handbean, :host, previous_host),
        else: Application.delete_env(:handbean, :host)

      File.rm_rf(home_dir)
    end)

    :ok
  end

  defp drain_runtime_tasks do
    deadline = System.monotonic_time(:millisecond) + 2_000
    await_runtime_tasks(deadline)
  end

  defp await_runtime_tasks(deadline) do
    tasks = Task.Supervisor.children(Handbean.AgentRunTaskSupervisor)

    if tasks != [] and System.monotonic_time(:millisecond) < deadline do
      refs = Enum.map(tasks, &Process.monitor/1)
      timeout = max(deadline - System.monotonic_time(:millisecond), 0)

      Enum.each(refs, fn ref ->
        receive do
          {:DOWN, ^ref, :process, _pid, _reason} -> :ok
        after
          timeout -> Process.demonitor(ref, [:flush])
        end
      end)

      await_runtime_tasks(deadline)
    end
  end

  defp sync_runtime_observers do
    for name <- [Handbean.Runtime.TaskTracker, Handbean.Schedule.Recorder],
        pid = Process.whereis(name),
        is_pid(pid) do
      :sys.get_state(pid)
    end
  end

  defmodule FailingAssistantStore do
    alias Handbean.ConversationTranscriptStore.ConversationStore, as: Store

    def append(_id, %{"role" => "assistant"}, _opts), do: {:error, :enospc}
    defdelegate append(id, entry, opts), to: Store
    defdelegate update(id, entry_id, patch, opts), to: Store
    defdelegate list(id, opts), to: Store
  end

  defmodule LateProvider do
    @behaviour Handbean.Agent.Provider

    @impl true
    def complete(_messages, _tool_defs, config) do
      send(config.notify, {:late_provider_started, self()})

      receive do
        :finish ->
          {:ok,
           %{
             stop_reason: :end_turn,
             messages: [Handbean.Agent.Message.assistant("late")],
             usage: %{input_tokens: 1, output_tokens: 1}
           }}
      end
    end

    @impl true
    def stream(messages, tools, config, _on_chunk), do: complete(messages, tools, config)
  end

  defmodule BlockingProvider do
    @behaviour Handbean.Agent.Provider

    @impl true
    def complete(_messages, _tool_defs, config) do
      notify = Map.fetch!(config, :notify)
      send(notify, {:blocking_provider_started, self()})

      receive do
        :finish ->
          {:ok,
           %{
             stop_reason: :end_turn,
             messages: [Handbean.Agent.Message.assistant("done")],
             usage: %{input_tokens: 1, output_tokens: 1},
             response_metadata: %{}
           }}
      after
        5_000 ->
          raise "blocking provider timed out"
      end
    end

    @impl true
    def stream(messages, tool_defs, config, _on_chunk), do: complete(messages, tool_defs, config)
  end

  defmodule BlockingMutationTool do
    @behaviour Handbean.Agent.Tool

    def name, do: "blocking_mutation_fixture"
    def description, do: "Waits before a deterministic test mutation"
    def input_schema, do: %{type: "object", properties: %{}}

    def execute(_input, context) do
      send(context.test_pid, {:blocking_mutation_started, self()})

      receive do
        :mutate ->
          File.write!(context.marker, "mutated")
          {:ok, "mutated"}
      end
    end
  end

  defmodule MutationProvider do
    @behaviour Handbean.Agent.Provider

    @impl true
    def complete(messages, _tool_defs, _config) do
      if Enum.any?(messages, &(&1.role == :tool_result)) do
        {:ok,
         %{
           stop_reason: :end_turn,
           messages: [Handbean.Agent.Message.assistant("done")],
           usage: %{input_tokens: 1, output_tokens: 1}
         }}
      else
        {:ok,
         %{
           stop_reason: :tool_use,
           messages: [
             Handbean.Agent.Message.assistant([
               %{
                 type: "tool_use",
                 id: "mutation-1",
                 name: "blocking_mutation_fixture",
                 input: %{}
               }
             ])
           ],
           usage: %{input_tokens: 1, output_tokens: 1}
         }}
      end
    end

    @impl true
    def stream(messages, tool_defs, config, _on_chunk), do: complete(messages, tool_defs, config)
  end

  defmodule UnavailableErrorStore do
    alias Handbean.ConversationTranscriptStore.ConversationStore, as: Store

    def update(_id, "msg-run-error-" <> _run_id, _patch, _opts),
      do: exit({:noproc, {GenServer, :call, [:journal, :update]}})

    defdelegate update(id, entry_id, patch, opts), to: Store
    defdelegate append(id, entry, opts), to: Store
    defdelegate list(id, opts), to: Store
  end

  defmodule CrashProvider do
    @behaviour Handbean.Agent.Provider

    @impl true
    def complete(_messages, _tool_defs, _config), do: raise("runner crash")

    @impl true
    def stream(messages, tool_defs, config, _on_chunk), do: complete(messages, tool_defs, config)
  end

  defmodule CallbackFailureProvider do
    @behaviour Handbean.Agent.Provider

    @impl true
    def complete(_messages, _tools, _config) do
      handler = Handbean.Agent.Provider.SSE.req_stream_handler(%{buffer: ""}, &fail_event/2)

      {:halt, {_, response}} =
        handler.({:data, "data: private-provider-payload\n\n"}, {%{}, %{private: %{}}})

      Handbean.Agent.Provider.OpenAIStream.build_response(response.private.sse_acc)
    end

    defp fail_event(_acc, event), do: raise(ArgumentError, event.data)

    @impl true
    def stream(messages, tools, config, _on_chunk), do: complete(messages, tools, config)
  end

  defmodule OverloadedProvider do
    @behaviour Handbean.Agent.Provider

    @impl true
    def complete(_messages, _tool_defs, _config), do: {:error, :server_is_overloaded}

    @impl true
    def stream(messages, tool_defs, config, _on_chunk), do: complete(messages, tool_defs, config)
  end

  defp opts(extra) do
    Keyword.merge(
      [
        workspace_path: File.cwd!(),
        model: "fake-model",
        provider: Handbean.TestSupport.FakeProvider,
        provider_config: %{scenario: :simple_answer},
        tools: [],
        source: :cli,
        streaming: false,
        max_turns: 3
      ],
      extra
    )
  end

  test "Coordinator.status/1 reports active Runner state" do
    sid = "runner-status-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)

    assert {:ok, %{action: :started, run_pid: runner_pid}} =
             Coordinator.add_message(
               sid,
               "hello",
               opts(provider: BlockingProvider, provider_config: %{notify: self()})
             )

    assert_receive {:blocking_provider_started, _task_pid}, 1_000

    assert {:ok, %{running?: true, status: :running, run_pid: ^runner_pid, queue_pid: queue_pid}} =
             Coordinator.status(sid)

    assert is_pid(queue_pid)
    assert :ok = Coordinator.cancel(sid)
  end

  test "Coordinator.cancel/1 terminates active run and marks session idle" do
    sid = "runner-cancel-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(
               sid,
               "hello",
               opts(provider: BlockingProvider, provider_config: %{notify: self()})
             )

    assert_receive {:blocking_provider_started, _task_pid}, 1_000
    assert :ok = Coordinator.cancel(sid)

    assert_eventually(fn ->
      assert {:ok, %{running?: false}} = Coordinator.status(sid)
    end)
  end

  test "cancel acknowledges completion before scheduling supervisor teardown" do
    {:ok, conversation} = Handbean.ConversationStore.create("default")
    sid = conversation["id"]

    assert {:ok, %{run_pid: runner}} =
             Coordinator.add_message(
               sid,
               "hello",
               opts(provider: BlockingProvider, provider_config: %{notify: self()})
             )

    assert_receive {:blocking_provider_started, _task_pid}, 1_000
    ref = Process.monitor(runner)
    parent = self()
    supervisor = Handbean.AgentRunTaskSupervisor
    :ok = :sys.suspend(supervisor)

    try do
      spawn_link(fn -> send(parent, {:cancel_result, Coordinator.cancel(sid)}) end)
      assert_receive {:cancel_result, :ok}, 1_000
      assert %{meta: %{running?: false}} = Session.snapshot(sid)
    after
      :sys.resume(supervisor)
    end

    assert_receive {:DOWN, ^ref, :process, ^runner, :shutdown}, 1_000
  end

  test "cancel marks durable in-flight tools after task shutdown" do
    {:ok, conversation} = Handbean.ConversationStore.create("default", timeline: [])
    sid = conversation["id"]
    :ok = Session.subscribe(sid)

    assert {:ok, %{action: :started, run_id: run_id}} =
             Coordinator.add_message(
               sid,
               "hello",
               opts(provider: BlockingProvider, provider_config: %{notify: self()})
             )

    assert_receive {:blocking_provider_started, _task_pid}, 1_000

    TranscriptPersistence.handle_event(
      sid,
      {:tool_start, %{tool_use_id: "hold-1", tool: "bash", input: %{command: "sleep"}}},
      run_id: run_id
    )

    assert :ok = Coordinator.cancel(sid)

    tool =
      Enum.find(Handbean.ConversationStore.load_messages(sid), &(&1["id"] == "tool-hold-1"))

    refute Map.has_key?(tool, "status")
    assert tool["tool_status"] == "cancelled"

    cancelled =
      sid
      |> Session.snapshot()
      |> Map.fetch!(:events)
      |> Enum.filter(fn
        %{kind: :run_end, payload: %{status: status}}
        when status in [:cancelled, "cancelled"] ->
          true

        _ ->
          false
      end)

    assert length(cancelled) == 1
  end

  test "cancel does not acknowledge until run-local tool tasks are terminated" do
    sid = "runner-tool-cancel-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)
    marker = Path.join(Handbean.Host.data_dir(), "late-tool-mutation")

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(
               sid,
               "start mutation",
               opts(
                 provider: MutationProvider,
                 tools: [BlockingMutationTool],
                 middleware: [],
                 context: %{test_pid: self(), marker: marker}
               )
             )

    assert_receive {:blocking_mutation_started, tool_task}, 1_000
    tool_ref = Process.monitor(tool_task)

    assert :ok = Coordinator.cancel(sid)
    assert_receive {:DOWN, ^tool_ref, :process, ^tool_task, _reason}, 0

    send(tool_task, :mutate)
    refute File.exists?(marker)
  end

  test "Coordinator.cancel terminates RunElixirScript worker and IO capture" do
    sid = "runner-elixir-script-cancel-#{System.unique_integer([:positive])}"
    workspace = Path.join(Handbean.Host.data_dir(), "run-elixir-cancel-workspace")
    probe = Handbean.Agent.RunnerLifecycleCancelTest.RunElixirCancelProbe
    true = Process.register(self(), probe)
    File.mkdir_p!(workspace)

    File.write!(Path.join(workspace, "cancel.exs"), """
    send(String.to_existing_atom(hd(args)),
      {:run_elixir_script_started, self(), Process.group_leader()})

    receive do
      :finish -> :ok
    end
    """)

    scenario =
      {:script,
       fn _messages, _tool_defs ->
         {:tools,
          [
            %{
              name: "run_elixir_script",
              input: %{
                "path" => "cancel.exs",
                "args" => [Atom.to_string(probe)],
                "timeout_ms" => 30_000
              }
            }
          ]}
       end}

    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(
               sid,
               "run the script",
               opts(
                 workspace_path: workspace,
                 provider_config: %{scenario: scenario},
                 tools: [Handbean.Tool.Builtin.RunElixirScript],
                 middleware: []
               )
             )

    assert_receive {:run_elixir_script_started, worker, io}, 1_000
    worker_ref = Process.monitor(worker)
    io_ref = Process.monitor(io)

    assert :ok = Coordinator.cancel(sid)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 1_000
    assert_receive {:DOWN, ^io_ref, :process, ^io, _reason}, 1_000
    refute Process.alive?(worker)
    refute Process.alive?(io)
  end

  test "task crash broadcasts run_end status error" do
    sid = "runner-crash-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(sid, "boom", opts(provider: CrashProvider))

    assert_eventually(fn ->
      %{events: events} = Session.snapshot(sid)
      assert Enum.any?(events, &match?(%{kind: :run_end, payload: %{status: "error"}}, &1))
    end)

    assert [_, %{"role" => "system", "content" => content}] =
             Handbean.ConversationStore.load_messages(sid)

    assert content =~ "runner crash"
  end

  test "SSE callback failures reach ErrorTracker once with the original safe stack" do
    previous = Application.get_env(:error_tracker, :enabled)
    Application.put_env(:error_tracker, :enabled, true)
    on_exit(fn -> Application.put_env(:error_tracker, :enabled, previous) end)

    sid = "runner-sse-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)
    :ok = Session.subscribe(sid)

    assert {:ok, %{action: :started, run_pid: runner}} =
             Coordinator.add_message(
               sid,
               "trigger callback failure",
               opts(provider: CallbackFailureProvider)
             )

    monitor = Process.monitor(runner)
    assert_receive {:DOWN, ^monitor, :process, ^runner, _}, 1_000
    assert_receive {:agent_event, %{kind: :run_end} = event}, 1_000
    assert event.payload.error == "sse_event_handler failed (ArgumentError)"
    refute inspect(event) =~ "private-provider-payload"
    refute inspect(Handbean.ConversationStore.load_messages(sid)) =~ "private-provider-payload"
    assert [error] = Handbean.Repo.all(ErrorTracker.Error)
    assert error.reason =~ "sse_event_handler"
    assert error.reason =~ "ArgumentError"
    assert [occurrence] = Handbean.Repo.all(ErrorTracker.Occurrence)
    assert occurrence.context["conversation_id"] == sid
    assert occurrence.context["failure_class"] == "exception"
    assert inspect(occurrence.stacktrace) =~ "fail_event"
    refute inspect({error, occurrence}) =~ "private-provider-payload"
  end

  test "provider return errors are recorded with gateway context" do
    previous = Application.get_env(:error_tracker, :enabled)
    Application.put_env(:error_tracker, :enabled, true)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:error_tracker, :enabled),
        else: Application.put_env(:error_tracker, :enabled, previous)
    end)

    sid = "runner-overloaded-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(
               sid,
               "overload",
               opts(
                 provider: OverloadedProvider,
                 provider_config: %{
                   provider: "test-gateway",
                   base_url: "https://gateway.test/v1"
                 }
               )
             )

    assert_eventually(fn ->
      assert [%ErrorTracker.Error{reason: reason}] = Handbean.Repo.all(ErrorTracker.Error)
      assert reason =~ "server_is_overloaded"

      assert [%ErrorTracker.Occurrence{context: context}] =
               Handbean.Repo.all(ErrorTracker.Occurrence)

      assert context["failure_class"] == "provider_overloaded"
      assert context["gateway_host"] == "gateway.test"
      assert context["provider"] == "test-gateway"
      assert context["conversation_id"] == sid
    end)
  end

  test "assistant persistence failure ends the run as error, never completed" do
    sid = "runner-persistence-error-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)
    :ok = Session.subscribe(sid)

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(sid, "hello", opts(transcript_store: FailingAssistantStore))

    assert_receive {:agent_event, %{kind: :run_end, payload: %{status: "error", error: reason}}},
                   1_000

    assert reason =~ "Assistant transcript persistence failed"
    assert reason =~ "enospc"
    %{events: events} = Session.snapshot(sid)
    refute Enum.any?(events, &match?(%{kind: :run_end, payload: %{status: :completed}}, &1))

    assert [
             %{"role" => "user", "content" => "hello"},
             %{"role" => "system", "content" => content}
           ] =
             Handbean.ConversationStore.load_messages(sid)

    assert content =~ "enospc"
  end

  test "a crashed runner is not restarted with the original input" do
    sid = "runner-no-replay-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)
    counter = :counters.new(1, [])

    provider =
      Module.concat(__MODULE__, "CountingProvider#{System.unique_integer([:positive])}")

    defmodule provider do
      @behaviour Handbean.Agent.Provider

      def complete(_messages, _tool_defs, config) do
        :counters.add(config.counter, 1, 1)
        send(config.notify, {:provider_entered, :counters.get(config.counter, 1)})
        Process.sleep(5_000)
        {:ok, %{messages: [], stop_reason: :end_turn, usage: %{}}}
      end

      def stream(messages, tool_defs, config, _on_chunk),
        do: complete(messages, tool_defs, config)
    end

    assert {:ok, %{run_pid: runner}} =
             Coordinator.add_message(
               sid,
               "side effect",
               opts(provider: provider, provider_config: %{counter: counter, notify: self()})
             )

    assert_receive {:provider_entered, 1}, 1_000
    ref = Process.monitor(runner)
    Process.exit(runner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^runner, :killed}, 1_000
    refute_receive {:provider_entered, 2}, 200
    assert :counters.get(counter, 1) == 1
    assert {:error, :not_found} = Handbean.Agent.Runner.status(sid)
  end

  test "the same request id through Coordinator delivers the side effect once" do
    sid = "runner-idem-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)
    parent = self()
    counter = :counters.new(1, [])

    provider =
      Module.concat(__MODULE__, "OnceProvider#{System.unique_integer([:positive])}")

    defmodule provider do
      @behaviour Handbean.Agent.Provider

      def complete(_messages, _tool_defs, config) do
        :counters.add(config.counter, 1, 1)
        send(config.notify, {:side_effect, :counters.get(config.counter, 1)})

        {:ok,
         %{
           stop_reason: :end_turn,
           messages: [Handbean.Agent.Message.assistant("done")],
           usage: %{input_tokens: 1, output_tokens: 1}
         }}
      end

      def stream(messages, tool_defs, config, _on_chunk),
        do: complete(messages, tool_defs, config)
    end

    run_opts =
      opts(
        provider: provider,
        provider_config: %{counter: counter, notify: parent},
        request_id: "op-once"
      )

    assert {:ok, %{action: :started}} = Coordinator.add_message(sid, "write once", run_opts)

    assert_receive {:side_effect, 1}, 1_000
    assert {:ok, receipt} = Coordinator.add_message(sid, "write once", run_opts)
    assert receipt.action == :started
    assert receipt.replayed == true
    assert receipt.run_id
    refute_receive {:side_effect, 2}, 100
    assert :counters.get(counter, 1) == 1
  end

  test "a late completed from the previous run does not rewrite the next run" do
    sid = "runner-late-completed-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)
    :ok = Session.subscribe(sid)
    release = :counters.new(1, [])

    assert {:ok, %{run_id: first_run}} =
             Coordinator.add_message(
               sid,
               "old",
               opts(
                 provider: LateProvider,
                 provider_config: %{notify: self(), release: release}
               )
             )

    assert_receive {:late_provider_started, old_task}, 1_000
    Process.exit(old_task, :kill)

    assert_eventually(fn ->
      %{events: events} = Session.snapshot(sid)

      assert Enum.any?(
               events,
               &match?(%{kind: :run_end, payload: %{status: "error", run_id: ^first_run}}, &1)
             )
    end)

    assert {:ok, %{run_id: second_run, run_pid: second_runner}} =
             Coordinator.add_message(
               sid,
               "new",
               opts(provider: BlockingProvider, provider_config: %{notify: self()})
             )

    assert second_run != first_run
    assert_receive {:blocking_provider_started, _new_task}, 1_000
    send(old_task, :finish)

    refute_receive {:agent_event, %{kind: :run_end, payload: %{run_id: ^second_run}}}, 150

    assert {:ok, %{running?: true, run_id: ^second_run}} = Coordinator.status(sid)
    assert Process.alive?(second_runner)
    send(second_runner, :ignore)
    Coordinator.cancel(sid)
  end

  test "unavailable transcript owner during crash closure does not restart Runner" do
    {:ok, conversation} = Handbean.ConversationStore.create("default")
    sid = conversation["id"]
    :ok = Session.subscribe(sid)

    assert {:ok, %{run_pid: runner}} =
             Coordinator.add_message(
               sid,
               "hello",
               opts(
                 provider: BlockingProvider,
                 provider_config: %{notify: self()},
                 transcript_store: UnavailableErrorStore
               )
             )

    assert_receive {:blocking_provider_started, task}, 1_000
    ref = Process.monitor(runner)
    Process.exit(task, :kill)
    assert_receive {:agent_event, %{kind: :run_end, payload: %{status: "error"}}}, 1_000
    assert_receive {:DOWN, ^ref, :process, ^runner, :shutdown}, 1_000
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
