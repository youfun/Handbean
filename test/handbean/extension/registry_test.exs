defmodule Handbean.Extension.RegistryTest do
  use ExUnit.Case, async: false

  alias Handbean.Extension.Registry

  defp build_ext(name, opts \\ []) do
    %Handbean.Extension{
      name: name,
      version: Keyword.get(opts, :version, "0.1.0"),
      enabled: Keyword.get(opts, :enabled, true),
      root: "/abs/path/.handbean/extensions/#{name}",
      hooks: Keyword.get(opts, :hooks, []),
      tools: Keyword.get(opts, :tools, []),
      commands: Keyword.get(opts, :commands, []),
      providers: Keyword.get(opts, :providers, []),
      permissions: %{},
      metadata: %{},
      entry: nil,
      description: nil
    }
  end

  defp start_registry do
    name = :"test_registry_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Registry.start_link(name: name)
    name
  end

  describe "register/2" do
    test "registers an extension" do
      registry = start_registry()
      ext = build_ext("test-ext")
      assert :ok = Registry.register(registry, ext)
      assert {:ok, ^ext} = Registry.get(registry, "test-ext")
    end

    test "duplicate register returns diagnostic" do
      registry = start_registry()
      ext = build_ext("test-ext")
      assert :ok = Registry.register(registry, ext)
      assert {:error, diagnostic} = Registry.register(registry, ext)
      assert diagnostic.type == :collision
    end

    test "duplicate register uses override with opts" do
      registry = start_registry()
      ext1 = build_ext("test-ext", version: "0.1.0")
      ext2 = build_ext("test-ext", version: "0.2.0")

      assert :ok = Registry.register(registry, ext1)
      assert :ok = Registry.register(registry, ext2, override: true)

      {:ok, ext} = Registry.get(registry, "test-ext")
      assert ext.version == "0.2.0"
    end
  end

  describe "list/1" do
    test "lists all registered extensions" do
      registry = start_registry()
      ext1 = build_ext("ext-a")
      ext2 = build_ext("ext-b")

      Registry.register(registry, ext1)
      Registry.register(registry, ext2)

      all = Registry.list(registry)
      assert length(all) == 2
    end

    test "empty registry returns empty list" do
      registry = start_registry()
      assert Registry.list(registry) == []
    end
  end

  describe "list_active/1" do
    test "excludes disabled extensions" do
      registry = start_registry()
      ext_active = build_ext("active-ext", enabled: true)
      ext_disabled = build_ext("disabled-ext", enabled: false)

      Registry.register(registry, ext_active)
      Registry.register(registry, ext_disabled)

      active = Registry.list_active(registry)
      assert length(active) == 1
      assert hd(active).name == "active-ext"
    end

    test "all enabled are active" do
      registry = start_registry()
      Registry.register(registry, build_ext("ext1", enabled: true))
      Registry.register(registry, build_ext("ext2", enabled: true))
      assert length(Registry.list_active(registry)) == 2
    end
  end

  describe "get/2" do
    test "returns extension by name" do
      registry = start_registry()
      ext = build_ext("test-ext")
      Registry.register(registry, ext)
      assert {:ok, ^ext} = Registry.get(registry, "test-ext")
    end

    test "returns error for unknown extension" do
      registry = start_registry()
      assert {:error, :not_found} = Registry.get(registry, "nonexistent")
    end
  end

  describe "unregister/2" do
    test "removes an extension" do
      registry = start_registry()
      ext = build_ext("test-ext")
      Registry.register(registry, ext)
      assert :ok = Registry.unregister(registry, "test-ext")
      assert {:error, :not_found} = Registry.get(registry, "test-ext")
    end

    test "unregistering nonexistent extension returns ok" do
      registry = start_registry()
      assert :ok = Registry.unregister(registry, "nonexistent")
    end
  end

  describe "reset/1" do
    test "clears all extensions" do
      registry = start_registry()
      Registry.register(registry, build_ext("ext1"))
      Registry.register(registry, build_ext("ext2"))
      Registry.reset(registry)
      assert Registry.list(registry) == []
    end
  end

  describe "list_hooks_by_event/2" do
    test "returns extensions that subscribe to an event" do
      registry = start_registry()
      ext1 = build_ext("ext1", hooks: ["agent_start", "tool_start"])
      ext2 = build_ext("ext2", hooks: ["agent_end"])
      ext3 = build_ext("ext3", hooks: ["tool_start", "tool_end"])

      Registry.register(registry, ext1)
      Registry.register(registry, ext2)
      Registry.register(registry, ext3)

      hooks = Registry.list_hooks_by_event(registry, "tool_start")
      names = Enum.map(hooks, & &1.name)
      assert "ext1" in names
      assert "ext3" in names
      refute "ext2" in names
    end

    test "returns empty for unsubscribed event" do
      registry = start_registry()
      ext = build_ext("ext1", hooks: ["agent_start"])
      Registry.register(registry, ext)
      assert Registry.list_hooks_by_event(registry, "turn_end") == []
    end
  end

  describe "list_declared_tools/1" do
    test "returns tools from all active extensions" do
      registry = start_registry()

      ext1 =
        build_ext("ext1",
          enabled: true,
          tools: [%{"name" => "tool_a", "description" => "Tool A"}]
        )

      ext2 =
        build_ext("ext2",
          enabled: true,
          tools: [%{"name" => "tool_b", "description" => "Tool B"}]
        )

      Registry.register(registry, ext1)
      Registry.register(registry, ext2)

      tools = Registry.list_declared_tools(registry)
      assert length(tools) == 2
    end

    test "excludes tools from disabled extensions" do
      registry = start_registry()
      ext = build_ext("disabled-ext", enabled: false, tools: [%{"name" => "hidden_tool"}])
      Registry.register(registry, ext)
      assert Registry.list_declared_tools(registry) == []
    end
  end

  describe "list_declared_commands/1" do
    test "returns commands from active extensions" do
      registry = start_registry()

      ext =
        build_ext("ext1",
          enabled: true,
          commands: [%{"name" => "mycmd", "description" => "My command"}]
        )

      Registry.register(registry, ext)
      cmds = Registry.list_declared_commands(registry)
      assert length(cmds) == 1
    end
  end

  describe "list_declared_providers/1" do
    test "returns providers from active extensions" do
      registry = start_registry()

      ext =
        build_ext("ext1",
          enabled: true,
          providers: [%{"name" => "mock_provider", "base_url" => "http://localhost:8000"}]
        )

      Registry.register(registry, ext)
      providers = Registry.list_declared_providers(registry)
      assert length(providers) == 1
    end
  end

  describe "size/1" do
    test "returns count of registered extensions" do
      registry = start_registry()
      assert Registry.size(registry) == 0
      Registry.register(registry, build_ext("ext1"))
      assert Registry.size(registry) == 1
      Registry.register(registry, build_ext("ext2"))
      assert Registry.size(registry) == 2
    end
  end
end
