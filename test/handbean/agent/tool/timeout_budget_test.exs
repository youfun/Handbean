defmodule Handbean.Agent.Tool.TimeoutBudgetTest do
  use Handbean.DataCase, async: false

  alias Handbean.Agent.{Config, State}
  alias Handbean.Agent.Tool.Executor
  alias Handbean.Tool.Registry

  defmodule BudgetTool do
    @behaviour Handbean.Agent.Tool
    def name, do: "timeout_budget_fixture"
    def description, do: "Timeout budget fixture"
    def input_schema, do: %{type: "object", properties: %{}}
    def timeout_ms(input), do: input["budget"]

    def execute(input, context) do
      send(context.test_pid, {:started, input["label"], self(), context.tool_timeout})

      receive do
        :finish -> {:ok, input["label"] || "finished"}
      end
    end
  end

  setup do
    :ok = Registry.register(BudgetTool)
    on_exit(fn -> Registry.unregister(BudgetTool.name()) end)
    :ok
  end

  test "registry resolves explicit execution budgets without replacing job response budgets" do
    for {module, input, expected} <- [
          {Handbean.Tool.Builtin.Bash, %{}, 120_000},
          {Handbean.Tool.Builtin.Bash, %{"timeout" => 300}, 300_000},
          {Handbean.Tool.Builtin.Bash, %{"timeout" => 3601}, nil},
          {Handbean.Tool.Builtin.Bash, %{"timeout" => "300"}, nil},
          {Handbean.Tool.Builtin.Bash, %{"job" => true, "timeout" => 3600}, nil},
          {Handbean.Tool.Builtin.Browser, %{"timeout_ms" => 300_000}, 300_000},
          {Handbean.Tool.Builtin.Browser, %{"timeout_ms" => 300_001}, nil},
          {Handbean.Tool.Builtin.MixProject, %{}, 60_000},
          {Handbean.Tool.Builtin.MixProject, %{"timeout_ms" => 120_000}, nil},
          {Handbean.Tool.Builtin.MixProject, %{"job" => true, "timeout_ms" => 3_600_000}, nil},
          {Handbean.Tool.Builtin.RunElixirScript, %{}, 30_000},
          {Handbean.Tool.Builtin.RunElixirScript, %{"job" => true}, nil}
        ] do
      assert apply(module, :timeout_ms, [input]) == expected
    end

    {:ok, entry} = Registry.get(BudgetTool.name())
    assert is_function(entry.timeout_ms, 1)
    assert entry.timeout_ms.(%{"budget" => 123}) == 123
  end

  test "concurrent calls use their own budget and preserve requested order" do
    state = state(tool_timeout: 50)
    calls = [call("first", 1), call("second", 1_000)]
    task = Task.async(fn -> Executor.execute_all(calls, state) end)
    assert_receive {:started, "first", first, 50}
    assert_receive {:started, "second", second, 50}
    monitor = Process.monitor(first)
    # Cross the first call's actual guard, then release the longer call by message.
    assert_receive {:DOWN, ^monitor, :process, ^first, _}, 5_500
    send(second, :finish)
    assert {:ok, message} = Task.await(task)
    assert [short, long] = message.content
    assert short.tool_use_id == "first"
    assert short.is_error
    refute long.is_error
    assert long.content == "second"
  end

  test "sequential explicit budget survives the configured default guard" do
    name = "sequential_budget_fixture"

    :ok =
      Registry.register_virtual(name, "Budget fixture", %{}, &BudgetTool.execute/2,
        concurrent?: false,
        timeout_ms: &BudgetTool.timeout_ms/1
      )

    on_exit(fn -> Registry.unregister(name) end)
    state = state(tool_timeout: 50)
    call = %{call("sequential", 2_000) | name: name}
    task = Task.async(fn -> Executor.execute_all([call], state) end)
    assert_receive {:started, "sequential", worker, 50}
    Process.send_after(worker, :finish, 5_100)
    assert {:ok, message} = Task.await(task, 6_000)
    assert [block] = message.content
    refute block.is_error
    assert block.content == "sequential"
  end

  for concurrent <- [true, false] do
    test "run deadline bounds cleanup grace and stops worker (concurrent=#{concurrent})" do
      name = "deadline_fixture_#{unquote(concurrent)}"
      test_pid = self()

      :ok =
        Registry.register_virtual(
          name,
          "Deadline fixture",
          %{},
          fn _, _ ->
            send(test_pid, {:blocked, self()})

            receive do
              :finish -> {:ok, "unexpected"}
            end
          end,
          concurrent?: unquote(concurrent),
          timeout_ms: 100_000
        )

      on_exit(fn -> Registry.unregister(name) end)
      deadline = System.monotonic_time(:millisecond) + 100
      state = state(context: %{test_pid: self(), run_deadline: deadline})

      task =
        Task.async(fn ->
          Executor.execute_all([%{id: "deadline", name: name, input: %{}}], state)
        end)

      assert_receive {:blocked, worker}
      monitor = Process.monitor(worker)
      assert {:ok, message} = Task.await(task, 1_000)
      assert [block] = message.content
      assert block.is_error
      assert_receive {:DOWN, ^monitor, :process, ^worker, _}
    end
  end

  test "expired calls do not invoke tools, including sequential calls queued behind expiry" do
    name = "queued_deadline_fixture"
    test_pid = self()

    :ok =
      Registry.register_virtual(
        name,
        "Queued deadline fixture",
        %{},
        fn input, _ ->
          send(test_pid, {:invoked, input["id"]})

          receive do
            :finish -> {:ok, "finished"}
          end
        end,
        concurrent?: false
      )

    on_exit(fn -> Registry.unregister(name) end)
    calls = for id <- ["one", "two"], do: %{id: id, name: name, input: %{"id" => id}}
    expired = state(context: %{run_deadline: System.monotonic_time(:millisecond) - 1})
    assert {:ok, message} = Executor.execute_all(calls, expired)
    assert Enum.all?(message.content, & &1.is_error)
    refute_received {:invoked, _}

    live = state(context: %{run_deadline: System.monotonic_time(:millisecond) + 100})
    assert {:ok, message} = Executor.execute_all(calls, live)
    assert Enum.all?(message.content, & &1.is_error)
    assert_received {:invoked, "one"}
    refute_received {:invoked, "two"}
  end

  test "job wait budget uses the remaining run budget rather than command execution timeout" do
    name = "job_wait_budget_fixture"

    :ok =
      Registry.register_virtual(
        name,
        "Wait budget fixture",
        %{},
        fn _, context ->
          {:ok, launch} = Handbean.Jobs.wait_budget(100_000, context)
          {:ok, query} = Handbean.Jobs.status_wait_budget(100_000, context)
          {:ok, "bounded", %{launch_wait: launch, query_wait: query}}
        end,
        timeout_ms: &Handbean.Tool.Builtin.Bash.timeout_ms/1
      )

    on_exit(fn -> Registry.unregister(name) end)
    state = state(context: %{run_deadline: System.monotonic_time(:millisecond) + 2_000})

    assert {:ok, _, [block]} =
             Executor.execute_all_with_details(
               [
                 %{id: "job", name: name, input: %{"job" => true, "timeout" => 3600}}
               ],
               state
             )

    refute block.is_error
    assert block.details.launch_wait in 1..1_000
    assert block.details.query_wait in 1..1_000
  end

  for concurrent <- [true, false] do
    test "cancelling the caller terminates its guarded worker (concurrent=#{concurrent})" do
      name = "cancel_budget_#{unquote(concurrent)}"

      :ok =
        Registry.register_virtual(name, "Cancellation fixture", %{}, &BudgetTool.execute/2,
          concurrent?: unquote(concurrent),
          timeout_ms: 10_000
        )

      on_exit(fn -> Registry.unregister(name) end)
      state = state(tool_timeout: 10_000)
      call = %{call("cancel", 10_000) | name: name}
      task = Task.async(fn -> Executor.execute_all([call], state) end)
      assert_receive {:started, "cancel", worker, 10_000}
      monitor = Process.monitor(worker)
      Task.shutdown(task, :brutal_kill)
      assert_receive {:DOWN, ^monitor, :process, ^worker, _}
    end
  end

  test "cancelling dispatch during timeout resolution stops the resolver" do
    name = "cancel_budget_resolver"
    test_pid = self()

    resolver = fn _ ->
      send(test_pid, {:resolving, self()})

      receive do
        :finish -> 10_000
      end
    end

    :ok =
      Registry.register_virtual(
        name,
        "Resolver cancellation",
        %{},
        fn _, _ ->
          send(test_pid, :unexpected_execution)
          {:ok, "unexpected"}
        end,
        concurrent?: false,
        timeout_ms: resolver
      )

    on_exit(fn -> Registry.unregister(name) end)
    state = state(tool_timeout: 10_000)

    task =
      Task.async(fn ->
        Executor.execute_all([%{id: "resolver", name: name, input: %{}}], state)
      end)

    assert_receive {:resolving, resolver_pid}
    monitor = Process.monitor(resolver_pid)
    Task.shutdown(task, :brutal_kill)
    assert_receive {:DOWN, ^monitor, :process, ^resolver_pid, _}
    refute_received :unexpected_execution
  end

  test "invalid and failing dynamic declarations fall back without crashing dispatch" do
    for {label, resolver} <- [
          {"raise", fn _ -> raise "bad declaration" end},
          {"infinity", fn _ -> :infinity end},
          {"negative", fn _ -> -10 end},
          {"hang",
           fn _ ->
             receive do
               :never -> 10
             end
           end}
        ] do
      name = "invalid_budget_" <> label

      :ok =
        Registry.register_virtual(name, "Invalid budget", %{}, fn _, _ -> {:ok, "fallback"} end,
          concurrent?: false,
          timeout_ms: resolver
        )

      on_exit(fn -> Registry.unregister(name) end)

      assert {:ok, message} =
               Executor.execute_all(
                 [%{id: label, name: name, input: %{}}],
                 state(tool_timeout: 50)
               )

      assert [block] = message.content
      refute block.is_error
      assert block.content == "fallback"
    end
  end

  defp call(label, budget),
    do: %{id: label, name: BudgetTool.name(), input: %{"budget" => budget, "label" => label}}

  defp state(opts) do
    config = struct(Config, Keyword.merge([context: %{test_pid: self()}], opts))
    State.init(config, "timeout test")
  end
end
