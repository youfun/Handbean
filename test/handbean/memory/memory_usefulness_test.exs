defmodule Handbean.Memory.MemoryUsefulnessTest do
  use Handbean.DataCase

  alias Handbean.Agent.{Config, Message, State}
  alias Handbean.Agent.Middleware.ObservationalSessionStart
  alias Handbean.Memory.MemoryStore

  setup do
    previous = Application.get_env(:handbean, :observational_memory)

    Application.put_env(:handbean, :observational_memory,
      enabled: true,
      observation: [max_recent_context: 5]
    )

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:handbean, :observational_memory)
        value -> Application.put_env(:handbean, :observational_memory, value)
      end
    end)

    :ok
  end

  describe "automatic scoped memory injection" do
    test "injects relevant current-workspace long-term memory into the system prompt" do
      {:ok, _} =
        MemoryStore.learn("To run tests use mise exec -- mix test", :fact,
          short_term: false,
          metadata: %{scope: "workspace", workspace_id: "useful-workspace"}
        )

      state =
        build_state("How should I run tests?",
          workspace_id: "useful-workspace",
          memory_scope: "workspace",
          privacy_mode: "standard"
        )

      result = ObservationalSessionStart.call(:session_start, state)

      assert result.config.system_prompt =~ "## Relevant Memory"
      assert result.config.system_prompt =~ "mise exec -- mix test"
    end

    test "does not inject memories from another workspace" do
      {:ok, _} =
        MemoryStore.learn("To run tests use forbidden workspace command", :fact,
          short_term: false,
          metadata: %{scope: "workspace", workspace_id: "other-workspace"}
        )

      state =
        build_state("How should I run tests?",
          workspace_id: "current-workspace",
          memory_scope: "workspace",
          privacy_mode: "standard"
        )

      result = ObservationalSessionStart.call(:session_start, state)

      refute result.config.system_prompt =~ "forbidden workspace command"
    end

    test "local_only does not inject global memory even when memory_scope is both" do
      {:ok, _} =
        MemoryStore.learn("To run tests use global cloud memory", :fact,
          short_term: false,
          metadata: %{scope: "global"}
        )

      {:ok, _} =
        MemoryStore.learn("To run tests use private workspace memory", :fact,
          short_term: false,
          metadata: %{scope: "workspace", workspace_id: "private-workspace"}
        )

      state =
        build_state("How should I run tests?",
          workspace_id: "private-workspace",
          memory_scope: "both",
          privacy_mode: "local_only"
        )

      result = ObservationalSessionStart.call(:session_start, state)

      assert result.config.system_prompt =~ "private workspace memory"
      refute result.config.system_prompt =~ "global cloud memory"
    end
  end

  defp build_state(user_prompt, opts) do
    config = %Config{
      provider: nil,
      system_prompt: "Base system prompt",
      working_directory: File.cwd!(),
      model: "test-model",
      max_turns: 50,
      max_budget_cents: nil,
      timeout_ms: 300_000,
      tool_timeout: 60_000,
      until_tool: nil,
      reasoning_level: "off",
      memory: nil,
      context: Map.new(opts),
      middleware: nil,
      provider_config: %{},
      max_messages: 200,
      max_tokens: 200_000,
      compaction: %{reserve_tokens: 16_384, keep_recent_tokens: 20_000, fallback: :truncate},
      on_compaction: nil
    }

    %State{
      config: config,
      messages: [Message.user(user_prompt)],
      turn: 0,
      status: :running,
      error: nil,
      usage: %{input_tokens: 0, output_tokens: 0},
      tool_calls: [],
      provider_state: %{},
      response_metadata: %{},
      run_metadata: %{session_id: "memory-usefulness-session"},
      provider_response_metadata: %{},
      tool_guard_overrides: %{},
      interrupt_data: nil,
      tool_guard_denied_calls: [],
      tool_guard_result_blocks: []
    }
  end
end
