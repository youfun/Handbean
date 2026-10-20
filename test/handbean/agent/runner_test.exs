defmodule Handbean.Agent.RunnerTest do
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

  defmodule FailingTimerStore do
    alias Handbean.ConversationTranscriptStore.ConversationStore, as: Store

    def append(id, entry, opts), do: Store.append(id, entry, opts)
    def list(id, opts), do: Store.list(id, opts)

    def update(id, entry_id, %{"content" => %{"$append" => _delta}} = patch, opts) do
      counter = Keyword.fetch!(opts, :timer_flush_counter)
      :counters.add(counter, 1, 1)
      count = :counters.get(counter, 1)

      if count == 1,
        do: Store.update(id, entry_id, patch, opts),
        else: {:error, :enospc}
    end

    def update(id, entry_id, patch, opts), do: Store.update(id, entry_id, patch, opts)
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

  defmodule ResumeBudgetProvider do
    @behaviour Handbean.Agent.Provider

    @impl true
    def complete(messages, _tool_defs, config) do
      if Enum.any?(messages, &(&1.role == :tool_result)) do
        send(config.notify, {:resumed_deadline, config[:run_deadline]})

        receive do
          :finish -> :ok
        end
      end

      {:ok,
       %{
         stop_reason: :tool_use,
         messages: [
           Handbean.Agent.Message.assistant([
             %{
               type: "tool_use",
               id: "call-1",
               name: "run_elixir_script",
               input: %{"path" => "approval.exs"}
             }
           ])
         ],
         usage: %{input_tokens: 1, output_tokens: 1}
       }}
    end

    @impl true
    def stream(messages, tool_defs, config, _on_chunk), do: complete(messages, tool_defs, config)
  end

  defmodule ApprovalProvider do
    @behaviour Handbean.Agent.Provider

    @impl true
    def complete(_messages, _tool_defs, _config) do
      {:ok,
       %{
         stop_reason: :tool_use,
         messages: [
           Handbean.Agent.Message.assistant([
             %{
               type: "tool_use",
               id: "call-1",
               name: "run_elixir_script",
               input: %{"path" => "approval.exs"}
             }
           ])
         ],
         usage: %{input_tokens: 1, output_tokens: 1}
       }}
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

  defmodule OverloadedProvider do
    @behaviour Handbean.Agent.Provider

    @impl true
    def complete(_messages, _tool_defs, _config), do: {:error, :server_is_overloaded}

    @impl true
    def stream(messages, tool_defs, config, _on_chunk), do: complete(messages, tool_defs, config)
  end

  defmodule StreamingProvider do
    @behaviour Handbean.Agent.Provider

    @impl true
    def complete(_messages, _tool_defs, _config) do
      {:ok,
       %{
         stop_reason: :end_turn,
         messages: [Handbean.Agent.Message.assistant("streamed")],
         usage: %{input_tokens: 1, output_tokens: 1},
         response_metadata: %{}
       }}
    end

    @impl true
    def stream(_messages, _tool_defs, _config, on_chunk) do
      on_chunk.("streamed")

      {:ok,
       %{
         stop_reason: :end_turn,
         messages: [Handbean.Agent.Message.assistant("streamed")],
         usage: %{input_tokens: 1, output_tokens: 1},
         response_metadata: %{}
       }}
    end
  end

  defmodule ControlledStreamingProvider do
    @behaviour Handbean.Agent.Provider

    @impl true
    def complete(_messages, _tool_defs, _config), do: raise("stream/4 expected")

    @impl true
    def stream(_messages, _tool_defs, config, on_chunk) do
      send(config.notify, {:controlled_stream_ready, self()})
      stream_loop(config.notify, on_chunk, config.on_event, [])
    end

    defp stream_loop(notify, on_chunk, on_event, chunks) do
      receive do
        {:emit_chunk, payload} ->
          on_chunk.(payload)
          send(notify, {:chunk_callback_returned, self(), payload})
          stream_loop(notify, on_chunk, on_event, [payload | chunks])

        {:emit_event, event} ->
          on_event.(event)
          send(notify, {:event_callback_returned, self(), event})
          stream_loop(notify, on_chunk, on_event, chunks)

        :kill_stream ->
          Process.exit(self(), :kill)

        :finish_stream ->
          chunks = Enum.reverse(chunks)

          {:ok,
           %{
             stop_reason: :end_turn,
             messages: [assistant_message(chunks)],
             usage: %{input_tokens: 1, output_tokens: 1},
             response_metadata: %{}
           }}
      end
    end

    defp assistant_message(chunks) do
      if Enum.any?(chunks, &is_map/1) do
        blocks =
          Enum.map(chunks, fn chunk ->
            %{
              type: "text",
              text: chunk.text,
              phase: chunk.phase,
              output_index: chunk.output_index
            }
          end)

        Handbean.Agent.Message.assistant(blocks)
      else
        Handbean.Agent.Message.assistant(Enum.join(chunks))
      end
    end
  end

  defmodule RoundTripTool do
    @behaviour Handbean.Agent.Tool

    def name, do: "round_trip_fixture"
    def description, do: "Completes immediately for a streaming multi-turn test"
    def input_schema, do: %{type: "object", properties: %{}}
    def execute(_input, _context), do: {:ok, "round trip complete"}
  end

  defmodule MultiTurnStreamingProvider do
    @behaviour Handbean.Agent.Provider

    @impl true
    def complete(_messages, _tool_defs, _config), do: raise("stream/4 expected")

    @impl true
    def stream(messages, _tool_defs, config, on_chunk) do
      if Enum.any?(messages, &(&1.role == :tool_result)) do
        on_chunk.("second")
        send(config.notify, {:second_turn_chunk_returned, self()})

        receive do
          :finish_second_turn ->
            {:ok,
             %{
               stop_reason: :end_turn,
               messages: [Handbean.Agent.Message.assistant("second")],
               usage: %{input_tokens: 1, output_tokens: 1},
               response_metadata: %{}
             }}
        end
      else
        on_chunk.("first")

        {:ok,
         %{
           stop_reason: :tool_use,
           messages: [
             Handbean.Agent.Message.assistant([
               %{
                 type: "tool_use",
                 id: "round-trip-1",
                 name: "round_trip_fixture",
                 input: %{}
               }
             ])
           ],
           usage: %{input_tokens: 1, output_tokens: 1},
           response_metadata: %{}
         }}
      end
    end
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
    probe = Handbean.Agent.RunnerTest.RunElixirCancelProbe
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

  test "permission mode changes reconcile an already pending approval inside Runner" do
    sid = "runner-policy-reconcile-#{System.unique_integer([:positive])}"
    workspace = default_prompt_workspace()
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)
    :ok = Session.subscribe(sid)

    script = fn messages, _tools ->
      if Enum.any?(messages, &(&1.role == :tool_result)) do
        "completed after policy reconciliation"
      else
        {:tools,
         [
           %{
             name: "run_elixir_script",
             input: %{"path" => "approval.exs"}
           }
         ]}
      end
    end

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(
               sid,
               "approve through policy",
               opts(
                 workspace_path: workspace,
                 provider_config: %{scenario: {:script, script}},
                 tools: [Handbean.Tool.Builtin.RunElixirScript],
                 middleware: [Handbean.Agent.Middleware.ToolGuard]
               )
             )

    assert_receive {:agent_event, %{kind: :tool_approval_requested}}, 1_000

    assert_eventually(fn ->
      assert {:ok, %{status: :awaiting_approval}} = Coordinator.status(sid)
    end)

    assert :ok = Handbean.WorkspaceSettings.update_permission_mode(workspace, :yolo)
    assert_receive {:agent_event, %{kind: :run_resumed}}, 1_000

    assert_receive {:agent_event, %{kind: :run_end, payload: %{status: status}}}
                   when status in [:completed, "completed"],
                   1_000
  end

  test "yolo does not reconcile a per-tool prompt" do
    sid = "runner-explicit-prompt-#{System.unique_integer([:positive])}"
    workspace = approval_workspace()
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)
    :ok = Session.subscribe(sid)

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(
               sid,
               "keep prompting",
               opts(
                 workspace_path: workspace,
                 provider: ApprovalProvider,
                 tools: [Handbean.Tool.Builtin.RunElixirScript],
                 middleware: [Handbean.Agent.Middleware.ToolGuard]
               )
             )

    assert_receive {:agent_event, %{kind: :tool_approval_requested}}, 1_000

    assert_eventually(fn ->
      assert {:ok, %{status: :awaiting_approval}} = Coordinator.status(sid)
    end)

    assert :ok = Handbean.WorkspaceSettings.update_permission_mode(workspace, :yolo)
    refute_receive {:agent_event, %{kind: :run_resumed}}, 100
    assert {:ok, %{status: :awaiting_approval}} = Coordinator.status(sid)
    assert :ok = Coordinator.cancel(sid)
  end

  test "Runner validates run and approval batch identities atomically" do
    sid = "runner-approval-identity-#{System.unique_integer([:positive])}"
    workspace = approval_workspace()
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)
    :ok = Session.subscribe(sid)

    assert {:ok, %{run_id: run_id}} =
             Coordinator.add_message(
               sid,
               "approve",
               opts(
                 workspace_path: workspace,
                 provider: ApprovalProvider,
                 tools: [Handbean.Tool.Builtin.RunElixirScript],
                 middleware: [Handbean.Agent.Middleware.ToolGuard]
               )
             )

    assert_receive {:agent_event, %{kind: :run_end, payload: %{status: initial_status}}}, 1_000
    assert initial_status in [:interrupted, "interrupted"]

    assert_eventually(fn ->
      assert {:ok,
              %{
                status: :awaiting_approval,
                approval_batch_id: batch_id,
                interrupt_data: interrupt_data
              }} = Coordinator.status(sid)

      assert is_binary(batch_id)
      assert interrupt_data.approval_batch_id == batch_id
    end)

    {:ok, %{approval_batch_id: batch_id, run_supervisor: run_supervisor}} =
      Coordinator.status(sid)

    supervisor_ref = Process.monitor(run_supervisor)
    decisions = [%{"tool_call_id" => "call-1", "action" => "deny"}]

    assert {:error, {:run_mismatch, ^run_id}} =
             Handbean.Agent.Runner.cancel(sid, "stale-run")

    assert {:error, :stale_approval} =
             Handbean.Agent.Runner.resume(sid, decisions, run_id, "stale-batch")

    assert {:ok, %{status: :awaiting_approval}} = Coordinator.status(sid)
    assert :ok = Handbean.Agent.Runner.resume(sid, decisions, run_id, batch_id)
    assert_receive {:agent_event, %{kind: :run_resumed}}, 1_000

    assert_eventually(fn ->
      assert {:ok, %{status: :awaiting_approval, approval_batch_id: next_batch_id}} =
               Coordinator.status(sid)

      assert next_batch_id != batch_id
    end)

    assert :ok = Handbean.Agent.Runner.cancel(sid, run_id)
    assert_receive {:DOWN, ^supervisor_ref, :process, ^run_supervisor, _reason}, 1_000
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

  test "interactive approval wait pauses the inactivity watchdog" do
    sid = "runner-approval-deadline-#{System.unique_integer([:positive])}"
    workspace = approval_workspace()
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)
    :ok = Session.subscribe(sid)

    assert {:ok, %{run_pid: runner}} =
             Coordinator.add_message(
               sid,
               "needs approval",
               opts(
                 workspace_path: workspace,
                 timeout_ms: 100,
                 provider: ApprovalProvider,
                 tools: [Handbean.Tool.Builtin.RunElixirScript],
                 middleware: [Handbean.Agent.Middleware.ToolGuard]
               )
             )

    assert_receive {:agent_event, %{kind: :tool_approval_requested}}, 1_000

    assert_eventually(fn ->
      assert {:ok, %{status: :awaiting_approval, deadline: nil}} = Coordinator.status(sid)
    end)

    refute_receive {:agent_event, %{kind: :run_end, payload: %{status: "timeout"}}}, 200
    assert Process.alive?(runner)
    assert :ok = Coordinator.cancel(sid)
  end

  test "resuming an interactive approval starts a fresh inactivity window" do
    sid = "runner-resume-budget-#{System.unique_integer([:positive])}"
    workspace = approval_workspace()
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)
    :ok = Session.subscribe(sid)
    parent = self()

    assert {:ok, %{run_id: run_id}} =
             Coordinator.add_message(
               sid,
               "approve then block",
               opts(
                 workspace_path: workspace,
                 timeout_ms: 300,
                 provider: ResumeBudgetProvider,
                 provider_config: %{notify: parent},
                 tools: [Handbean.Tool.Builtin.RunElixirScript],
                 middleware: [Handbean.Agent.Middleware.ToolGuard]
               )
             )

    assert_receive {:agent_event, %{kind: :tool_approval_requested}}, 1_000

    assert_eventually(fn ->
      assert {:ok, %{deadline: nil, status: :awaiting_approval}} = Coordinator.status(sid)
    end)

    assert :ok =
             Coordinator.resume(sid, [%{"tool_call_id" => "call-1", "action" => "approve"}],
               expected_run_id: run_id
             )

    assert_receive {:resumed_deadline, received_deadline}, 1_000
    assert received_deadline == nil

    assert_receive {:agent_event,
                    %{
                      kind: :run_end,
                      payload: %{status: "timeout", reason: :run_inactivity_timeout}
                    }},
                   1_200

    refute_receive {:agent_event, %{kind: :run_end, payload: %{status: :completed}}}, 50
  end

  test "run timeout kills the bash child started by the tool" do
    sid = "runner-bash-kill-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)
    workspace = Handbean.Host.data_dir()
    shell_file = Path.join(workspace, "tmp-bash-shell-#{System.unique_integer([:positive])}.txt")
    child_file = Path.join(workspace, "tmp-bash-child-#{System.unique_integer([:positive])}.txt")

    provider =
      Module.concat(__MODULE__, "BashHangProvider#{System.unique_integer([:positive])}")

    defmodule provider do
      @behaviour Handbean.Agent.Provider

      def complete(messages, tool_defs, config) do
        if Enum.any?(messages, &(&1.role == :tool_result)) do
          Handbean.Agent.RunnerTest.BlockingProvider.complete(messages, tool_defs, config)
        else
          {:ok,
           %{
             stop_reason: :tool_use,
             messages: [
               Handbean.Agent.Message.assistant([
                 %{
                   type: "tool_use",
                   id: "bash-1",
                   name: "bash",
                   input: %{
                     "command" =>
                       "echo $$ > #{config.shell_file}; sleep 30 & echo $! > #{config.child_file}; wait",
                     "wait_ms" => 100
                   }
                 }
               ])
             ],
             usage: %{input_tokens: 1, output_tokens: 1}
           }}
        end
      end

      def stream(messages, tool_defs, config, _on_chunk),
        do: complete(messages, tool_defs, config)
    end

    :ok = Session.subscribe(sid)

    assert {:ok, _} =
             Coordinator.add_message(
               sid,
               "hang",
               opts(
                 timeout_ms: 1_500,
                 provider: provider,
                 provider_config: %{
                   shell_file: shell_file,
                   child_file: child_file,
                   notify: self()
                 },
                 tools: [Handbean.Tool.Builtin.Bash],
                 middleware: [],
                 workspace_path: workspace,
                 working_directory: workspace
               )
             )

    assert_eventually(fn ->
      assert File.exists?(shell_file) and File.exists?(child_file)
    end)

    {shell_pid, child_pid} = host_process_ids(shell_file, child_file)

    assert_receive {:agent_event,
                    %{
                      kind: :run_end,
                      payload: %{status: "timeout", reason: :run_inactivity_timeout}
                    }},
                   3_000

    assert_eventually(fn ->
      refute alive_os?(shell_pid)
      refute alive_os?(child_pid)
    end)

    File.rm(shell_file)
    File.rm(child_file)
  end

  test "killing the runner cleans the bash process group" do
    sid = "runner-bash-crash-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)
    workspace = Handbean.Host.data_dir()

    shell_file =
      Path.join(workspace, "tmp-bash-crash-shell-#{System.unique_integer([:positive])}.txt")

    child_file =
      Path.join(workspace, "tmp-bash-crash-child-#{System.unique_integer([:positive])}.txt")

    provider = Module.concat(__MODULE__, "CrashBash#{System.unique_integer([:positive])}")

    defmodule provider do
      @behaviour Handbean.Agent.Provider

      def complete(_messages, _tool_defs, config) do
        {:ok,
         %{
           stop_reason: :tool_use,
           messages: [
             Handbean.Agent.Message.assistant([
               %{
                 type: "tool_use",
                 id: "bash-crash",
                 name: "bash",
                 input: %{
                   "command" =>
                     "echo $$ > #{config.shell_file}; sleep 30 & echo $! > #{config.child_file}; wait"
                 }
               }
             ])
           ],
           usage: %{input_tokens: 1, output_tokens: 1}
         }}
      end

      def stream(messages, tool_defs, config, _on_chunk),
        do: complete(messages, tool_defs, config)
    end

    assert {:ok, %{run_pid: runner}} =
             Coordinator.add_message(
               sid,
               "crash owner",
               opts(
                 timeout_ms: 30_000,
                 provider: provider,
                 provider_config: %{shell_file: shell_file, child_file: child_file},
                 tools: [Handbean.Tool.Builtin.Bash],
                 middleware: [],
                 workspace_path: workspace,
                 working_directory: workspace
               )
             )

    assert_eventually(fn ->
      assert File.exists?(shell_file) and File.exists?(child_file)
    end)

    {shell_pid, child_pid} = host_process_ids(shell_file, child_file)
    assert Process.alive?(runner)
    Process.exit(runner, :kill)

    assert_eventually(fn ->
      refute alive_os?(shell_pid)
      refute alive_os?(child_pid)
    end)

    File.rm(shell_file)
    File.rm(child_file)
  end

  test "a finished bash command leaves no child process" do
    sid = "runner-bash-done-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)
    workspace = Handbean.Host.data_dir()
    marker = Path.join(workspace, "tmp-bash-done-#{System.unique_integer([:positive])}.txt")

    provider = Module.concat(__MODULE__, "DoneBash#{System.unique_integer([:positive])}")

    defmodule provider do
      @behaviour Handbean.Agent.Provider

      def complete(messages, _tool_defs, config) do
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
                   id: "bash-done",
                   name: "bash",
                   input: %{"command" => "echo done > #{config.marker}"}
                 }
               ])
             ],
             usage: %{input_tokens: 1, output_tokens: 1}
           }}
        end
      end

      def stream(messages, tool_defs, config, _on_chunk),
        do: complete(messages, tool_defs, config)
    end

    :ok = Session.subscribe(sid)

    assert {:ok, _} =
             Coordinator.add_message(
               sid,
               "finish",
               opts(
                 provider: provider,
                 provider_config: %{marker: marker},
                 tools: [Handbean.Tool.Builtin.Bash],
                 middleware: [],
                 workspace_path: workspace,
                 working_directory: workspace
               )
             )

    assert_receive {:agent_event, %{kind: :run_end, payload: %{status: status}}}, 2_000
    assert status in [:completed, "completed"]
    assert File.read!(marker) == "done\n"
    File.rm(marker)
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

  test "delegated run deadline ends a stuck provider and ignores a late result" do
    sid = "runner-deadline-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)
    :ok = Session.subscribe(sid)
    entered = :counters.new(1, [])

    assert {:ok, %{run_pid: runner}} =
             Coordinator.add_message(
               sid,
               "stuck",
               opts(
                 timeout_ms: 50,
                 delegated?: true,
                 provider: BlockingProvider,
                 provider_config: %{notify: self(), counter: entered}
               )
             )

    assert_receive {:agent_event,
                    %{kind: :run_end, payload: %{status: "timeout", reason: :run_timeout}}},
                   1_000

    refute_receive {:agent_event, %{kind: :run_end, payload: %{status: :completed}}}, 100
    refute Process.alive?(runner)
    assert {:error, :not_found} = Handbean.Agent.Runner.status(sid)
    _ = entered
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

  test "streaming coordinator run broadcasts message_delta into session" do
    sid = "runner-streaming-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(
               sid,
               "hello",
               opts(provider: StreamingProvider, provider_config: %{}, streaming: true)
             )

    assert_eventually(fn ->
      %{events: events} = Session.snapshot(sid)

      assert Enum.any?(
               events,
               &match?(%{kind: :message_delta, payload: %{chunk: "streamed"}}, &1)
             )

      assert Enum.any?(events, &match?(%{kind: :run_end}, &1))
    end)
  end

  test "stream persistence commits the first chunk immediately and flushes a quiet batch" do
    {sid, provider} = start_controlled_stream(stream_flush_ms: 20)

    emit_chunk(provider, "你")

    assert_receive {:agent_event, %{kind: :message_delta, payload: %{text: "你", text_offset: 0}}},
                   1_000

    assert [%{"role" => "user"}, %{"content" => "你"}] =
             Handbean.ConversationStore.load_messages(sid)

    emit_chunk(provider, "好")
    refute_receive {:agent_event, %{kind: :message_delta, payload: %{text: "好"}}}, 0

    assert_receive {:agent_event, %{kind: :message_delta, payload: %{text: "好", text_offset: 3}}},
                   1_000

    assert [%{"role" => "user"}, %{"content" => "你好"}] =
             Handbean.ConversationStore.load_messages(sid)

    finish_stream(provider)
  end

  test "stream persistence flushes at the byte bound without waiting for its timer" do
    {sid, provider} = start_controlled_stream(stream_flush_bytes: 6, stream_flush_ms: 5_000)

    emit_chunk(provider, "a")
    assert_receive {:agent_event, %{kind: :message_delta, payload: %{text: "a"}}}, 1_000

    emit_chunk(provider, "你好")

    assert_receive {:agent_event,
                    %{kind: :message_delta, payload: %{text: "你好", text_offset: 1}}},
                   1_000

    assert [%{"role" => "user"}, %{"content" => "a你好"}] =
             Handbean.ConversationStore.load_messages(sid)

    finish_stream(provider)
  end

  test "rich message deltas bypass text batching without losing metadata" do
    {sid, provider} = start_controlled_stream(stream_flush_ms: 5_000)

    emit_chunk(provider, "saved")
    assert_receive {:agent_event, %{kind: :message_delta, payload: %{text: "saved"}}}, 1_000

    emit_provider_event(provider, {:message_delta, %{"chunk" => " pending"}})

    provider_items = [%{type: "reasoning", id: "reasoning-1"}]

    emit_provider_event(
      provider,
      {:message_delta,
       %{
         chunk: " rich",
         thinking: "private reasoning",
         provider_items: provider_items
       }}
    )

    assert_receive {:agent_event, %{kind: :message_delta, payload: %{text: " pending"}}}, 1_000

    assert_receive {:agent_event,
                    %{
                      kind: :message_delta,
                      payload: %{
                        text: " rich",
                        thinking: "private reasoning",
                        provider_items: ^provider_items
                      }
                    }},
                   1_000

    emit_provider_event(
      provider,
      {:message_delta, %{chunk: "", thinking_delta: "more private reasoning"}}
    )

    assert_receive {:agent_event,
                    %{
                      kind: :message_delta,
                      payload: %{chunk: "", thinking_delta: "more private reasoning"} = payload
                    }},
                   1_000

    refute Map.has_key?(payload, :text)

    assert [%{"role" => "user"}, %{"content" => "saved pending rich"}] =
             Handbean.ConversationStore.load_messages(sid)
  end

  test "the first visible chunk of a later tool turn commits immediately" do
    sid = "runner-multi-turn-stream-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)
    :ok = Session.subscribe(sid)

    assert {:ok, %{action: :started, run_pid: runner}} =
             Coordinator.add_message(
               sid,
               "use a tool",
               opts(
                 provider: MultiTurnStreamingProvider,
                 provider_config: %{notify: self()},
                 tools: [RoundTripTool],
                 streaming: true,
                 stream_flush_ms: 5_000,
                 source: :web
               )
             )

    assert_receive {:agent_event, %{kind: :message_delta, payload: %{text: "first"}}}, 1_000
    assert_receive {:second_turn_chunk_returned, provider}, 1_000

    assert_receive {:agent_event, %{kind: :message_delta, payload: %{text: "second"}}}, 1_000

    runner_ref = Process.monitor(runner)
    send(provider, :finish_second_turn)
    assert_receive {:agent_event, %{kind: :run_end, payload: %{status: :completed}}}, 1_000
    assert_receive {:DOWN, ^runner_ref, :process, ^runner, :shutdown}, 1_000
  end

  test "phase and output index changes each drain the preceding stream segment" do
    {sid, provider} = start_controlled_stream(stream_flush_ms: 5_000)

    emit_chunk(provider, %{text: "a", phase: "commentary", output_index: 0})

    assert_receive {:agent_event,
                    %{
                      kind: :message_delta,
                      payload: %{
                        text: "a",
                        phase: "commentary",
                        output_index: 0,
                        text_offset: 0
                      }
                    }},
                   1_000

    emit_chunk(provider, %{text: "b", phase: "commentary", output_index: 0})
    emit_chunk(provider, %{text: "c", phase: "final_answer", output_index: 0})

    assert_receive {:agent_event,
                    %{
                      kind: :message_delta,
                      payload: %{
                        text: "b",
                        phase: "commentary",
                        output_index: 0,
                        text_offset: 1
                      }
                    }},
                   1_000

    assert_receive {:agent_event,
                    %{
                      kind: :message_delta,
                      payload: %{
                        text: "c",
                        phase: "final_answer",
                        output_index: 0,
                        text_offset: 0
                      }
                    }},
                   1_000

    emit_chunk(provider, %{text: "d", phase: "final_answer", output_index: 1})
    refute_receive {:agent_event, %{kind: :message_delta, payload: %{text: "d"}}}, 0

    send(provider, :finish_stream)

    assert_receive {:agent_event,
                    %{
                      kind: :message_delta,
                      payload: %{
                        text: "d",
                        phase: "final_answer",
                        output_index: 1,
                        text_offset: 0
                      }
                    }},
                   1_000

    assert_receive {:agent_event, %{kind: :run_end}}, 1_000

    assert [
             %{"role" => "user"},
             %{"content" => "ab", "phase" => "commentary"},
             %{"content" => "c", "phase" => "final_answer"},
             %{"content" => "d", "phase" => "final_answer"}
           ] = Handbean.ConversationStore.load_messages(sid)
  end

  test "cancellation flushes an accepted stream batch before its terminal event" do
    {sid, provider} = start_controlled_stream(stream_flush_ms: 5_000)

    emit_chunk(provider, "saved")
    assert_receive {:agent_event, %{kind: :message_delta, payload: %{text: "saved"}}}, 1_000

    emit_chunk(provider, " pending")
    assert :ok = Coordinator.cancel(sid)
    assert_receive {:agent_event, %{kind: :message_delta, payload: %{text: " pending"}}}, 1_000
    assert_receive {:agent_event, %{kind: :run_end, payload: %{status: "cancelled"}}}, 1_000

    assert [%{"role" => "user"}, %{"content" => "saved pending", "status" => "cancelled"}] =
             Handbean.ConversationStore.load_messages(sid)
  end

  test "provider task failure flushes accepted text before reporting error" do
    {sid, provider} = start_controlled_stream(stream_flush_ms: 5_000)

    emit_chunk(provider, "saved")
    assert_receive {:agent_event, %{kind: :message_delta, payload: %{text: "saved"}}}, 1_000
    emit_chunk(provider, " pending")

    send(provider, :kill_stream)

    assert_receive {:agent_event, %{kind: :message_delta, payload: %{text: " pending"}}}, 1_000
    assert_receive {:agent_event, %{kind: :run_end, payload: %{status: "error"}}}, 1_000

    assert [%{"role" => "user"}, %{"content" => "saved pending", "status" => "error"}, _] =
             Handbean.ConversationStore.load_messages(sid)
  end

  test "inactivity timeout flushes accepted text before reporting timeout" do
    {sid, provider} =
      start_controlled_stream(stream_flush_ms: 5_000, timeout_ms: 300, delegated?: false)

    emit_chunk(provider, "saved")
    assert_receive {:agent_event, %{kind: :message_delta, payload: %{text: "saved"}}}, 1_000
    emit_chunk(provider, " pending")

    assert_receive {:agent_event, %{kind: :message_delta, payload: %{text: " pending"}}}, 1_000

    assert_receive {:agent_event,
                    %{
                      kind: :run_end,
                      payload: %{status: "timeout", reason: :run_inactivity_timeout}
                    }},
                   1_000

    assert [
             %{"role" => "user"},
             %{
               "role" => "assistant",
               "content" => "saved pending",
               "status" => "error",
               "error" => "run stalled: no progress for 300ms"
             },
             %{
               "role" => "system",
               "message_type" => "error",
               "status" => "final",
               "content" => "Run error: run stalled: no progress for 300ms"
             }
           ] = Handbean.ConversationStore.load_messages(sid)
  end

  test "absolute run deadline flushes accepted text before reporting timeout" do
    {sid, provider} =
      start_controlled_stream(stream_flush_ms: 5_000, timeout_ms: 300, delegated?: true)

    emit_chunk(provider, "saved")
    assert_receive {:agent_event, %{kind: :message_delta, payload: %{text: "saved"}}}, 1_000
    emit_chunk(provider, " pending")

    assert_receive {:agent_event, %{kind: :message_delta, payload: %{text: " pending"}}}, 1_000

    assert_receive {:agent_event,
                    %{kind: :run_end, payload: %{status: "timeout", reason: :run_timeout}}},
                   1_000

    assert [
             %{"role" => "user"},
             %{
               "role" => "assistant",
               "content" => "saved pending",
               "status" => "error",
               "error" => "run deadline exceeded"
             },
             %{
               "role" => "system",
               "message_type" => "error",
               "status" => "final",
               "content" => "Run error: run deadline exceeded"
             }
           ] = Handbean.ConversationStore.load_messages(sid)
  end

  test "timer flush failure stops the producer without replaying pending text" do
    counter = :counters.new(1, [])

    {sid, provider} =
      start_controlled_stream(
        stream_flush_ms: 20,
        transcript_store: FailingTimerStore,
        timer_flush_counter: counter
      )

    emit_chunk(provider, "saved")
    assert_receive {:agent_event, %{kind: :message_delta, payload: %{text: "saved"}}}, 1_000
    emit_chunk(provider, " pending")
    provider_ref = Process.monitor(provider)

    assert_receive {:DOWN, ^provider_ref, :process, ^provider, _reason}, 1_000
    assert_receive {:agent_event, %{kind: :run_end, payload: %{status: "error"}}}, 1_000
    refute_receive {:agent_event, %{kind: :message_delta, payload: %{text: " pending"}}}, 100

    assert [%{"role" => "user"}, %{"content" => "saved", "status" => "error"}, _] =
             Handbean.ConversationStore.load_messages(sid)

    assert :counters.get(counter, 1) == 2
  end

  test "on_event failure stops the producer without replaying a committed batch" do
    callback = fn
      {:message_delta, %{chunk: " pending"}} -> raise "callback failed"
      _event -> :ok
    end

    {sid, provider} = start_controlled_stream(stream_flush_ms: 20, on_event: callback)

    emit_chunk(provider, "saved")
    assert_receive {:agent_event, %{kind: :message_delta, payload: %{text: "saved"}}}, 1_000
    emit_chunk(provider, " pending")
    provider_ref = Process.monitor(provider)

    assert_receive {:DOWN, ^provider_ref, :process, ^provider, _reason}, 1_000
    assert_receive {:agent_event, %{kind: :run_end, payload: %{status: "error"}}}, 1_000
    refute_receive {:agent_event, %{kind: :message_delta, payload: %{text: " pending"}}}, 100

    assert [%{"role" => "user"}, %{"content" => "saved pending", "status" => "error"}, _] =
             Handbean.ConversationStore.load_messages(sid)
  end

  test "non-message callback failure does not replay the batch it drained" do
    callback = fn
      {:usage_updated, _payload} -> raise "usage callback failed"
      _event -> :ok
    end

    {sid, provider} = start_controlled_stream(stream_flush_ms: 5_000, on_event: callback)

    emit_chunk(provider, "saved")
    assert_receive {:agent_event, %{kind: :message_delta, payload: %{text: "saved"}}}, 1_000
    emit_chunk(provider, " pending")
    send(provider, :finish_stream)

    assert_receive {:agent_event, %{kind: :message_delta, payload: %{text: " pending"}}}, 1_000
    assert_receive {:agent_event, %{kind: :run_end, payload: %{status: "error"}}}, 1_000
    refute_receive {:agent_event, %{kind: :message_delta, payload: %{text: " pending"}}}, 100

    assert [%{"role" => "user"}, %{"content" => "saved pending", "status" => "error"}, _] =
             Handbean.ConversationStore.load_messages(sid)
  end

  defp start_controlled_stream(extra) do
    sid = "runner-controlled-stream-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)
    :ok = Session.subscribe(sid)

    assert {:ok, %{action: :started, run_pid: runner}} =
             Coordinator.add_message(
               sid,
               "hello",
               opts(
                 [
                   provider: ControlledStreamingProvider,
                   provider_config: %{notify: self()},
                   streaming: true,
                   source: :web
                 ] ++ extra
               )
             )

    assert_receive {:controlled_stream_ready, provider}, 1_000
    on_exit(fn -> stop_controlled_run(sid, runner) end)
    {sid, provider}
  end

  defp stop_controlled_run(sid, runner) do
    ref = Process.monitor(runner)
    if Process.alive?(runner), do: Coordinator.cancel(sid)
    assert_receive {:DOWN, ^ref, :process, ^runner, _reason}, 2_000

    # Runner schedules collaboration settlement before it exits. Waiting for
    # the Runner first makes that task visible to the existing task drain and
    # keeps it inside the current SQL sandbox ownership lifetime.
    drain_runtime_tasks()
  end

  defp emit_chunk(provider, payload) do
    send(provider, {:emit_chunk, payload})
    assert_receive {:chunk_callback_returned, ^provider, ^payload}, 1_000
    :ok
  end

  defp emit_provider_event(provider, event) do
    send(provider, {:emit_event, event})
    assert_receive {:event_callback_returned, ^provider, ^event}, 1_000
    :ok
  end

  defp finish_stream(provider) do
    send(provider, :finish_stream)
    assert_receive {:agent_event, %{kind: :run_end}}, 1_000
    :ok
  end

  defp default_prompt_workspace do
    workspace = Path.join(Handbean.Host.data_dir(), "default-prompt-workspace")
    File.mkdir_p!(Path.join(workspace, ".handbean"))
    File.write!(Path.join(workspace, "approval.exs"), "1\n")

    File.write!(
      Handbean.WorkspaceSettings.path(workspace),
      Handbean.JSON.encode!(%{"tools" => %{"default_mode" => "prompt"}})
    )

    workspace
  end

  defp approval_workspace do
    workspace = Path.join(Handbean.Host.data_dir(), "approval-workspace")
    File.mkdir_p!(Path.join(workspace, ".handbean"))
    File.write!(Path.join(workspace, "approval.exs"), "1\n")

    File.write!(
      Handbean.WorkspaceSettings.path(workspace),
      Handbean.JSON.encode!(%{"tools" => %{"per_tool" => %{"run_elixir_script" => "prompt"}}})
    )

    workspace
  end

  defp host_process_ids(shell_file, child_file) do
    shell_pid = shell_file |> File.read!() |> String.trim() |> String.to_integer()
    child_pid = child_file |> File.read!() |> String.trim() |> String.to_integer()

    if :os.type() == {:unix, :linux} do
      # $$ and $! are namespace-local under Bubblewrap, not host PIDs.
      # Resolve the shell by its unique command marker, then the child within
      # that same PID namespace. Never mistake a namespace PID of 2 for kthreadd.
      processes =
        for name <- File.ls!("/proc"),
            {pid, ""} <- [Integer.parse(name)],
            {:ok, status} <- [File.read("/proc/#{pid}/status")],
            [_, ids] <- [Regex.run(~r/^NSpid:\s*(.+)$/m, status)] do
          {pid, ids |> String.split() |> List.last() |> String.to_integer()}
        end

      assert [{host_shell, ^shell_pid}] =
               Enum.filter(processes, fn {pid, local} ->
                 local == shell_pid and
                   case File.read("/proc/#{pid}/cmdline") do
                     {:ok, command} -> String.contains?(command, shell_file)
                     _ -> false
                   end
               end)

      namespace = File.read_link!("/proc/#{host_shell}/ns/pid")

      assert [{host_child, ^child_pid}] =
               Enum.filter(processes, fn {pid, local} ->
                 local == child_pid and
                   File.read_link("/proc/#{pid}/ns/pid") == {:ok, namespace}
               end)

      {host_shell, host_child}
    else
      {shell_pid, child_pid}
    end
  end

  defp alive_os?(pid) when is_integer(pid) do
    case System.cmd("ps", ["-p", Integer.to_string(pid), "-o", "stat="]) do
      {state, 0} ->
        String.trim(state) != "" and not String.starts_with?(String.trim(state), ["Z", "X"])

      _ ->
        false
    end
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
