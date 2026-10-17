defmodule Handbean.ExtensionTest do
  use Handbean.DataCase, async: true

  alias Handbean.Extension
  alias Handbean.Extension.Manifest

  describe "new/2 - build from manifest" do
    test "builds extension struct with all fields" do
      manifest = %Manifest{
        name: "agent-notify",
        version: "0.1.0",
        description: "Post Handbean lifecycle events to AgentNotify.",
        entry: "extension.exs",
        enabled: true,
        permissions: %{
          "network" => ["http://localhost:8000"],
          "filesystem" => "workspace",
          "tools" => ["read"]
        },
        hooks: ["agent_start", "agent_end"],
        tools: [%{"name" => "notify_send", "description" => "Send a notification"}],
        commands: [%{"name" => "notify:send"}],
        providers: [%{"name" => "mock_provider"}],
        metadata: %{"custom" => "value"}
      }

      root = "/abs/path/.handbean/extensions/agent-notify"

      assert {:ok, ext} = Extension.new(manifest, root)
      assert ext.name == "agent-notify"
      assert ext.version == "0.1.0"
      assert ext.description == "Post Handbean lifecycle events to AgentNotify."
      assert ext.root == root
      assert ext.entry == "/abs/path/.handbean/extensions/agent-notify/extension.exs"
      assert ext.enabled == true
      assert ext.permissions["network"] == ["http://localhost:8000"]
      assert ext.hooks == ["agent_start", "agent_end"]
      assert ext.tools == [%{"name" => "notify_send", "description" => "Send a notification"}]
      assert ext.commands == [%{"name" => "notify:send"}]
      assert ext.providers == [%{"name" => "mock_provider"}]
      assert ext.metadata["custom"] == "value"
    end

    test "root must be an absolute path" do
      manifest = %Manifest{name: "test-ext"}

      assert {:error, diagnostic} = Extension.new(manifest, "relative/path")
      assert diagnostic.type == :validation_error
      assert diagnostic.message =~ "absolute"
    end

    test "entry defaults to nil when not in manifest" do
      manifest = %Manifest{name: "test-ext"}
      root = "/abs/path/.handbean/extensions/test-ext"

      assert {:ok, ext} = Extension.new(manifest, root)
      assert ext.entry == nil
    end

    test "entry is resolved relative to root" do
      manifest = %Manifest{name: "test-ext", entry: "lib/runner.exs"}
      root = "/abs/path/.handbean/extensions/test-ext"

      assert {:ok, ext} = Extension.new(manifest, root)
      assert ext.entry == "/abs/path/.handbean/extensions/test-ext/lib/runner.exs"
    end

    test "entry path traversal outside root is rejected" do
      manifest = %Manifest{name: "test-ext", entry: "../../etc/passwd"}
      root = "/abs/path/.handbean/extensions/test-ext"

      assert {:error, diagnostic} = Extension.new(manifest, root)
      assert diagnostic.type == :validation_error
      assert diagnostic.message =~ "outside root"
    end

    test "entry with absolute path outside root is rejected" do
      manifest = %Manifest{name: "test-ext", entry: "/etc/passwd"}
      root = "/abs/path/.handbean/extensions/test-ext"

      assert {:error, diagnostic} = Extension.new(manifest, root)
      assert diagnostic.type == :validation_error
    end

    test "disabled extension has enabled: false" do
      manifest = %Manifest{name: "test-ext", enabled: false}
      root = "/abs/path/.handbean/extensions/test-ext"

      assert {:ok, ext} = Extension.new(manifest, root)
      assert ext.enabled == false
    end

    test "extension with no entry has entry: nil" do
      manifest = %Manifest{name: "test-ext"}
      root = "/abs/path/.handbean/extensions/test-ext"

      assert {:ok, ext} = Extension.new(manifest, root)
      assert ext.entry == nil
    end

    test "empty lists default correctly" do
      manifest = %Manifest{name: "test-ext"}
      root = "/abs/path/.handbean/extensions/test-ext"

      assert {:ok, ext} = Extension.new(manifest, root)
      assert ext.hooks == []
      assert ext.tools == []
      assert ext.commands == []
      assert ext.providers == []
    end
  end

  describe "active?/1" do
    test "enabled extension is active" do
      manifest = %Manifest{name: "test-ext", enabled: true}
      {:ok, ext} = Extension.new(manifest, "/abs/path/.handbean/extensions/test-ext")
      assert Extension.active?(ext) == true
    end

    test "disabled extension is not active" do
      manifest = %Manifest{name: "test-ext", enabled: false}
      {:ok, ext} = Extension.new(manifest, "/abs/path/.handbean/extensions/test-ext")
      assert Extension.active?(ext) == false
    end
  end
end
