defmodule Handbean.Extension.ManifestTest do
  use Handbean.DataCase, async: true

  alias Handbean.Extension.Manifest

  describe "from_json/1 - valid manifests" do
    test "loads minimal valid manifest with only name" do
      json = ~s({"name": "agent-notify"})

      assert {:ok, manifest} = Manifest.from_json(json)
      assert manifest.name == "agent-notify"
      assert manifest.version == nil
      assert manifest.description == nil
      assert manifest.enabled == true
      assert manifest.permissions == %{"network" => [], "filesystem" => "none", "tools" => []}
      assert manifest.hooks == []
      assert manifest.tools == []
      assert manifest.commands == []
      assert manifest.providers == []
    end

    test "loads full manifest with all fields" do
      json = ~s"""
      {
        "name": "agent-notify",
        "version": "0.1.0",
        "description": "Post Handbean lifecycle events to AgentNotify.",
        "entry": "extension.exs",
        "enabled": true,
        "permissions": {
          "network": ["http://localhost:8000"],
          "filesystem": "workspace",
          "tools": ["read"]
        },
        "hooks": ["agent_start", "agent_end", "turn_end"],
        "tools": [
          {"name": "notify_send", "description": "Send a notification"}
        ],
        "commands": [
          {"name": "notify:send", "description": "Manual send"}
        ],
        "providers": [
          {"name": "mock_provider", "base_url": "http://localhost:8000"}
        ]
      }
      """

      assert {:ok, manifest} = Manifest.from_json(json)
      assert manifest.name == "agent-notify"
      assert manifest.version == "0.1.0"
      assert manifest.description == "Post Handbean lifecycle events to AgentNotify."
      assert manifest.entry == "extension.exs"
      assert manifest.enabled == true
      assert manifest.permissions["network"] == ["http://localhost:8000"]
      assert manifest.permissions["filesystem"] == "workspace"
      assert manifest.permissions["tools"] == ["read"]
      assert manifest.hooks == ["agent_start", "agent_end", "turn_end"]

      assert manifest.tools == [
               %{"name" => "notify_send", "description" => "Send a notification"}
             ]

      assert manifest.commands == [%{"name" => "notify:send", "description" => "Manual send"}]

      assert manifest.providers == [
               %{"name" => "mock_provider", "base_url" => "http://localhost:8000"}
             ]
    end

    test "enabled defaults to true when omitted" do
      json = ~s({"name": "test-ext"})

      assert {:ok, manifest} = Manifest.from_json(json)
      assert manifest.enabled == true
    end

    test "enabled can be explicitly false" do
      json = ~s({"name": "test-ext", "enabled": false})

      assert {:ok, manifest} = Manifest.from_json(json)
      assert manifest.enabled == false
    end

    test "permissions default to minimal when omitted" do
      json = ~s({"name": "test-ext"})

      assert {:ok, manifest} = Manifest.from_json(json)
      assert manifest.permissions == %{"network" => [], "filesystem" => "none", "tools" => []}
    end

    test "version is optional" do
      json = ~s({"name": "test-ext"})

      assert {:ok, manifest} = Manifest.from_json(json)
      assert manifest.version == nil
    end

    test "description is optional" do
      json = ~s({"name": "test-ext"})

      assert {:ok, manifest} = Manifest.from_json(json)
      assert manifest.description == nil
    end

    test "entry is optional" do
      json = ~s({"name": "test-ext"})

      assert {:ok, manifest} = Manifest.from_json(json)
      assert manifest.entry == nil
    end

    test "unknown fields are placed in metadata" do
      json = ~s({"name": "test-ext", "custom_field": "value", "another": 42})

      assert {:ok, manifest} = Manifest.from_json(json)
      assert manifest.metadata["custom_field"] == "value"
      assert manifest.metadata["another"] == 42
    end

    test "valid name: lowercase letters only" do
      json = ~s({"name": "myextension"})
      assert {:ok, _manifest} = Manifest.from_json(json)
    end

    test "valid name: lowercase with numbers" do
      json = ~s({"name": "ext123"})
      assert {:ok, _manifest} = Manifest.from_json(json)
    end

    test "valid name: lowercase with hyphens" do
      json = ~s({"name": "agent-notify"})
      assert {:ok, _manifest} = Manifest.from_json(json)
    end

    test "valid name: single character" do
      json = ~s({"name": "a"})
      assert {:ok, _manifest} = Manifest.from_json(json)
    end

    test "entry is stored as is (path resolution happens in loader)" do
      json = ~s({"name": "test-ext", "entry": "lib/extension.exs"})
      assert {:ok, manifest} = Manifest.from_json(json)
      assert manifest.entry == "lib/extension.exs"
    end
  end

  describe "from_json/1 - error cases" do
    test "missing name returns diagnostic" do
      json = ~s({"description": "no name here"})

      assert {:error, diagnostic} = Manifest.from_json(json)
      assert diagnostic.type == :validation_error
      assert diagnostic.message =~ "name"
    end

    test "nil name returns diagnostic" do
      json = ~s({"name": null})

      assert {:error, diagnostic} = Manifest.from_json(json)
      assert diagnostic.type == :validation_error
      assert diagnostic.message =~ "name"
    end

    test "empty string name returns diagnostic" do
      json = ~s({"name": ""})

      assert {:error, diagnostic} = Manifest.from_json(json)
      assert diagnostic.type == :validation_error
      assert diagnostic.message =~ "name"
    end

    test "name starting with hyphen returns diagnostic" do
      json = ~s({"name": "-invalid"})

      assert {:error, diagnostic} = Manifest.from_json(json)
      assert diagnostic.type == :validation_error
      assert diagnostic.message =~ "name"
    end

    test "name ending with hyphen returns diagnostic" do
      json = ~s({"name": "invalid-"})

      assert {:error, diagnostic} = Manifest.from_json(json)
      assert diagnostic.type == :validation_error
      assert diagnostic.message =~ "name"
    end

    test "name with consecutive hyphens returns diagnostic" do
      json = ~s({"name": "invalid--name"})

      assert {:error, diagnostic} = Manifest.from_json(json)
      assert diagnostic.type == :validation_error
      assert diagnostic.message =~ "name"
    end

    test "name with uppercase letters returns diagnostic" do
      json = ~s({"name": "InvalidExt"})

      assert {:error, diagnostic} = Manifest.from_json(json)
      assert diagnostic.type == :validation_error
    end

    test "name with special characters returns diagnostic" do
      json = ~s({"name": "invalid@ext"})

      assert {:error, diagnostic} = Manifest.from_json(json)
      assert diagnostic.type == :validation_error
    end

    test "name with spaces returns diagnostic" do
      json = ~s({"name": "invalid ext"})

      assert {:error, diagnostic} = Manifest.from_json(json)
      assert diagnostic.type == :validation_error
    end

    test "invalid JSON returns diagnostic" do
      json = ~s(not valid json at all)

      assert {:error, diagnostic} = Manifest.from_json(json)
      assert diagnostic.type == :parse_error
    end

    test "non-object JSON returns diagnostic" do
      json = ~s(["just", "an", "array"])

      assert {:error, diagnostic} = Manifest.from_json(json)
      assert diagnostic.type == :validation_error
    end
  end

  describe "validate_name/1" do
    test "returns ok for valid names" do
      assert :ok == Manifest.validate_name("a")
      assert :ok == Manifest.validate_name("abc")
      assert :ok == Manifest.validate_name("agent-notify")
      assert :ok == Manifest.validate_name("ext123")
    end

    test "returns error for invalid names" do
      for name <- ["", "-start", "end-", "double--dash", "UpperCase", "special@char"] do
        assert {:error, %{type: :validation_error}} = Manifest.validate_name(name)
      end
    end
  end
end
