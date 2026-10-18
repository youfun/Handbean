defmodule Handbean.Extension.HookPipelineTest do
  use ExUnit.Case, async: false

  alias Handbean.Extension.HookPipeline
  alias Handbean.Extension.Event
  alias Handbean.Extension.Registry, as: ExtRegistry

  describe "run/2 — no registered extensions" do
    test "returns :ok when no hooks match" do
      assert HookPipeline.run("session-1", {:run_start, %{}}) == :ok
    end

    test "returns :ok for any event type when pipeline has no hooks" do
      assert HookPipeline.run("s", {:tool_start, %{tool: "read"}}) == :ok
      assert HookPipeline.run("s", {:message_delta, %{chunk: "hi"}}) == :ok
    end
  end

  describe "run/2 — with hook extensions registered" do
    setup do
      reg_name = :"test_hook_pipeline_reg_#{System.unique_integer([:positive])}"
      {:ok, _pid} = ExtRegistry.start_link(name: reg_name)
      %{reg_name: reg_name}
    end

    test "returns :ok when extension hook returns :ok", %{reg_name: reg} do
      ext = build_extension("pass-ext", hooks: ["tool_start"])
      :ok = ExtRegistry.register(reg, ext)

      # Register a hook module that always returns :ok
      HookPipeline.register_hook_module(reg, "pass-ext", AlwaysOkHook)

      assert HookPipeline.run("s", {:tool_start, %{tool: "read"}}, registry: reg) == :ok
    end

    test "a read-only halt cannot suppress the next observer or transform its context", %{
      reg_name: reg
    } do
      for {name, hook} <- [
            {"readonly-blocker", BlockingHook},
            {"readonly-observer", ReadonlyObserverHook}
          ] do
        :ok = ExtRegistry.register(reg, build_extension(name, hooks: ["tool_end"]))
        :ok = HookPipeline.register_hook_module(reg, name, hook)
      end

      assert HookPipeline.run("s", {:tool_end, %{notify: self()}}, registry: reg) == :ok
      assert_received :readonly_observed
    end

    test "returns {:block, reason} when extension hook returns {:halt, reason}", %{reg_name: reg} do
      ext = build_extension("block-ext", hooks: ["tool_call"])
      :ok = ExtRegistry.register(reg, ext)

      HookPipeline.register_hook_module(reg, "block-ext", BlockingHook)

      assert {:block, "tool not allowed"} =
               HookPipeline.run(
                 "s",
                 {:tool_call, %{tool_name: "bash", args: %{"command" => "rm -rf /"}}},
                 registry: reg
               )
    end

    test "returns {:transform, payload} when extension hook modifies payload", %{reg_name: reg} do
      ext = build_extension("transform-ext", hooks: ["context"])
      :ok = ExtRegistry.register(reg, ext)

      HookPipeline.register_hook_module(reg, "transform-ext", TransformingHook)

      assert {:transform, %{messages: [:filtered]}} =
               HookPipeline.run("s", {:context, %{messages: [:original, :stale]}}, registry: reg)
    end

    test "first block wins when multiple hooks are registered", %{reg_name: reg} do
      ext1 = build_extension("blocker1", hooks: ["tool_call"])
      ext2 = build_extension("blocker2", hooks: ["tool_call"])
      :ok = ExtRegistry.register(reg, ext1)
      :ok = ExtRegistry.register(reg, ext2, override: true)

      HookPipeline.register_hook_module(reg, "blocker1", BlockingHook)
      HookPipeline.register_hook_module(reg, "blocker2", AlwaysOkHook)

      # blocker1 halts, blocker2 never runs
      assert {:block, "tool not allowed"} =
               HookPipeline.run("s", {:tool_call, %{tool_name: "bash", args: %{}}}, registry: reg)
    end

    test "hooks not matching the event are skipped", %{reg_name: reg} do
      ext = build_extension("selective-ext", hooks: ["tool_call"])
      :ok = ExtRegistry.register(reg, ext)

      HookPipeline.register_hook_module(reg, "selective-ext", BlockingHook)

      # tool_call is hooked → block
      assert {:block, _} =
               HookPipeline.run("s", {:tool_call, %{tool_name: "bash", args: %{}}}, registry: reg)

      # turn_start is not hooked → :ok
      assert HookPipeline.run("s", {:turn_start, %{}}, registry: reg) == :ok
    end

    test "high-frequency events (message_delta) do not block" do
      # message_delta is read-only notification; even if a hook exists,
      # it should not be able to block
      assert HookPipeline.run("s", {:message_delta, %{chunk: "hi"}}) == :ok
    end
  end

  describe "run/2 — event types" do
    test "all known blockable event types can be dispatched" do
      events = [
        {:before_agent_start, %{}},
        {:tool_call, %{tool_name: "read", args: %{}}},
        {:context, %{messages: []}},
        {:turn_start, %{}},
        {:turn_end, %{}},
        {:agent_end, %{}},
        {:tool_start, %{tool: "read"}},
        {:tool_end, %{tool: "read"}},
        {:run_start, %{}},
        {:run_end, %{}}
      ]

      Enum.each(events, fn event ->
        result = HookPipeline.run("s", event)

        assert match?(:ok, result) or match?({:block, _}, result) or
                 match?({:transform, _}, result)
      end)
    end
  end

  describe "register_hook_module/3" do
    setup do
      reg_name = :"test_hook_reg_#{System.unique_integer([:positive])}"
      {:ok, _pid} = ExtRegistry.start_link(name: reg_name)
      %{reg_name: reg_name}
    end

    test "registers a hook module for an extension", %{reg_name: reg} do
      ext = build_extension("test-ext", hooks: ["tool_start"])
      :ok = ExtRegistry.register(reg, ext)

      assert :ok = HookPipeline.register_hook_module(reg, "test-ext", AlwaysOkHook)
    end

    test "returns error for non-existent extension", %{reg_name: reg} do
      assert {:error, :not_found} = HookPipeline.register_hook_module(reg, "no-ext", AlwaysOkHook)
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
end

# ── Test hook modules ──

defmodule AlwaysOkHook do
  @moduledoc false
  @behaviour Handbean.Extension.Hook

  @impl true
  def handle_event(_event, _ctx), do: :ok
end

defmodule BlockingHook do
  @moduledoc false
  @behaviour Handbean.Extension.Hook

  @impl true
  def handle_event(_event, _ctx), do: {:halt, "tool not allowed"}
end

defmodule ReadonlyObserverHook do
  @moduledoc false
  @behaviour Handbean.Extension.Hook

  @impl true
  def handle_event(event, _ctx) do
    send(event.payload.notify, :readonly_observed)
    :ok
  end
end

defmodule TransformingHook do
  @moduledoc false
  @behaviour Handbean.Extension.Hook

  alias Handbean.Extension.Event

  @impl true
  def handle_event(%Event{name: :context}, _ctx) do
    {:ok, %{messages: [:filtered]}}
  end

  def handle_event(_event, _ctx), do: :ok
end
