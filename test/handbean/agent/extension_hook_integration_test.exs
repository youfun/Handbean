defmodule Handbean.Agent.ExtensionHookIntegrationTest do
  use ExUnit.Case, async: false

  alias Handbean.Extension.Event
  alias Handbean.Extension.HookRunner
  alias Handbean.Extension.Registry, as: ExtRegistry
  alias Handbean.Extension.Diagnostic

  setup do
    %{}
  end

  describe "HookRunner executes extension hooks" do
    test "hook receives session_start event" do
      ext = build_extension("hook-ext", hooks: ["session_start", "turn_start"])

      runner = HookRunner.new() |> HookRunner.register(ext, TestHookModule)

      {:ok, evt} = Event.new(:session_start, "session-1")
      result = HookRunner.run(runner, evt)
      assert result.status == :ok
    end

    test "hooks are filtered by event name" do
      ext = build_extension("hook-ext", hooks: ["agent_start"])

      runner = HookRunner.new() |> HookRunner.register(ext, TestHookModule)

      {:ok, evt} = Event.new(:turn_end, "session-1")
      result = HookRunner.run(runner, evt)
      assert result.status == :ok
      assert result.diagnostics == []
    end

    test "list_hooks_by_event filters correctly from registry" do
      reg_name = :"test_hook_reg_#{System.unique_integer([:positive])}"
      {:ok, _pid} = ExtRegistry.start_link(name: reg_name)
      registry = reg_name

      ext1 = build_extension("ext-a", hooks: ["agent_start", "tool_start"])
      ext2 = build_extension("ext-b", hooks: ["tool_start", "turn_end"])
      ext3 = build_extension("ext-c", hooks: ["agent_end"])

      ExtRegistry.register(registry, ext1)
      ExtRegistry.register(registry, ext2)
      ExtRegistry.register(registry, ext3)

      tool_start_hooks = ExtRegistry.list_hooks_by_event(registry, "tool_start")
      hook_names = Enum.map(tool_start_hooks, & &1.name)
      assert "ext-a" in hook_names
      assert "ext-b" in hook_names
      refute "ext-c" in hook_names
    end
  end

  describe "Extension tool execution via Tool.Registry" do
    test "extension tool can be dispatched through Tool.Executor" do
      :ok = Handbean.Tool.Registry.register(TestExtensionTool)

      state = build_test_state()

      tool_calls = [
        %{name: "ext__test__ping", input: %{}, id: "call_1"}
      ]

      {:ok, result_msg, _ui_blocks} =
        Handbean.Agent.Tool.Executor.execute_all_with_details(tool_calls, state)

      assert length(result_msg.content) == 1
      result_block = hd(result_msg.content)
      assert result_block.content =~ "pong"
      assert result_block.is_error == false
    end

    test "extension tool with input schema works" do
      :ok = Handbean.Tool.Registry.register(TestExtensionTool2)

      state = build_test_state()

      tool_calls = [
        %{name: "ext__test__echo", input: %{"message" => "hello"}, id: "call_2"}
      ]

      {:ok, result_msg, _ui_blocks} =
        Handbean.Agent.Tool.Executor.execute_all_with_details(tool_calls, state)

      result_block = hd(result_msg.content)
      assert result_block.content =~ "echo: hello"
    end

    test "extension tool error is handled" do
      :ok = Handbean.Tool.Registry.register(TestExtensionTool2)

      state = build_test_state()

      tool_calls = [
        %{name: "ext__test__echo", input: %{}, id: "call_3"}
      ]

      {:ok, result_msg, _ui_blocks} =
        Handbean.Agent.Tool.Executor.execute_all_with_details(tool_calls, state)

      result_block = hd(result_msg.content)
      assert result_block.is_error == true
      assert result_block.content =~ "message is required"
    end
  end

  # ── Helpers ──

  defp build_extension(name, opts \\ []) do
    %Handbean.Extension{
      name: name,
      root: "/abs/path/.handbean/extensions/#{name}",
      enabled: Keyword.get(opts, :enabled, true),
      hooks: Keyword.get(opts, :hooks, []),
      tools: Keyword.get(opts, :tools, []),
      entry: nil,
      version: "0.1.0",
      description: nil,
      permissions: %{},
      commands: [],
      providers: [],
      metadata: %{}
    }
  end

  defp build_test_state do
    config = %Handbean.Agent.Config{
      provider: Handbean.Agent.Provider.OpenAICompat,
      model: "test-model",
      working_directory: "/tmp",
      context: %{},
      tool_timeout: 30_000
    }

    Handbean.Agent.State.init(config, "test prompt")
  end
end
