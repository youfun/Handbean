defmodule Handbean.Agent.ExtensionBridgeTest do
  use ExUnit.Case, async: false

  alias Handbean.Agent.ExtensionBridge
  alias Handbean.Extension.Registry, as: ExtRegistry

  defmodule StableWorker do
    use Agent

    def child_spec(_opts),
      do: %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}, restart: :permanent}

    def start_link(opts), do: Agent.start_link(fn -> opts end)
  end

  defmodule ReplacementWorker do
    use Agent

    def child_spec(_opts),
      do: %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}, restart: :permanent}

    def start_link(opts), do: Agent.start_link(fn -> opts end, name: __MODULE__)
  end

  defmodule AutoRestartWorker do
    use Agent

    def child_spec(_opts),
      do: %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}, restart: :permanent}

    def start_link(opts), do: Agent.start_link(fn -> opts end, name: __MODULE__)
  end

  defmodule FailingWorker do
    def child_spec(_opts),
      do: %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}, restart: :permanent}

    def start_link(_opts), do: {:error, :boom}
  end

  defmodule PreviousOwnerTool do
    @behaviour Handbean.Agent.Tool
    def name, do: "ext__rollback__ping"
    def description, do: "previous"
    def input_schema, do: %{"type" => "object", "properties" => %{}}
    def execute(_, _), do: {:ok, "previous"}
  end

  defmodule ReplacementOwnerTool do
    @behaviour Handbean.Agent.Tool
    def name, do: "ext__rollback__ping"
    def description, do: "replacement"
    def input_schema, do: %{"type" => "object", "properties" => %{}}
    def execute(_, _), do: {:ok, "replacement"}
  end

  setup do
    # Start a fresh extension registry for each test
    # Use a test supervisor to ensure cleanup
    reg_name = :"test_ext_registry_#{System.unique_integer([:positive])}"
    {:ok, pid} = ExtRegistry.start_link(name: reg_name)

    %{reg_name: reg_name, reg_pid: pid}
  end

  describe "register_extension_tool/1" do
    test "registers a tool module that implements Handbean.Agent.Tool" do
      result = ExtensionBridge.register_extension_tool(TestExtensionTool)
      assert result == :ok

      {:ok, entry} = Handbean.Tool.Registry.get("ext__test__ping")
      assert entry.module == TestExtensionTool
    end

    test "tool appears in provider tool defs" do
      :ok = ExtensionBridge.register_extension_tool(TestExtensionTool)
      defs = Handbean.Tool.Registry.tool_defs()
      assert Enum.any?(defs, &(&1.name == "ext__test__ping"))
    end

    test "returns error for non-tool module" do
      result = ExtensionBridge.register_extension_tool(String)
      assert {:error, _reason} = result
    end

    test "returns error for module missing tool callbacks" do
      # Elixir atom that's not a tool module
      result = ExtensionBridge.register_extension_tool(MissingToolCallbacks)
      assert {:error, reason} = result
      assert reason =~ "missing required callbacks"
    end
  end

  describe "register_extension_tools/1" do
    test "registers multiple tool modules" do
      result =
        ExtensionBridge.register_extension_tools([
          TestExtensionTool,
          TestExtensionTool2
        ])

      assert result == :ok

      names = Handbean.Tool.Registry.list()
      assert "ext__test__ping" in names
      assert "ext__test__echo" in names
    end
  end

  describe "from_extension/1" do
    test "returns ok with empty diagnostics when no tools declared" do
      ext = build_extension("empty-ext")
      result = ExtensionBridge.from_extension(ext)
      assert {:ok, []} = result
    end

    test "returns ok when declared tools have matching modules" do
      # Pre-register the tool modules
      ExtensionBridge.register_extension_tool(TestExtensionTool)
      ExtensionBridge.register_extension_tool(TestExtensionTool2)

      ext =
        build_extension("test-ext",
          tools: [
            %{"name" => "ping"},
            %{"name" => "echo"}
          ]
        )

      result = ExtensionBridge.from_extension(ext)
      assert {:ok, diagnostics} = result
      # No warnings expected since modules are found
      assert diagnostics == []
    end
  end

  describe "load_and_integrate/1" do
    test "returns ok with diagnostics when no extensions found" do
      result =
        ExtensionBridge.load_and_integrate(
          project: "/tmp/nonexistent-workspace-12345",
          user_home: "/tmp/nonexistent-home-12345"
        )

      assert {:ok, diagnostics} = result
      assert is_list(diagnostics)
      assert diagnostics == []
    end
  end

  describe "atomic runtime replacement" do
    test "worker startup failure keeps the previous worker alive" do
      owner = {:extension, "worker-rollback-#{System.unique_integer([:positive])}"}
      assert :ok = Handbean.Extension.Supervisor.replace_workers(owner, [StableWorker])
      [pid] = Handbean.Extension.Supervisor.workers(owner)

      assert {:error, {:worker_start_failed, {FailingWorker, :boom}}} =
               Handbean.Extension.Supervisor.replace_workers(owner, [StableWorker, FailingWorker])

      assert Handbean.Extension.Supervisor.workers(owner) == [pid]
      assert Process.alive?(pid)
      assert :ok = Handbean.Extension.Supervisor.replace_workers(owner, [])
    end

    test "registry commit failure preserves the previous worker pid, state, and tools" do
      owner = {:extension, "rollback"}
      assert :ok = Handbean.Extension.Supervisor.replace_workers(owner, [StableWorker])
      [previous_pid] = Handbean.Extension.Supervisor.workers(owner)
      Agent.update(previous_pid, fn _ -> :sentinel end)
      assert :ok = Handbean.Tool.Registry.replace_owner(owner, [PreviousOwnerTool])

      dead_registry = spawn(fn -> :ok end)
      ref = Process.monitor(dead_registry)
      assert_receive {:DOWN, ^ref, :process, ^dead_registry, _}

      ext = build_extension("rollback")

      prepared = %{
        extension: ext,
        modules: [ReplacementWorker],
        tool_modules: [ReplacementOwnerTool],
        hook_module: nil,
        capabilities: %{commands: [], providers: []}
      }

      assert {:error, {:registry_commit_failed, _}} =
               ExtensionBridge.commit_prepared(prepared, ext_registry: dead_registry)

      assert Handbean.Extension.Supervisor.workers(owner) == [previous_pid]
      assert Process.alive?(previous_pid)
      assert Agent.get(previous_pid, & &1) == :sentinel
      assert Process.whereis(ReplacementWorker) == nil
      assert {:ok, entry} = Handbean.Tool.Registry.get("ext__rollback__ping")
      assert entry.module == PreviousOwnerTool
      assert :ok = Handbean.Tool.Registry.remove_owner(owner)
      assert :ok = Handbean.Extension.Supervisor.replace_workers(owner, [])
    end

    test "already-started workers are never borrowed by another owner" do
      first_owner = {:extension, "first-worker-owner"}
      second_owner = {:extension, "second-worker-owner"}

      assert :ok = Handbean.Extension.Supervisor.replace_workers(first_owner, [ReplacementWorker])
      [pid] = Handbean.Extension.Supervisor.workers(first_owner)

      assert {:error, {:worker_start_failed, {ReplacementWorker, {:already_started, ^pid}}}} =
               Handbean.Extension.Supervisor.prepare_workers(second_owner, [ReplacementWorker])

      assert Process.alive?(pid)
      assert Handbean.Extension.Supervisor.workers(first_owner) == [pid]
      assert Handbean.Extension.Supervisor.workers(second_owner) == []
      assert :ok = Handbean.Extension.Supervisor.replace_workers(first_owner, [])
    end

    test "aborting or removing a restarted worker terminates its current instance" do
      candidate_owner = {:extension, "restart-candidate"}

      assert {:ok, change} =
               Handbean.Extension.Supervisor.prepare_workers(candidate_owner, [AutoRestartWorker])

      first_pid = Process.whereis(AutoRestartWorker)
      assert is_pid(first_pid)
      Process.exit(first_pid, :kill)
      restarted_pid = eventually_new_pid(AutoRestartWorker, first_pid)
      assert Process.alive?(restarted_pid)

      assert :ok = Handbean.Extension.Supervisor.abort_workers(change)
      assert_eventually_stopped(AutoRestartWorker)
      assert Handbean.Extension.Supervisor.workers(candidate_owner) == []

      committed_owner = {:extension, "restart-committed"}

      assert :ok =
               Handbean.Extension.Supervisor.replace_workers(committed_owner, [AutoRestartWorker])

      committed_pid = Process.whereis(AutoRestartWorker)
      Process.exit(committed_pid, :kill)
      replacement_pid = eventually_new_pid(AutoRestartWorker, committed_pid)
      assert Process.alive?(replacement_pid)

      assert :ok = Handbean.Extension.Supervisor.replace_workers(committed_owner, [])
      assert_eventually_stopped(AutoRestartWorker)
      assert Handbean.Extension.Supervisor.workers(committed_owner) == []
    end
  end

  defp eventually_new_pid(module, previous, attempts \\ 1_000)

  defp eventually_new_pid(_module, _previous, 0), do: flunk("worker did not restart")

  defp eventually_new_pid(module, previous, attempts) do
    case Process.whereis(module) do
      pid when is_pid(pid) and pid != previous ->
        pid

      _ ->
        receive do
        after
          1 -> eventually_new_pid(module, previous, attempts - 1)
        end
    end
  end

  defp assert_eventually_stopped(module, attempts \\ 1_000)
  defp assert_eventually_stopped(_module, 0), do: flunk("worker did not stop")

  defp assert_eventually_stopped(module, attempts) do
    if Process.whereis(module) == nil do
      :ok
    else
      receive do
      after
        1 -> assert_eventually_stopped(module, attempts - 1)
      end
    end
  end

  # ── Helpers ──

  defp build_extension(name, opts \\ []) do
    tools = Keyword.get(opts, :tools, [])

    %Handbean.Extension{
      name: name,
      root: "/abs/path/.handbean/extensions/#{name}",
      enabled: true,
      tools: tools,
      entry: nil,
      version: "0.1.0",
      description: nil,
      permissions: %{},
      hooks: [],
      commands: [],
      providers: [],
      metadata: %{}
    }
  end
end
