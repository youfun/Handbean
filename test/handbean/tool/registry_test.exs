defmodule Handbean.Tool.RegistryTest do
  @moduledoc """
  Tests for the tool registry GenServer.

  Reference: `alloy/` (Tool Registry pattern)
  Test pattern: hand-written

  Covers:
    - Registering tools
    - Retrieving tools by name
    - Listing registered tools
    - Generating tool definitions
    - Tool function lookups
  """

  use ExUnit.Case, async: false

  alias Handbean.Tool.Registry

  # Note: Handbean.Tool.Registry is a named GenServer shared across tests.
  # async:false ensures serial execution to avoid race conditions.

  setup do
    registry_state = :sys.get_state(Registry)
    snapshot_sync_id = "registry-test-sync-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      :sys.replace_state(Registry, fn _current -> registry_state end)
      Registry.set_active_for_session(snapshot_sync_id, nil)
    end)
  end

  describe "register/1" do
    test "registers a tool module" do
      mod = Handbean.Tool.Builtin.Read
      assert Registry.register(mod) == :ok
    end

    test "overwrites duplicate registration" do
      Registry.register(Handbean.Tool.Builtin.Read)
      # Second registration should succeed (with warning log)
      assert Registry.register(Handbean.Tool.Builtin.Read) == :ok
    end

    test "override: true replaces description and schema" do
      assert :ok = Registry.register(__MODULE__.OverrideProbeA)
      assert {:ok, first} = Registry.get("override_probe")
      assert first.description == "a"

      assert :ok = Registry.register(__MODULE__.OverrideProbeB)
      assert {:ok, kept} = Registry.get("override_probe")
      assert kept.description == "a"

      assert :ok = Registry.register(__MODULE__.OverrideProbeB, override: true)
      assert {:ok, replaced} = Registry.get("override_probe")
      assert replaced.description == "b"
      assert replaced.module == __MODULE__.OverrideProbeB
    after
      Registry.unregister("override_probe")
    end

    test "stores a trimmed hint and omits it when the tool defines none" do
      assert :ok = Registry.register(Handbean.Tool.Builtin.Edit, override: true)
      assert {:ok, edit} = Registry.get("edit")
      assert edit.hint =~ "Re-read the file"

      assert :ok = Registry.register(__MODULE__.OverrideProbeA, override: true)
      assert {:ok, probe} = Registry.get("override_probe")
      assert probe.hint == nil
    after
      Registry.unregister("override_probe")
    end
  end

  describe "owner-aware replacement" do
    test "an owner cannot remove or replace another owner's tool" do
      assert :ok = Registry.replace_owner(:owner_a, [__MODULE__.OverrideProbeA])

      assert {:error, {:tool_name_collision, "override_probe", :owner_a}} =
               Registry.replace_owner(:owner_b, [__MODULE__.OverrideProbeB])

      assert {:ok, entry} = Registry.get("override_probe")
      assert entry.meta.owner == :owner_a

      assert :ok = Registry.remove_owner(:owner_b)
      assert {:ok, _} = Registry.get("override_probe")
    after
      Registry.remove_owner(:owner_a)
      Registry.remove_owner(:owner_b)
    end
  end

  describe "concurrent snapshots" do
    test "keeps reads available while the single write owner is busy and publishes replace_owner atomically" do
      owner = {:snapshot_test, System.unique_integer([:positive])}
      session_id = "snapshot-session-#{System.unique_integer([:positive])}"
      old_names = MapSet.new(["snapshot_old_a", "snapshot_old_b"])
      new_names = MapSet.new(["snapshot_new_a", "snapshot_new_b"])

      assert :ok =
               Registry.replace_owner(owner, [__MODULE__.SnapshotOldA, __MODULE__.SnapshotOldB])

      assert :ok =
               Registry.set_active_for_session(
                 session_id,
                 MapSet.to_list(MapSet.union(old_names, new_names))
               )

      Process.register(self(), __MODULE__.RegistrySnapshotProbe)

      on_exit(fn ->
        if Process.whereis(__MODULE__.RegistrySnapshotProbe) == self() do
          Process.unregister(__MODULE__.RegistrySnapshotProbe)
        end

        Registry.remove_owner(owner)
      end)

      replacement =
        Task.async(fn ->
          Registry.replace_owner(owner, [__MODULE__.SnapshotNewA, __MODULE__.SnapshotNewB])
        end)

      assert_receive {:building_snapshot_replacement, registry_pid}

      read =
        Task.async(fn ->
          tools = Registry.tool_fns()

          %{
            get: Registry.get("snapshot_old_a"),
            list: Registry.list() |> MapSet.new() |> MapSet.intersection(old_names),
            fns: tools |> Map.keys() |> MapSet.new() |> MapSet.intersection(old_names),
            defs: Registry.tool_defs() |> names() |> MapSet.intersection(old_names),
            deferred_catalog: Registry.deferred_catalog(),
            active: Registry.active_for_session(session_id),
            session_defs:
              session_id
              |> Registry.tool_defs_for_session()
              |> names()
              |> MapSet.intersection(old_names),
            prompt: Registry.prompt_snippets(),
            session_prompt: Registry.prompt_snippets_for_session(session_id)
          }
        end)

      try do
        assert {:ok, observed} = Task.yield(read, 1_000) || Task.shutdown(read, :brutal_kill)
        assert match?({:ok, %{name: "snapshot_old_a"}}, observed.get)
        assert observed.list == old_names
        assert observed.fns == old_names
        assert observed.defs == old_names
        assert is_list(observed.deferred_catalog)
        assert MapSet.new(observed.active) == MapSet.union(old_names, new_names)
        assert observed.session_defs == old_names
        assert observed.prompt =~ "snapshot_old_a"
        assert observed.session_prompt =~ "snapshot_old_a"
        refute observed.session_prompt =~ "snapshot_new_a"
      after
        send(registry_pid, :continue_snapshot_replacement)
      end

      assert :ok = Task.await(replacement)
      tools = Registry.tool_fns()
      assert MapSet.disjoint?(MapSet.new(Map.keys(tools)), old_names)
      assert MapSet.subset?(new_names, MapSet.new(Map.keys(tools)))
      assert Registry.tool_defs_for_session(session_id) |> names() == new_names
    end

    test "uses a protected ETS table owned by the registry process" do
      assert :ets.info(Registry, :protection) == :protected
      assert :ets.info(Registry, :owner) == Process.whereis(Registry)
      refute :ets.info(Registry, :write_concurrency)
      assert :ets.info(Registry, :read_concurrency)
    end

    test "does not serve a stale snapshot while the registry is stopped or after restart" do
      assert :ok = Registry.register(__MODULE__.SnapshotOldA, override: true)
      registry_pid = Process.whereis(Registry)
      monitor_ref = Process.monitor(registry_pid)

      on_exit(fn ->
        unless Process.whereis(Registry) do
          {:ok, _pid} = Supervisor.restart_child(Handbean.Supervisor, Registry)
        end
      end)

      assert :ok = Supervisor.terminate_child(Handbean.Supervisor, Registry)
      assert_receive {:DOWN, ^monitor_ref, :process, ^registry_pid, :shutdown}
      assert :ets.whereis(Registry) == :undefined
      assert {:noproc, _details} = catch_exit(Registry.get("snapshot_old_a"))

      assert {:ok, restarted_pid} = Supervisor.restart_child(Handbean.Supervisor, Registry)
      assert Process.whereis(Registry) == restarted_pid
      assert Registry.get("snapshot_old_a") == :error
    end
  end

  describe "host_tool_modules/0" do
    setup do
      previous = Application.get_env(:handbean, :host)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:handbean, :host, previous),
          else: Application.delete_env(:handbean, :host)
      end)

      :ok
    end

    test "desktop host seeds browser and not preview_serve" do
      Application.delete_env(:handbean, :host)
      names = Enum.map(Registry.host_tool_modules(), & &1.name())
      assert "browser" in names
      refute "mix_project" in names
      refute "git" in names
      assert "bash" in names
      for tool <- ~w(web_fetch skill task job_status job_cancel), do: assert(tool in names)
      refute "preview_serve" in names
      assert :ok = Registry.register(Handbean.Tool.Builtin.Browser)
      assert {:ok, entry} = Registry.get("browser")
      assert entry.module == Handbean.Tool.Builtin.Browser
      refute "run_elixir_script" in names
    end

    test "webview host seeds browser and preview_serve only for declared backends" do
      Handbean.Host.put!(%{
        shell: false,
        browser_backend: :webview,
        artifact_delivery_backend: Handbean.ArtifactDelivery,
        host_script: true,
        beam_eval: false,
        packaged_mix_toolchain: true
      })

      mods = Registry.host_tool_modules()
      names = Enum.map(mods, & &1.name())
      assert "browser" in names
      assert "preview_serve" in names
      assert "open_url" in names
      assert "open_file" in names
      assert "share_file" in names
      assert "run_elixir_script" in names

      for tool <- ~w(web_fetch skill task job_status job_cancel create_thread send_thread_message),
          do: assert(tool in names)

      assert "mix_project" in names
      refute "git" in names
      refute "bash" in names

      Enum.each(mods, &Registry.register/1)
      assert match?({:ok, %{module: Handbean.Tool.Builtin.Browser}}, Registry.get("browser"))

      assert match?(
               {:ok, %{module: Handbean.Tool.Builtin.PreviewServe}},
               Registry.get("preview_serve")
             )

      assert match?(
               {:ok, %{module: Handbean.Tool.Builtin.OpenUrl}},
               Registry.get("open_url")
             )

      assert match?(
               {:ok, %{module: Handbean.Tool.Builtin.RunElixirScript}},
               Registry.get("run_elixir_script")
             )
    end

    test "host-provided Git backend enables the builtin git tool" do
      Handbean.Host.put!(%{
        shell: false,
        browser_backend: :webview,
        git_backend: Handbean.Git.CLI
      })

      names = Enum.map(Registry.host_tool_modules(), & &1.name())
      assert "git" in names
      refute "bash" in names
    end
  end

  describe "get/1" do
    test "retrieves a registered tool by name" do
      Registry.register(Handbean.Tool.Builtin.Read)
      {:ok, tool} = Registry.get("read")
      assert tool.module == Handbean.Tool.Builtin.Read
      assert tool.name == "read"
      assert is_function(tool.executor, 2)
    end

    test "returns :error for unregistered tool" do
      assert Registry.get("nonexistent") == :error
    end
  end

  describe "list/0" do
    test "returns all registered tool names" do
      Registry.register(Handbean.Tool.Builtin.Read)
      Registry.register(Handbean.Tool.Builtin.Bash)

      names = Registry.list()
      assert "read" in names
      assert "bash" in names
    end

    test "returns the name of a tool registered in this test" do
      Registry.register(Handbean.Tool.Builtin.Grep)
      assert "grep" in Registry.list()
    end
  end

  describe "tool_defs/0" do
    test "returns tool definitions for providers" do
      Registry.register(Handbean.Tool.Builtin.Read)

      defs = Registry.tool_defs()
      assert length(defs) >= 1

      read_def = Enum.find(defs, &(&1.name == "read"))
      assert read_def != nil
      assert is_binary(read_def.description)
      assert is_map(read_def.input_schema)
    end
  end

  describe "tool_fns/0" do
    test "returns function lookup map" do
      Registry.register(Handbean.Tool.Builtin.Read)
      Registry.register(Handbean.Tool.Builtin.Bash)

      fns = Registry.tool_fns()

      {:ok, read_tool} = Map.fetch(fns, "read")
      assert read_tool.module == Handbean.Tool.Builtin.Read
      assert read_tool.name == "read"
      assert is_function(read_tool.executor, 2)

      {:ok, bash_tool} = Map.fetch(fns, "bash")
      assert bash_tool.module == Handbean.Tool.Builtin.Bash
      assert bash_tool.name == "bash"
      assert is_function(bash_tool.executor, 2)
    end
  end

  describe "BEAM tool registration from workspace settings" do
    defp tmp_workspace do
      dir =
        Path.join(System.tmp_dir!(), "sigil_registry_beam_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)

      on_exit(fn -> File.rm_rf(dir) end)

      dir
    end

    defp write_settings(workspace, content) do
      path = Handbean.WorkspaceSettings.path(workspace)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end

    setup do
      Registry.reset()
      :ok
    end

    test "registers docs/source/db_schema/sql for Elixir projects by default" do
      workspace = tmp_workspace()
      File.write!(Path.join(workspace, "mix.exs"), "defmodule Demo.MixProject do end")

      assert {:ok, _state} =
               Handbean.Agent.run("hello",
                 provider: Handbean.TestSupport.FakeProvider,
                 provider_config: %{scenario: :simple_answer},
                 model: "fake",
                 working_directory: workspace,
                 mcp: false
               )

      names = Registry.list()
      assert "ext__beam__docs" in names
      assert "ext__beam__source" in names
      assert "ext__beam__db_schema" in names
      assert "ext__beam__sql" in names
      refute "ext__beam__eval" in names
    end

    test "does not append BEAM tools to an explicit tool list" do
      workspace = tmp_workspace()
      File.write!(Path.join(workspace, "mix.exs"), "defmodule Demo.MixProject do end")

      assert {:ok, _state} =
               Handbean.Agent.run("hello",
                 tools: [Handbean.Tool.Builtin.Read],
                 provider: Handbean.TestSupport.FakeProvider,
                 provider_config: %{scenario: :simple_answer},
                 model: "fake",
                 working_directory: workspace,
                 mcp: false
               )

      names = Registry.list()
      assert "read" in names
      refute "ext__beam__docs" in names
      refute "ext__beam__db_schema" in names
      refute "ext__beam__sql" in names
    end

    test "does not auto-register BEAM tools when tools.beam.auto is false" do
      workspace = tmp_workspace()
      File.write!(Path.join(workspace, "mix.exs"), "defmodule Demo.MixProject do end")

      write_settings(workspace, """
      {
        "tools": {
          "beam": {
            "auto": false,
            "eval": false,
          },
        },
      }
      """)

      assert {:ok, _state} =
               Handbean.Agent.run("hello",
                 provider: Handbean.TestSupport.FakeProvider,
                 provider_config: %{scenario: :simple_answer},
                 model: "fake",
                 working_directory: workspace,
                 mcp: false
               )

      names = Registry.list()
      refute "ext__beam__docs" in names
      refute "ext__beam__source" in names
      refute "ext__beam__db_schema" in names
      refute "ext__beam__sql" in names
      refute "ext__beam__eval" in names
    end

    test "registers eval only when enabled or explicitly listed" do
      previous_host = Application.get_env(:handbean, :host)
      Handbean.Host.put!(Map.put(previous_host || %{}, :beam_eval, true))

      on_exit(fn ->
        if previous_host,
          do: Application.put_env(:handbean, :host, previous_host),
          else: Application.delete_env(:handbean, :host)
      end)

      workspace = tmp_workspace()

      write_settings(workspace, """
      {
        "tools": {
          "beam": {
            "auto": false,
            "eval": true,
          },
        },
      }
      """)

      assert {:ok, _state} =
               Handbean.Agent.run("hello",
                 provider: Handbean.TestSupport.FakeProvider,
                 provider_config: %{scenario: :simple_answer},
                 model: "fake",
                 working_directory: workspace,
                 mcp: false
               )

      assert "ext__beam__eval" in Registry.list()
    end
  end

  defmodule OverrideProbeA do
    @behaviour Handbean.Agent.Tool

    def name, do: "override_probe"
    def description, do: "a"
    def input_schema, do: %{"type" => "object", "properties" => %{}}
    def execute(_input, _context), do: {:ok, "a"}
  end

  defmodule OverrideProbeB do
    @behaviour Handbean.Agent.Tool

    def name, do: "override_probe"
    def description, do: "b"
    def input_schema, do: %{"type" => "object", "properties" => %{"x" => %{}}}
    def execute(_input, _context), do: {:ok, "b"}
  end

  defmodule NestedOnlyProbe do
    @behaviour Handbean.Agent.Tool

    def name, do: "nested_only_probe"
    def description, do: "secret nested probe"
    def input_schema, do: %{"type" => "object", "properties" => %{}}
    def nested_only?, do: true
    def execute(_input, _context), do: {:ok, "nested"}
  end

  defmodule SnapshotOldA do
    @behaviour Handbean.Agent.Tool

    def name, do: "snapshot_old_a"
    def description, do: "old a"
    def input_schema, do: %{"type" => "object", "properties" => %{}}
    def execute(_input, _context), do: {:ok, "old a"}
  end

  defmodule SnapshotOldB do
    @behaviour Handbean.Agent.Tool

    def name, do: "snapshot_old_b"
    def description, do: "old b"
    def input_schema, do: %{"type" => "object", "properties" => %{}}
    def execute(_input, _context), do: {:ok, "old b"}
  end

  defmodule SnapshotNewA do
    @behaviour Handbean.Agent.Tool

    def name, do: "snapshot_new_a"

    def description do
      if probe = Process.whereis(Handbean.Tool.RegistryTest.RegistrySnapshotProbe) do
        send(probe, {:building_snapshot_replacement, self()})

        receive do
          :continue_snapshot_replacement -> :ok
        end
      end

      "new a"
    end

    def input_schema, do: %{"type" => "object", "properties" => %{}}
    def execute(_input, _context), do: {:ok, "new a"}
  end

  defmodule SnapshotNewB do
    @behaviour Handbean.Agent.Tool

    def name, do: "snapshot_new_b"
    def description, do: "new b"
    def input_schema, do: %{"type" => "object", "properties" => %{}}
    def execute(_input, _context), do: {:ok, "new b"}
  end

  defp names(definitions), do: MapSet.new(definitions, & &1.name)

  describe "entries from before deferred?" do
    test "a tool map without deferred? stays eager and does not crash the registry" do
      stale = %{
        kind: :virtual,
        name: "stale_before_deferred",
        description: "registered before deferred?",
        input_schema: %{"type" => "object"},
        module: nil,
        executor: fn _input, _context -> {:ok, "ok"} end,
        max_result_chars: :unlimited,
        concurrent?: true,
        timeout_ms: nil,
        hint: nil,
        nested_only?: false,
        meta: %{}
      }

      :sys.replace_state(Registry, fn state ->
        %{state | tools: Map.put(state.tools, stale.name, stale)}
      end)

      Registry.set_active_for_session(
        "stale-snapshot-sync-#{System.unique_integer([:positive])}",
        nil
      )

      refute Enum.any?(Registry.deferred_catalog(), &(&1.name == stale.name))
      assert Enum.any?(Registry.tool_defs(), &(&1.name == stale.name))
      assert Registry.prompt_snippets() =~ stale.name
    end
  end

  describe "nested-only exposure" do
    test "omits nested-only module and virtual tools from provider defs and prompt snippets" do
      assert :ok = Registry.register(Handbean.Tool.Builtin.Read)
      assert :ok = Registry.register(NestedOnlyProbe)

      assert :ok =
               Registry.register_virtual(
                 "virtual_nested_probe",
                 "hidden virtual",
                 %{},
                 fn _input, _context -> {:ok, "virtual"} end,
                 nested_only?: true
               )

      assert {:ok, %{nested_only?: true}} = Registry.get("nested_only_probe")
      assert {:ok, %{nested_only?: true}} = Registry.get("virtual_nested_probe")
      assert "nested_only_probe" in Registry.list()

      refute Enum.any?(
               Registry.tool_defs(),
               &(&1.name in ["nested_only_probe", "virtual_nested_probe"])
             )

      session_id = "nested-session-#{System.unique_integer([:positive])}"
      :ok = Registry.set_active_for_session(session_id, ["nested_only_probe", "read"])

      session_defs = Registry.tool_defs_for_session(session_id)
      refute Enum.any?(session_defs, &(&1.name == "nested_only_probe"))
      assert Enum.any?(session_defs, &(&1.name == "read"))

      refute Registry.prompt_snippets() =~ "nested_only_probe"
      refute Registry.prompt_snippets() =~ "virtual_nested_probe"
      refute Registry.prompt_snippets() =~ "secret nested probe"
      refute Registry.prompt_snippets_for_session(session_id) =~ "nested_only_probe"
      assert Registry.prompt_snippets_for_session(session_id) =~ "read"
    after
      Registry.unregister("nested_only_probe")
      Registry.unregister("virtual_nested_probe")
    end
  end
end
