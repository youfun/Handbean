defmodule Handbean.Extension.ToolSpecTest do
  use Handbean.DataCase, async: true

  alias Handbean.Extension.ToolSpec
  alias Handbean.Extension.CommandSpec
  alias Handbean.Extension.ProviderSpec

  describe "ToolSpec.new/3" do
    test "creates a valid tool spec" do
      assert {:ok, spec} =
               ToolSpec.new("agent-notify", "notify_send", %{
                 description: "Send a notification",
                 input_schema: %{
                   "type" => "object",
                   "properties" => %{"message" => %{"type" => "string"}}
                 }
               })

      assert spec.extension == "agent-notify"
      assert spec.name == "notify_send"
      assert spec.handbean_name == "ext__agent-notify__notify_send"
      assert spec.description == "Send a notification"
      assert spec.input_schema["type"] == "object"
    end

    test "generates namespace: ext__<extension>__<tool>" do
      {:ok, spec} = ToolSpec.new("my-ext", "my_tool", %{description: "desc"})
      assert spec.handbean_name == "ext__my-ext__my_tool"
    end

    test "rejects invalid extension name in tool spec" do
      assert {:error, diagnostic} = ToolSpec.new("", "tool", %{description: "desc"})
      assert diagnostic.type == :validation_error
    end

    test "rejects empty tool name" do
      assert {:error, %{type: :validation_error, message: "invalid tool name: " <> _}} =
               ToolSpec.new("my-ext", "", %{description: "desc"})
    end

    test "rejects nil tool name" do
      assert {:error, %{type: :validation_error, message: "tool name must not be nil"}} =
               ToolSpec.new("my-ext", nil, %{description: "desc"})
    end

    test "rejects tool name with invalid characters" do
      assert {:error, %{type: :validation_error, message: "invalid tool name: " <> _}} =
               ToolSpec.new("my-ext", "my tool!", %{description: "desc"})
    end

    test "description is optional" do
      assert {:ok, spec} = ToolSpec.new("my-ext", "my_tool", %{})
      assert spec.description == nil
    end

    test "input_schema defaults to empty map" do
      assert {:ok, spec} = ToolSpec.new("my-ext", "my_tool", %{})
      assert spec.input_schema == %{}
    end
  end

  describe "ToolSpec.to_provider_tool_def/1" do
    test "converts to provider tool definition" do
      {:ok, spec} =
        ToolSpec.new("agent-notify", "notify_send", %{
          description: "Send a notification",
          input_schema: %{"type" => "object", "properties" => %{}}
        })

      tool_def = ToolSpec.to_provider_tool_def(spec)
      assert tool_def.name == "ext__agent-notify__notify_send"
      assert tool_def.description == "Send a notification"
      assert tool_def.input_schema["type"] == "object"
    end

    test "defaults description to nil when not provided" do
      {:ok, spec} = ToolSpec.new("ext", "tool", %{})
      tool_def = ToolSpec.to_provider_tool_def(spec)
      assert tool_def.description == nil
    end
  end

  describe "ToolSpec.check_builtin_collision/1" do
    test "detects collision with known builtin tool names" do
      {:ok, spec} = ToolSpec.new("my-ext", "read", %{description: "custom read"})
      assert {:collision, "read"} = ToolSpec.check_builtin_collision(spec)
    end

    test "no collision for unique name" do
      {:ok, spec} = ToolSpec.new("my-ext", "my_unique_tool", %{description: "desc"})
      assert :ok = ToolSpec.check_builtin_collision(spec)
    end
  end

  describe "ToolSpec.validate_name/1" do
    test "valid names" do
      assert :ok == ToolSpec.validate_name("my_tool")
      assert :ok == ToolSpec.validate_name("read_file")
      assert :ok == ToolSpec.validate_name("tool_1")
    end

    test "invalid names" do
      assert {:error, %{message: "invalid tool name: " <> _}} = ToolSpec.validate_name("")
      assert {:error, %{message: "tool name must not be nil"}} = ToolSpec.validate_name(nil)

      assert {:error, %{message: "invalid tool name: \"my tool\"" <> _}} =
               ToolSpec.validate_name("my tool")

      assert {:error, %{message: "invalid tool name: \"tool!\"" <> _}} =
               ToolSpec.validate_name("tool!")
    end
  end

  describe "CommandSpec.new/3" do
    test "creates a valid command spec" do
      assert {:ok, spec} =
               CommandSpec.new("my-ext", "notify:send", %{
                 description: "Manual send"
               })

      assert spec.extension == "my-ext"
      # /ext: prefix is auto-added
      assert spec.name == "/ext:notify:send"
      assert spec.description == "Manual send"
    end

    test "prefixes with /ext: if needed" do
      assert {:ok, spec} = CommandSpec.new("my-ext", "send", %{description: "desc"})
      assert spec.name == "/ext:send"
    end

    test "keeps /ext: prefix if already present" do
      assert {:ok, spec} = CommandSpec.new("my-ext", "/ext:send", %{description: "desc"})
      assert spec.name == "/ext:send"
    end

    test "rejects empty command name" do
      assert {:error, %{message: "command name must not be empty"}} =
               CommandSpec.new("my-ext", "", %{description: "desc"})
    end
  end

  describe "ProviderSpec.new/3" do
    test "creates a valid provider spec" do
      assert {:ok, spec} =
               ProviderSpec.new("my-ext", "mock_provider", %{
                 base_url: "http://localhost:8000",
                 api: "openai-completions"
               })

      assert spec.extension == "my-ext"
      assert spec.name == "mock_provider"
      assert spec.base_url == "http://localhost:8000"
      assert spec.api == "openai-completions"
    end

    test "rejects empty provider name" do
      assert {:error, %{message: "provider name must not be empty"}} =
               ProviderSpec.new("my-ext", "", %{base_url: "http://localhost:8000"})
    end

    test "base_url is optional" do
      assert {:ok, spec} = ProviderSpec.new("my-ext", "mock", %{})
      assert spec.base_url == nil
    end
  end
end
