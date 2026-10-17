defmodule Handbean.Agent.ExtensionBridgeTest do
  use ExUnit.Case, async: false

  alias Handbean.Agent.ExtensionBridge
  alias Handbean.Extension.Registry, as: ExtRegistry

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
