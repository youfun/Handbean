defmodule Handbean.Extension.HookRunnerTest do
  use Handbean.DataCase, async: true

  alias Handbean.Extension.HookRunner
  alias Handbean.Extension.Event

  defmodule TestHookOk do
    @behaviour Handbean.Extension.Hook

    def handle_event(_event, ctx) do
      send(ctx.test_pid, {:hook_called, :test_hook_ok, ctx.ext_name})
      :ok
    end
  end

  defmodule TestHookState do
    @behaviour Handbean.Extension.Hook

    def handle_event(_event, ctx) do
      new_ctx = Map.update(ctx, :counter, 1, &(&1 + 1))
      {:ok, new_ctx}
    end
  end

  defmodule TestHookHalt do
    @behaviour Handbean.Extension.Hook

    def handle_event(_event, ctx) do
      send(ctx.test_pid, {:hook_called, :test_hook_halt})
      {:halt, "stopped by policy"}
    end
  end

  defmodule TestHookError do
    @behaviour Handbean.Extension.Hook

    def handle_event(_event, _ctx) do
      {:error, "something went wrong"}
    end
  end

  defmodule TestHookRaise do
    @behaviour Handbean.Extension.Hook

    def handle_event(_event, _ctx) do
      raise "boom!"
    end
  end

  defmodule TestHookThrow do
    @behaviour Handbean.Extension.Hook

    def handle_event(_event, _ctx) do
      throw(:aborted)
    end
  end

  defmodule TestHookExit do
    @behaviour Handbean.Extension.Hook

    def handle_event(_event, _ctx) do
      exit(:killed)
    end
  end

  defmodule TestHookNoImpl do
  end

  defp build_ext(name, hooks) do
    %Handbean.Extension{
      name: name,
      enabled: true,
      hooks: hooks,
      root: "/abs/#{name}",
      tools: [],
      commands: [],
      providers: [],
      permissions: %{},
      metadata: %{},
      entry: nil,
      description: nil,
      version: nil
    }
  end

  describe "run/3 - basic execution" do
    test "runs hooks in registration order" do
      {:ok, event} = Event.new(:agent_start, "session-1")

      runner =
        HookRunner.new()
        |> HookRunner.register(build_ext("ext1", ["agent_start"]), TestHookOk)
        |> HookRunner.register(build_ext("ext2", ["agent_start"]), TestHookOk)

      result = HookRunner.run(runner, event, test_pid: self())

      assert result.status == :ok
      assert result.diagnostics == []
      assert_received {:hook_called, :test_hook_ok, "ext1"}
      assert_received {:hook_called, :test_hook_ok, "ext2"}
    end

    test "no hooks returns ok" do
      {:ok, event} = Event.new(:agent_start, "session-1")
      result = HookRunner.run(HookRunner.new(), event)
      assert result.status == :ok
      assert result.diagnostics == []
    end

    test "no registered hooks for event returns ok" do
      {:ok, event} = Event.new(:agent_start, "session-1")

      runner =
        HookRunner.new()
        |> HookRunner.register(build_ext("ext1", ["turn_end"]), TestHookOk)

      result = HookRunner.run(runner, event)
      assert result.status == :ok
      refute_received {:hook_called, _, _}
    end

    test "state flows between hooks" do
      {:ok, event} = Event.new(:agent_start, "session-1")

      runner =
        HookRunner.new()
        |> HookRunner.register(build_ext("ext1", ["agent_start"]), TestHookState)
        |> HookRunner.register(build_ext("ext2", ["agent_start"]), TestHookState)

      result = HookRunner.run(runner, event)
      assert result.status == :ok
    end
  end

  describe "run/3 - halt behavior" do
    test "halt stops subsequent hooks" do
      {:ok, event} = Event.new(:agent_start, "session-1")

      runner =
        HookRunner.new()
        |> HookRunner.register(build_ext("ext1", ["agent_start"]), TestHookHalt)
        |> HookRunner.register(build_ext("ext2", ["agent_start"]), TestHookOk)

      result = HookRunner.run(runner, event, test_pid: self())

      assert result.status == :halted
      assert result.halt_reason == "stopped by policy"
      assert_received {:hook_called, :test_hook_halt}
      refute_received {:hook_called, :test_hook_ok, "ext2"}
    end
  end

  describe "run/3 - error handling" do
    test "error records diagnostic and continues" do
      {:ok, event} = Event.new(:agent_start, "session-1")

      runner =
        HookRunner.new()
        |> HookRunner.register(build_ext("ext1", ["agent_start"]), TestHookError)
        |> HookRunner.register(build_ext("ext2", ["agent_start"]), TestHookOk)

      result = HookRunner.run(runner, event, test_pid: self())

      assert result.status == :ok
      assert length(result.diagnostics) == 1
      assert hd(result.diagnostics).type == :error
      assert_received {:hook_called, :test_hook_ok, "ext2"}
    end

    test "raised exception records diagnostic and continues" do
      {:ok, event} = Event.new(:agent_start, "session-1")

      runner =
        HookRunner.new()
        |> HookRunner.register(build_ext("ext1", ["agent_start"]), TestHookRaise)
        |> HookRunner.register(build_ext("ext2", ["agent_start"]), TestHookOk)

      result = HookRunner.run(runner, event, test_pid: self())

      assert result.status == :ok
      assert length(result.diagnostics) == 1
      assert hd(result.diagnostics).type == :error
      assert_received {:hook_called, :test_hook_ok, "ext2"}
    end

    test "hook throw is caught and does not break the chain" do
      {:ok, event} = Event.new(:agent_start, "session-1")

      runner =
        HookRunner.new()
        |> HookRunner.register(build_ext("ext1", ["agent_start"]), TestHookThrow)
        |> HookRunner.register(build_ext("ext2", ["agent_start"]), TestHookOk)

      result = HookRunner.run(runner, event, test_pid: self())

      assert result.status == :ok
      assert length(result.diagnostics) == 1
      assert hd(result.diagnostics).type == :error
      assert_received {:hook_called, :test_hook_ok, "ext2"}
    end

    test "hook exit is caught and does not kill the runner process" do
      {:ok, event} = Event.new(:agent_start, "session-1")

      runner =
        HookRunner.new()
        |> HookRunner.register(build_ext("ext1", ["agent_start"]), TestHookExit)
        |> HookRunner.register(build_ext("ext2", ["agent_start"]), TestHookOk)

      result = HookRunner.run(runner, event, test_pid: self())

      assert result.status == :ok
      assert length(result.diagnostics) == 1
      assert hd(result.diagnostics).type == :error
      assert_received {:hook_called, :test_hook_ok, "ext2"}
    end
  end

  describe "register/3" do
    test "registers hook module for extension" do
      runner =
        HookRunner.new()
        |> HookRunner.register(build_ext("ext1", ["agent_start"]), TestHookOk)

      assert length(runner.hooks) == 1
      assert hd(runner.hooks).extension_name == "ext1"
      assert hd(runner.hooks).module == TestHookOk
    end

    test "skip hooks that don't implement behaviour" do
      runner =
        HookRunner.new()
        |> HookRunner.register(build_ext("ext1", ["agent_start"]), TestHookNoImpl)

      assert runner.hooks == []
    end
  end
end
