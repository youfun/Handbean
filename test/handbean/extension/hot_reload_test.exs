defmodule Handbean.Extension.HotReloadTest do
  @moduledoc """
  TDD: reload extension manifests and compiled entry modules without
  tearing down an active RunSupervisor.
  """

  use Handbean.DataCase, async: false

  import Handbean.TestSupport.RuntimeLifecycle

  alias Handbean.Agent.Coordinator
  alias Handbean.Agent.ExtensionBridge
  alias Handbean.Extension.{Capabilities, HotReloader, Loader}
  alias Handbean.Extension.Registry, as: ExtRegistry

  @tmp_base Path.join(System.tmp_dir!(), "sigil_hot_reload_test")

  setup do
    tmp = Path.join(@tmp_base, "case_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    {:ok, tmp} = Handbean.Security.PathValidator.canonicalize(tmp)
    old_home = System.get_env("HOME")
    System.put_env("HOME", tmp)
    old_trust = Application.get_env(:handbean, :trust_project_code)
    Application.put_env(:handbean, :trust_project_code, true)

    on_exit(fn ->
      try do
        drain_terminal_callbacks!()
        sync_runtime_observers!()
      after
        if old_home, do: System.put_env("HOME", old_home), else: System.delete_env("HOME")

        if is_nil(old_trust),
          do: Application.delete_env(:handbean, :trust_project_code),
          else: Application.put_env(:handbean, :trust_project_code, old_trust)

        File.rm_rf!(tmp)
      end
    end)

    registry = :"hot_reload_reg_#{System.unique_integer([:positive])}"
    {:ok, _} = ExtRegistry.start_link(name: registry)

    on_exit(fn ->
      if Process.whereis(Handbean.Extension.Supervisor) do
        Handbean.Extension.Supervisor.replace_workers("hotdemo", [])
        Handbean.Extension.Supervisor.replace_workers("renamed", [])
        Handbean.Extension.Supervisor.replace_workers("userdemo", [])
        Handbean.Extension.Supervisor.replace_workers("shared", [])
        Handbean.Tool.Registry.remove_owner({:extension, "hotdemo"})
        Handbean.Tool.Registry.remove_owner({:extension, "renamed"})
        Handbean.Tool.Registry.remove_owner({:extension, "userdemo"})
        Handbean.Tool.Registry.remove_owner({:extension, "shared"})
      end
    end)

    {:ok, tmp: tmp, registry: registry}
  end

  test "reload swaps a compiled entry module and reregisters its tool", %{
    tmp: tmp,
    registry: registry
  } do
    ext_dir = write_entry_extension!(tmp, "hotdemo", version: "0.1.0", result: ":v1")

    assert {:ok, _diags} =
             ExtensionBridge.load_and_integrate(
               project: tmp,
               user_home: Path.join(tmp, "no-user"),
               ext_registry: registry
             )

    assert {:ok, ext} = ExtRegistry.get(registry, "hotdemo")
    assert ext.version == "0.1.0"
    assert {:ok, entry} = Handbean.Tool.Registry.get("ext__hotdemo__ping")
    assert {:ok, ":v1"} = entry.executor.(%{}, %{})

    write_entry_extension!(tmp, "hotdemo", version: "0.2.0", result: ":v2")

    assert {:ok, _diags} =
             HotReloader.reload(
               project: tmp,
               user_home: Path.join(tmp, "no-user"),
               ext_registry: registry
             )

    assert {:ok, reloaded} = ExtRegistry.get(registry, "hotdemo")
    assert reloaded.version == "0.2.0"
    assert reloaded.root == ext_dir
    assert {:ok, new_entry} = Handbean.Tool.Registry.get("ext__hotdemo__ping")
    assert {:ok, ":v2"} = new_entry.executor.(%{}, %{})
  end

  test "generation budget reuses unchanged source and rejects the next unique edit", %{
    tmp: tmp,
    registry: registry
  } do
    ext_dir = write_entry_extension!(tmp, "hotdemo", version: "0.1.0", result: ":v1")

    for generation <- 1..(Capabilities.generation_limit() - 1) do
      assert :ok = Capabilities.reserve_generation(ext_dir, "reserved-#{generation}")
    end

    assert {:ok, []} =
             HotReloader.reload(
               project: tmp,
               user_home: Path.join(tmp, "no-user"),
               ext_registry: registry
             )

    assert {:ok, []} =
             HotReloader.reload(
               project: tmp,
               user_home: Path.join(tmp, "no-user"),
               ext_registry: registry
             )

    write_entry_extension!(tmp, "hotdemo", version: "0.2.0", result: ":v2")

    assert {:ok, diagnostics} =
             HotReloader.reload(
               project: tmp,
               user_home: Path.join(tmp, "no-user"),
               ext_registry: registry
             )

    assert Enum.any?(diagnostics, fn diagnostic ->
             diagnostic.type == :validation_error and
               String.contains?(diagnostic.message, "generation limit") and
               String.contains?(diagnostic.message, "restart Handbean")
           end)

    assert {:ok, extension} = ExtRegistry.get(registry, "hotdemo")
    assert extension.version == "0.1.0"
    assert {:ok, entry} = Handbean.Tool.Registry.get("ext__hotdemo__ping")
    assert {:ok, ":v1"} = entry.executor.(%{}, %{})
  end

  test "reload does not stop an active RunSupervisor", %{tmp: tmp, registry: registry} do
    write_entry_extension!(tmp, "hotdemo", version: "0.1.0", result: ":v1")

    {:ok, _} =
      ExtensionBridge.load_and_integrate(
        project: tmp,
        user_home: Path.join(tmp, "no-user"),
        ext_registry: registry
      )

    assert {:ok, conversation} = Handbean.ConversationStore.create("default", timeline: [])
    conversation_id = conversation["id"]
    on_exit(fn -> stop_run!(conversation_id) end)
    parent = self()

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(conversation_id, "hold",
               workspace_path: tmp,
               model: "fake-model",
               provider: __MODULE__.BlockingProvider,
               provider_config: %{notify: parent},
               tools: [],
               source: :cli,
               streaming: false,
               max_turns: 3
             )

    assert_receive {:hot_reload_provider_started, task_pid}, 1_000
    assert {:ok, %{run_pid: run_pid}} = Coordinator.status(conversation_id)
    run_ref = Process.monitor(run_pid)

    write_entry_extension!(tmp, "hotdemo", version: "0.2.0", result: ":v2")

    assert {:ok, _} =
             HotReloader.reload(
               project: tmp,
               user_home: Path.join(tmp, "no-user"),
               ext_registry: registry
             )

    refute_receive {:DOWN, ^run_ref, :process, ^run_pid, _reason}, 200
    assert Process.alive?(run_pid)
    assert {:ok, entry} = Handbean.Tool.Registry.get("ext__hotdemo__ping")
    assert {:ok, ":v2"} = entry.executor.(%{}, %{})

    send(task_pid, :finish)
    assert_receive {:DOWN, ^run_ref, :process, ^run_pid, _reason}, 2_000
  end

  test "start_link preloads extensions already on disk", %{tmp: tmp, registry: registry} do
    write_entry_extension!(tmp, "hotdemo", version: "0.1.0", result: ":v1")

    {:ok, _pid} =
      HotReloader.start_link(
        name: :"hot_reload_preload_#{System.unique_integer([:positive])}",
        project: tmp,
        user_home: Path.join(tmp, "no-user"),
        ext_registry: registry,
        enabled: false,
        preload: true,
        trusted_project?: true
      )

    assert {:ok, ext} = ExtRegistry.get(registry, "hotdemo")
    assert ext.version == "0.1.0"
    assert {:ok, entry} = Handbean.Tool.Registry.get("ext__hotdemo__ping")
    assert {:ok, ":v1"} = entry.executor.(%{}, %{})
  end

  test "automatic preload skips project extensions when project code is untrusted", %{
    tmp: tmp,
    registry: registry
  } do
    write_entry_extension!(tmp, "hotdemo", version: "0.1.0", result: ":v1")

    {:ok, _pid} =
      HotReloader.start_link(
        name: :"hot_reload_untrusted_#{System.unique_integer([:positive])}",
        project: tmp,
        user_home: Path.join(tmp, "no-user"),
        ext_registry: registry,
        enabled: false,
        preload: true,
        trusted_project?: false
      )

    assert {:error, :not_found} = ExtRegistry.get(registry, "hotdemo")
  end

  test "explicit reload skips project extensions when project code is untrusted", %{
    tmp: tmp,
    registry: registry
  } do
    write_entry_extension!(tmp, "hotdemo", version: "0.1.0", result: ":v1")

    assert {:ok, _diagnostics} =
             HotReloader.reload(
               project: tmp,
               user_home: Path.join(tmp, "no-user"),
               ext_registry: registry,
               trusted_project?: false
             )

    assert {:error, :not_found} = ExtRegistry.get(registry, "hotdemo")
  end

  test "trust revocation unregisters every project runtime resource and preserves user extensions",
       %{tmp: tmp, registry: registry} do
    user_home = Path.join(tmp, "user-home")
    File.mkdir_p!(user_home)
    write_full_extension!(tmp, "hotdemo", ":project")
    write_full_extension!(user_home, "userdemo", ":user")

    assert {:ok, []} =
             HotReloader.reload(
               project: tmp,
               user_home: user_home,
               ext_registry: registry,
               trusted_project?: true
             )

    assert {:ok, _} = ExtRegistry.get(registry, "hotdemo")
    assert {:ok, _} = ExtRegistry.get(registry, "userdemo")
    assert {:ok, _} = Handbean.Tool.Registry.get("ext__hotdemo__ping")
    assert {:ok, user_tool} = Handbean.Tool.Registry.get("ext__userdemo__ping")
    assert {:ok, ":user"} = user_tool.executor.(%{}, %{})
    assert Map.has_key?(ExtRegistry.list_hook_modules(registry), "hotdemo")
    assert [_] = Handbean.Extension.Supervisor.workers("hotdemo")

    assert Enum.any?(
             ExtRegistry.capabilities(:commands, tmp, registry),
             &(&1.extension == "hotdemo")
           )

    assert Enum.any?(
             ExtRegistry.capabilities(:providers, tmp, registry),
             &(&1.extension == "hotdemo")
           )

    assert {:ok, []} =
             HotReloader.reload(
               project: tmp,
               user_home: user_home,
               ext_registry: registry,
               trusted_project?: false
             )

    assert {:error, :not_found} = ExtRegistry.get(registry, "hotdemo")
    assert Handbean.Tool.Registry.get("ext__hotdemo__ping") == :error
    refute Map.has_key?(ExtRegistry.list_hook_modules(registry), "hotdemo")
    assert Handbean.Extension.Supervisor.workers("hotdemo") == []

    refute Enum.any?(
             ExtRegistry.capabilities(:commands, tmp, registry),
             &(&1.extension == "hotdemo")
           )

    refute Enum.any?(
             ExtRegistry.capabilities(:providers, tmp, registry),
             &(&1.extension == "hotdemo")
           )

    assert {:ok, _} = ExtRegistry.get(registry, "userdemo")
    assert {:ok, preserved} = Handbean.Tool.Registry.get("ext__userdemo__ping")
    assert {:ok, ":user"} = preserved.executor.(%{}, %{})
    assert Map.has_key?(ExtRegistry.list_hook_modules(registry), "userdemo")
    assert [_] = Handbean.Extension.Supervisor.workers("userdemo")
    assert [_] = ExtRegistry.capabilities(:commands, :global, registry)
    assert [_] = ExtRegistry.capabilities(:providers, :global, registry)
  end

  test "trust revocation restores a shadowed same-name user generation", %{
    tmp: tmp,
    registry: registry
  } do
    user_home = Path.join(tmp, "collision-user-home")
    File.mkdir_p!(user_home)
    project_root = write_full_extension!(tmp, "shared", ":project")
    user_root = write_full_extension!(user_home, "shared", ":user")

    assert {:ok, []} =
             HotReloader.reload(
               project: tmp,
               user_home: user_home,
               ext_registry: registry,
               trusted_project?: true
             )

    assert {:ok, %{root: ^project_root}} = ExtRegistry.get(registry, "shared")
    assert {:ok, project_tool} = Handbean.Tool.Registry.get("ext__shared__ping")
    assert {:ok, ":project"} = project_tool.executor.(%{}, %{})
    project_hook = ExtRegistry.list_hook_modules(registry)["shared"]
    [project_worker] = Handbean.Extension.Supervisor.workers("shared")

    assert {:ok, []} =
             HotReloader.reload(
               project: tmp,
               user_home: user_home,
               ext_registry: registry,
               trusted_project?: false
             )

    assert {:ok, %{root: ^user_root, scope: :user}} = ExtRegistry.get(registry, "shared")
    assert {:ok, user_tool} = Handbean.Tool.Registry.get("ext__shared__ping")
    assert {:ok, ":user"} = user_tool.executor.(%{}, %{})
    refute ExtRegistry.list_hook_modules(registry)["shared"] == project_hook
    assert [user_worker] = Handbean.Extension.Supervisor.workers("shared")
    refute user_worker == project_worker
    refute Process.alive?(project_worker)
    assert Process.alive?(user_worker)

    assert [%{scope: :user}] = ExtRegistry.capabilities(:commands, tmp, registry)
    assert [%{scope: :user}] = ExtRegistry.capabilities(:providers, tmp, registry)

    assert Enum.all?(ExtRegistry.capability_extensions(registry), fn ext ->
             ext.name != "shared" or ext.scope == :user
           end)
  end

  test "pending path reload rechecks project trust before compiling", %{
    tmp: tmp,
    registry: registry
  } do
    previous_trust = Application.get_env(:handbean, :trust_project_code)
    Application.put_env(:handbean, :trust_project_code, true)

    on_exit(fn ->
      if is_nil(previous_trust),
        do: Application.delete_env(:handbean, :trust_project_code),
        else: Application.put_env(:handbean, :trust_project_code, previous_trust)
    end)

    other = Path.join(tmp, "untrusted-after-notify")
    File.mkdir_p!(other)
    write_entry_extension!(other, "hotdemo", version: "0.1.0", result: ":untrusted")

    {:ok, pid} =
      HotReloader.start_link(
        name: :"hot_reload_recheck_#{System.unique_integer([:positive])}",
        project: tmp,
        user_home: Path.join(tmp, "no-user"),
        ext_registry: registry,
        enabled: true,
        preload: false,
        debounce_ms: 60_000
      )

    HotReloader.notify_path(
      Path.join(other, ".handbean/extensions/hotdemo/extension.json"),
      pid
    )

    assert MapSet.member?(:sys.get_state(pid).pending_projects, other)
    Application.put_env(:handbean, :trust_project_code, false)
    send(pid, :reload)
    assert %{timer: nil, pending_projects: pending} = :sys.get_state(pid)
    assert MapSet.size(pending) == 0

    assert {:error, :not_found} = ExtRegistry.get(registry, "hotdemo")
  end

  test "reload overrides tool description in the registry", %{tmp: tmp, registry: registry} do
    write_entry_extension!(tmp, "hotdemo",
      version: "0.1.0",
      result: ":v1",
      description: "ping v1"
    )

    assert {:ok, _} =
             HotReloader.reload(
               project: tmp,
               user_home: Path.join(tmp, "no-user"),
               ext_registry: registry
             )

    assert {:ok, entry} = Handbean.Tool.Registry.get("ext__hotdemo__ping")
    assert entry.description == "ping v1"

    write_entry_extension!(tmp, "hotdemo",
      version: "0.2.0",
      result: ":v2",
      description: "ping v2"
    )

    assert {:ok, _} =
             HotReloader.reload(
               project: tmp,
               user_home: Path.join(tmp, "no-user"),
               ext_registry: registry
             )

    assert {:ok, updated} = Handbean.Tool.Registry.get("ext__hotdemo__ping")
    assert updated.description == "ping v2"
  end

  test "reload registers a compiled hook module", %{tmp: tmp, registry: registry} do
    write_hook_extension!(tmp, "hotdemo")

    assert {:ok, _} =
             HotReloader.reload(
               project: tmp,
               user_home: Path.join(tmp, "no-user"),
               ext_registry: registry
             )

    hooks = ExtRegistry.list_hook_modules(registry)
    assert is_atom(hooks["hotdemo"])
    assert function_exported?(hooks["hotdemo"], :handle_event, 2)
  end

  test "successful source reload swaps the worker generation", %{
    tmp: tmp,
    registry: registry
  } do
    write_worker_extension!(tmp, "hotdemo", code: :v1)

    assert {:ok, _} =
             HotReloader.reload(
               project: tmp,
               user_home: Path.join(tmp, "no-user"),
               ext_registry: registry
             )

    [pid] = Handbean.Extension.Supervisor.workers("hotdemo")
    [v1_module] = Handbean.Extension.Supervisor.worker_modules("hotdemo")
    assert Process.alive?(pid)
    assert v1_module.started_as() == :v1
    assert v1_module.code_version() == :v1

    write_worker_extension!(tmp, "hotdemo", code: :v2)

    assert {:ok, _} =
             HotReloader.reload(
               project: tmp,
               user_home: Path.join(tmp, "no-user"),
               ext_registry: registry
             )

    [new_pid] = Handbean.Extension.Supervisor.workers("hotdemo")
    [v2_module] = Handbean.Extension.Supervisor.worker_modules("hotdemo")
    refute new_pid == pid
    refute v2_module == v1_module
    refute Process.alive?(pid)
    assert Process.alive?(new_pid)
    assert v2_module.started_as() == :v2
    assert v2_module.code_version() == :v2
  end

  test "reload does not drop a running worker when the next compile fails", %{
    tmp: tmp,
    registry: registry
  } do
    write_combined_extension!(tmp, "hotdemo", result: ":v1", code: :v1)

    assert {:ok, _} =
             HotReloader.reload(
               project: tmp,
               user_home: Path.join(tmp, "no-user"),
               ext_registry: registry
             )

    pid = hd(Handbean.Extension.Supervisor.workers("hotdemo"))
    [worker_module] = Handbean.Extension.Supervisor.worker_modules("hotdemo")
    assert {:ok, entry} = Handbean.Tool.Registry.get("ext__hotdemo__ping")
    assert {:ok, ":v1"} = entry.executor.(%{}, %{})

    File.write!(
      Path.join(tmp, ".handbean/extensions/hotdemo/hot_combo.ex"),
      "defmodule Ext.Hotdemo.Broken do\n  this is not elixir\nend\n"
    )

    assert {:ok, diags} =
             HotReloader.reload(
               project: tmp,
               user_home: Path.join(tmp, "no-user"),
               ext_registry: registry
             )

    assert Enum.any?(diags, &(&1.type in [:warning, :validation_error]))
    assert Process.alive?(pid)
    assert Handbean.Extension.Supervisor.workers("hotdemo") == [pid]
    assert {:ok, still} = Handbean.Tool.Registry.get("ext__hotdemo__ping")
    assert {:ok, ":v1"} = still.executor.(%{}, %{})
    assert worker_module.started_as() == :v1
  end

  test "failed worker preparation does not activate newly compiled legacy code", %{
    tmp: tmp,
    registry: registry
  } do
    ext_dir = write_combined_extension!(tmp, "hotdemo", result: ":v1", code: :v1)

    assert {:ok, []} =
             HotReloader.reload(
               project: tmp,
               user_home: Path.join(tmp, "no-user"),
               ext_registry: registry
             )

    [old_pid] = Handbean.Extension.Supervisor.workers("hotdemo")
    [old_module] = Handbean.Extension.Supervisor.worker_modules("hotdemo")
    assert old_module.code_version() == :v1

    File.write!(Path.join(ext_dir, "hot_combo.ex"), """
    defmodule Ext.Hotdemo.Ping do
      @behaviour Handbean.Agent.Tool
      def name, do: "ext__hotdemo__ping"
      def description, do: "candidate"
      def input_schema, do: %{"type" => "object", "properties" => %{}}
      def execute(_input, _context), do: {:ok, ":v2"}
    end

    defmodule Ext.Hotdemo.Worker do
      def child_spec(_opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}}
      def start_link(_opts), do: {:error, :candidate_failed}
      def code_version, do: :v2
    end
    """)

    assert {:ok, diagnostics} =
             HotReloader.reload(
               project: tmp,
               user_home: Path.join(tmp, "no-user"),
               ext_registry: registry
             )

    assert Enum.any?(diagnostics, &String.contains?(&1.message, "Failed to commit"))
    assert Handbean.Extension.Supervisor.workers("hotdemo") == [old_pid]
    assert Handbean.Extension.Supervisor.worker_modules("hotdemo") == [old_module]
    assert Process.alive?(old_pid)
    assert old_module.code_version() == :v1
    assert {:ok, tool} = Handbean.Tool.Registry.get("ext__hotdemo__ping")
    assert {:ok, ":v1"} = tool.executor.(%{}, %{})
  end

  test "failed registry commit keeps the previous generated executable code", %{
    tmp: tmp,
    registry: registry
  } do
    write_combined_extension!(tmp, "hotdemo", result: ":v1", code: :v1)

    assert {:ok, []} =
             HotReloader.reload(
               project: tmp,
               user_home: Path.join(tmp, "no-user"),
               ext_registry: registry
             )

    [old_pid] = Handbean.Extension.Supervisor.workers("hotdemo")
    [old_module] = Handbean.Extension.Supervisor.worker_modules("hotdemo")
    write_combined_extension!(tmp, "hotdemo", result: ":v2", code: :v2)
    [candidate] = Loader.from_project(tmp).extensions
    assert {:ok, prepared} = ExtensionBridge.prepare(candidate)
    refute old_module in prepared.modules

    dead_registry = spawn(fn -> :ok end)
    monitor = Process.monitor(dead_registry)
    assert_receive {:DOWN, ^monitor, :process, ^dead_registry, _down_reason}

    assert {:error, {:registry_commit_failed, _commit_reason}} =
             ExtensionBridge.commit_prepared(prepared, ext_registry: dead_registry)

    assert Handbean.Extension.Supervisor.workers("hotdemo") == [old_pid]
    assert Handbean.Extension.Supervisor.worker_modules("hotdemo") == [old_module]
    assert Process.alive?(old_pid)
    assert old_module.code_version() == :v1
    assert {:ok, tool} = Handbean.Tool.Registry.get("ext__hotdemo__ping")
    assert {:ok, ":v1"} = tool.executor.(%{}, %{})
  end

  test "successful reload removes stale tools and hooks", %{tmp: tmp, registry: registry} do
    ext_dir = write_tool_hook_extension!(tmp, "hotdemo", include_tool: true, include_hook: true)

    assert {:ok, _} =
             HotReloader.reload(
               project: tmp,
               user_home: Path.join(tmp, "no-user"),
               ext_registry: registry
             )

    assert {:ok, _} = Handbean.Tool.Registry.get("ext__hotdemo__ping")
    assert ExtRegistry.list_hook_modules(registry)["hotdemo"]

    File.write!(
      Path.join(ext_dir, "extension.json"),
      Jason.encode!(%{
        "name" => "hotdemo",
        "version" => "0.2.0",
        "entry" => "hot_cleanup.ex",
        "tools" => [],
        "hooks" => []
      })
    )

    File.write!(
      Path.join(ext_dir, "hot_cleanup.ex"),
      """
      defmodule Ext.Hotdemo.Cleanup do
        def marker, do: :clean
      end

      defmodule Ext.Hotdemo.Hook do
        @behaviour Handbean.Extension.Hook
        def handle_event(_event, _ctx), do: :ok
      end
      """
    )

    assert {:ok, _} =
             HotReloader.reload(
               project: tmp,
               user_home: Path.join(tmp, "no-user"),
               ext_registry: registry
             )

    assert Handbean.Tool.Registry.get("ext__hotdemo__ping") == :error
    refute Map.has_key?(ExtRegistry.list_hook_modules(registry), "hotdemo")
  end

  test "renaming a manifest at the same root retires the previous runtime owner", %{
    tmp: tmp,
    registry: registry
  } do
    ext_dir = write_combined_extension!(tmp, "hotdemo", result: ":v1", code: :v1)

    assert {:ok, _} =
             HotReloader.reload(
               project: tmp,
               user_home: Path.join(tmp, "no-user"),
               ext_registry: registry
             )

    old_worker = hd(Handbean.Extension.Supervisor.workers("hotdemo"))

    File.write!(
      Path.join(ext_dir, "extension.json"),
      Handbean.JSON.encode!(%{
        "name" => "renamed",
        "version" => "0.2.0",
        "entry" => "renamed.ex",
        "tools" => [%{"name" => "ping"}],
        "hooks" => ["before_agent_start"]
      })
    )

    File.write!(
      Path.join(ext_dir, "renamed.ex"),
      """
      defmodule Ext.Renamed.Ping do
        @behaviour Handbean.Agent.Tool
        def name, do: "ext__renamed__ping"
        def description, do: "renamed"
        def input_schema, do: %{"type" => "object", "properties" => %{}}
        def execute(_, _), do: {:ok, "renamed"}
      end

      defmodule Ext.Renamed.Hook do
        @behaviour Handbean.Extension.Hook
        def handle_event(_, _), do: :ok
      end

      defmodule Ext.Renamed.Worker do
        use Agent
        def child_spec(_), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}}
        def start_link(opts), do: Agent.start_link(fn -> opts end)
      end
      """
    )

    assert {:ok, _} =
             HotReloader.reload(
               project: tmp,
               user_home: Path.join(tmp, "no-user"),
               ext_registry: registry
             )

    assert {:error, :not_found} = ExtRegistry.get(registry, "hotdemo")
    assert {:ok, %{name: "renamed"}} = ExtRegistry.get(registry, "renamed")
    assert Handbean.Tool.Registry.get("ext__hotdemo__ping") == :error
    assert {:ok, _} = Handbean.Tool.Registry.get("ext__renamed__ping")
    refute Map.has_key?(ExtRegistry.list_hook_modules(registry), "hotdemo")
    assert Map.has_key?(ExtRegistry.list_hook_modules(registry), "renamed")
    refute Process.alive?(old_worker)
    assert [_new_worker] = Handbean.Extension.Supervisor.workers("renamed")
  end

  test "deleting an extension directory removes its runtime resources", %{
    tmp: tmp,
    registry: registry
  } do
    ext_dir = write_combined_extension!(tmp, "hotdemo", result: ":v1", code: :v1)

    assert {:ok, _} =
             HotReloader.reload(
               project: tmp,
               user_home: Path.join(tmp, "no-user"),
               ext_registry: registry
             )

    pid = hd(Handbean.Extension.Supervisor.workers("hotdemo"))
    assert {:ok, _} = Handbean.Tool.Registry.get("ext__hotdemo__ping")

    File.rm_rf!(ext_dir)

    assert {:ok, _} =
             HotReloader.reload(
               project: tmp,
               user_home: Path.join(tmp, "no-user"),
               ext_registry: registry
             )

    assert {:error, :not_found} = ExtRegistry.get(registry, "hotdemo")
    assert Handbean.Tool.Registry.get("ext__hotdemo__ping") == :error
    assert Handbean.Extension.Supervisor.workers("hotdemo") == []
    refute Process.alive?(pid)
  end

  test "notify_path reloads an extension outside the server cwd", %{
    tmp: tmp,
    registry: registry
  } do
    other = Path.join(tmp, "other_ws")
    File.mkdir_p!(other)
    write_entry_extension!(other, "hotdemo", version: "0.1.0", result: ":from-other")

    {:ok, pid} =
      HotReloader.start_link(
        name: :"hot_reload_notify_#{System.unique_integer([:positive])}",
        project: tmp,
        user_home: Path.join(tmp, "no-user"),
        ext_registry: registry,
        enabled: true,
        preload: false,
        trusted_project?: true,
        debounce_ms: 30
      )

    HotReloader.notify_path(
      Path.join(other, ".handbean/extensions/hotdemo/extension.json"),
      pid
    )

    assert_eventually(fn ->
      assert {:ok, ext} = ExtRegistry.get(registry, "hotdemo")
      assert ext.version == "0.1.0"
      assert {:ok, entry} = Handbean.Tool.Registry.get("ext__hotdemo__ping")
      assert {:ok, ":from-other"} = entry.executor.(%{}, %{})
    end)
  end

  test "watcher reloads after extension files change", %{tmp: tmp, registry: registry} do
    write_entry_extension!(tmp, "hotdemo", version: "0.1.0", result: ":v1")

    {:ok, _} =
      ExtensionBridge.load_and_integrate(
        project: tmp,
        user_home: Path.join(tmp, "no-user"),
        ext_registry: registry
      )

    {:ok, pid} =
      HotReloader.start_link(
        name: :"hot_reload_watch_#{System.unique_integer([:positive])}",
        project: tmp,
        user_home: Path.join(tmp, "no-user"),
        ext_registry: registry,
        trusted_project?: true,
        debounce_ms: 50
      )

    assert Process.alive?(pid)
    watcher = :sys.get_state(pid).watcher
    assert is_pid(watcher)
    assert pid in (:sys.get_state(watcher).subscribers |> Map.values())
    :ok = FileSystem.subscribe(watcher)

    write_entry_extension!(tmp, "hotdemo", version: "0.2.0", result: ":v2")
    assert_receive {:file_event, ^watcher, {_path, _events}}, 5_000

    assert_eventually(fn ->
      assert {:ok, reloaded} = ExtRegistry.get(registry, "hotdemo")
      assert reloaded.version == "0.2.0"
      assert {:ok, entry} = Handbean.Tool.Registry.get("ext__hotdemo__ping")
      assert {:ok, ":v2"} = entry.executor.(%{}, %{})
    end)
  end

  test "user extension file events reload safely when project is untrusted", %{
    tmp: tmp,
    registry: registry
  } do
    user_home = Path.join(tmp, "user-home")
    File.mkdir_p!(user_home)

    write_entry_extension!(user_home, "hotdemo", version: "0.1.0", result: ":user-v1")
    write_entry_extension!(tmp, "projdemo", version: "0.1.0", result: ":proj-v1")

    {:ok, pid} =
      HotReloader.start_link(
        name: :"hot_reload_untrusted_user_event_#{System.unique_integer([:positive])}",
        project: tmp,
        user_home: user_home,
        ext_registry: registry,
        enabled: true,
        preload: true,
        trusted_project?: false,
        debounce_ms: 20
      )

    state = :sys.get_state(pid)
    assert state.project == nil
    assert {:ok, ext} = ExtRegistry.get(registry, "hotdemo")
    assert ext.version == "0.1.0"
    assert {:error, :not_found} = ExtRegistry.get(registry, "projdemo")

    write_entry_extension!(user_home, "hotdemo", version: "0.2.0", result: ":user-v2")

    state_file = Path.join(user_home, ".handbean/extensions/hotdemo/state.json")
    File.write!(state_file, ~s({"status":"ok"}))
    send(pid, {:file_event, state.watcher, {state_file, [:modified, :renamed]}})

    assert_eventually(fn ->
      assert Process.alive?(pid)
      assert {:ok, reloaded} = ExtRegistry.get(registry, "hotdemo")
      assert reloaded.version == "0.2.0"
      assert {:ok, entry} = Handbean.Tool.Registry.get("ext__hotdemo__ping")
      assert {:ok, ":user-v2"} = entry.executor.(%{}, %{})
      assert {:error, :not_found} = ExtRegistry.get(registry, "projdemo")
    end)
  end

  test "file events in sibling directories with similar prefixes do not schedule reload", %{
    tmp: tmp,
    registry: registry
  } do
    user_home = Path.join(tmp, "user-home")
    File.mkdir_p!(user_home)

    {:ok, pid} =
      HotReloader.start_link(
        name: :"hot_reload_prefix_boundary_#{System.unique_integer([:positive])}",
        project: tmp,
        user_home: user_home,
        ext_registry: registry,
        enabled: false,
        preload: false,
        trusted_project?: true,
        debounce_ms: 60_000
      )

    send(
      pid,
      {:file_event, self(),
       {Path.join(user_home, ".handbean/extensions-backup/hotdemo/state.json"), [:modified]}}
    )

    send(
      pid,
      {:file_event, self(),
       {Path.join(tmp, ".handbean/extensions-backup/hotdemo/extension.json"), [:modified]}}
    )

    assert %{timer: nil} = :sys.get_state(pid)

    send(
      pid,
      {:file_event, self(),
       {Path.join(user_home, ".handbean/extensions/hotdemo/state.json"), [:modified]}}
    )

    assert %{timer: timer} = :sys.get_state(pid)
    assert is_reference(timer)
  end

  defmodule BlockingProvider do
    @behaviour Handbean.Agent.Provider

    @impl true
    def complete(_messages, _tool_defs, config) do
      send(Map.fetch!(config, :notify), {:hot_reload_provider_started, self()})

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

  defp write_full_extension!(tmp, name, result) do
    ext_dir = Path.join(tmp, ".handbean/extensions/#{name}")
    module_name = Macro.camelize(name)
    File.mkdir_p!(ext_dir)

    File.write!(
      Path.join(ext_dir, "extension.json"),
      Handbean.JSON.encode!(%{
        "name" => name,
        "entry" => "full.ex",
        "tools" => [%{"name" => "ping"}],
        "hooks" => ["before_agent_start"],
        "commands" => [%{"name" => "echo"}],
        "providers" => [%{"name" => "model", "models" => [%{"id" => "chat"}]}]
      })
    )

    File.write!(Path.join(ext_dir, "full.ex"), """
    defmodule Ext.#{module_name}.Ping do
      @behaviour Handbean.Agent.Tool
      def name, do: "ext__#{name}__ping"
      def description, do: "full fixture"
      def input_schema, do: %{"type" => "object", "properties" => %{}}
      def execute(_input, _context), do: {:ok, #{inspect(result)}}
    end

    defmodule Ext.#{module_name}.Hook do
      @behaviour Handbean.Extension.Hook
      def handle_event(_event, _context), do: :ok
    end

    defmodule Ext.#{module_name}.Worker do
      use Agent
      def child_spec(_opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}}
      def start_link(opts), do: Agent.start_link(fn -> opts end)
    end

    defmodule Ext.#{module_name}.Command do
      @behaviour Handbean.Extension.Command
      def name, do: "/ext:#{name}:echo"
      def execute(args, _context), do: {:ok, args}
    end

    defmodule Ext.#{module_name}.Provider do
      @behaviour Handbean.Extension.Provider
      def name, do: "ext:#{name}:model"
      def complete(_messages, _tools, _config), do: {:error, "unused"}
    end
    """)

    ext_dir
  end

  defp write_entry_extension!(tmp, name, opts) do
    version = Keyword.fetch!(opts, :version)
    result = Keyword.fetch!(opts, :result)
    description = Keyword.get(opts, :description, "hot reload ping")
    ext_dir = Path.join(tmp, ".handbean/extensions/#{name}")
    File.mkdir_p!(ext_dir)

    File.write!(
      Path.join(ext_dir, "extension.json"),
      Jason.encode!(%{
        "name" => name,
        "version" => version,
        "entry" => "hot_demo.ex",
        "tools" => [%{"name" => "ping"}]
      })
    )

    File.write!(
      Path.join(ext_dir, "hot_demo.ex"),
      """
      defmodule Ext.Hotdemo.Ping do
        @behaviour Handbean.Agent.Tool

        def name, do: "ext__hotdemo__ping"
        def description, do: #{inspect(description)}
        def input_schema, do: %{"type" => "object", "properties" => %{}}
        def execute(_input, _context), do: {:ok, #{inspect(result)}}
      end
      """
    )

    ext_dir
  end

  defp write_tool_hook_extension!(tmp, name, opts) do
    include_tool = Keyword.fetch!(opts, :include_tool)
    include_hook = Keyword.fetch!(opts, :include_hook)
    ext_dir = Path.join(tmp, ".handbean/extensions/#{name}")
    File.mkdir_p!(ext_dir)

    File.write!(
      Path.join(ext_dir, "extension.json"),
      Jason.encode!(%{
        "name" => name,
        "version" => "0.1.0",
        "entry" => "hot_cleanup.ex",
        "tools" => if(include_tool, do: [%{"name" => "ping"}], else: []),
        "hooks" => if(include_hook, do: ["before_agent_start"], else: [])
      })
    )

    source =
      """
      #{if include_tool do
        """
        defmodule Ext.Hotdemo.Ping do
          @behaviour Handbean.Agent.Tool
          def name, do: "ext__hotdemo__ping"
          def description, do: "cleanup ping"
          def input_schema, do: %{"type" => "object", "properties" => %{}}
          def execute(_input, _context), do: {:ok, :ping}
        end
        """
      else
        ""
      end}
      #{if include_hook do
        """
        defmodule Ext.Hotdemo.Hook do
          @behaviour Handbean.Extension.Hook
          def handle_event(_event, _ctx), do: :ok
        end
        """
      else
        ""
      end}
      """

    File.write!(Path.join(ext_dir, "hot_cleanup.ex"), source)
    ext_dir
  end

  defp write_hook_extension!(tmp, name) do
    ext_dir = Path.join(tmp, ".handbean/extensions/#{name}")
    File.mkdir_p!(ext_dir)

    File.write!(
      Path.join(ext_dir, "extension.json"),
      Jason.encode!(%{
        "name" => name,
        "version" => "0.1.0",
        "entry" => "hot_hook.ex",
        "hooks" => ["before_agent_start"],
        "tools" => []
      })
    )

    File.write!(
      Path.join(ext_dir, "hot_hook.ex"),
      """
      defmodule Ext.Hotdemo.Hook do
        @behaviour Handbean.Extension.Hook

        def handle_event(_event, _ctx), do: :ok
      end
      """
    )

    ext_dir
  end

  defp write_combined_extension!(tmp, name, opts) do
    result = Keyword.fetch!(opts, :result)
    code = Keyword.fetch!(opts, :code)
    ext_dir = Path.join(tmp, ".handbean/extensions/#{name}")
    File.mkdir_p!(ext_dir)

    File.write!(
      Path.join(ext_dir, "extension.json"),
      Jason.encode!(%{
        "name" => name,
        "version" => "0.1.0",
        "entry" => "hot_combo.ex",
        "tools" => [%{"name" => "ping"}]
      })
    )

    File.write!(
      Path.join(ext_dir, "hot_combo.ex"),
      """
      defmodule Ext.Hotdemo.Ping do
        @behaviour Handbean.Agent.Tool

        def name, do: "ext__hotdemo__ping"
        def description, do: "hot reload ping"
        def input_schema, do: %{"type" => "object", "properties" => %{}}
        def execute(_input, _context), do: {:ok, #{inspect(result)}}
      end

      defmodule Ext.Hotdemo.Worker do
        use GenServer

        def child_spec(_opts) do
          %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}, type: :worker}
        end

        def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
        def started_as, do: GenServer.call(__MODULE__, :started_as)
        def code_version, do: #{inspect(code)}
        def init(_opts), do: {:ok, #{inspect(code)}}
        def handle_call(:started_as, _from, state), do: {:reply, state, state}
      end
      """
    )

    ext_dir
  end

  defp write_worker_extension!(tmp, name, opts) do
    code = Keyword.fetch!(opts, :code)
    ext_dir = Path.join(tmp, ".handbean/extensions/#{name}")
    File.mkdir_p!(ext_dir)

    File.write!(
      Path.join(ext_dir, "extension.json"),
      Jason.encode!(%{
        "name" => name,
        "version" => "0.1.0",
        "entry" => "hot_worker.ex",
        "tools" => []
      })
    )

    File.write!(
      Path.join(ext_dir, "hot_worker.ex"),
      """
      defmodule Ext.Hotdemo.Worker do
        use GenServer

        def child_spec(_opts) do
          %{
            id: __MODULE__,
            start: {__MODULE__, :start_link, [[]]},
            type: :worker
          }
        end

        def start_link(opts) do
          GenServer.start_link(__MODULE__, opts, name: __MODULE__)
        end

        def started_as, do: GenServer.call(__MODULE__, :started_as)
        def code_version, do: #{inspect(code)}

        def init(_opts), do: {:ok, #{inspect(code)}}

        def handle_call(:started_as, _from, state), do: {:reply, state, state}
      end
      """
    )

    ext_dir
  end

  defp assert_eventually(fun, attempts \\ 40)

  defp assert_eventually(fun, 0), do: fun.()

  defp assert_eventually(fun, attempts) do
    fun.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
  end
end
