defmodule Handbean.Memory.MemoryUsefulnessTest do
  use Handbean.DataCase

  alias Handbean.Agent.{Config, Message, State}
  alias Handbean.Agent.Middleware.MemoryProjection
  alias Handbean.Memory.MemoryStore

  describe "scoped memory projection" do
    test "injects long-term rules without a keyword match" do
      {:ok, _} =
        learn_scoped("Always run the focused test before editing unrelated files", :rule,
          workspace_id: "useful-workspace",
          short_term: false
        )

      state = build_state("Fix the failure", workspace_id: "useful-workspace")
      result = MemoryProjection.call(:session_start, state)

      assert result.config.system_prompt =~ "## Memory Context"
      assert result.config.system_prompt =~ "### Persistent Rules & Preferences"
      assert result.config.system_prompt =~ "Always run the focused test"
    end

    test "injects query-relevant facts but not unrelated facts" do
      {:ok, _} =
        learn_scoped("Run tests with mise exec -- mix test", :fact,
          workspace_id: "useful-workspace",
          short_term: false
        )

      {:ok, _} =
        learn_scoped("Deployment region is eu-west", :fact,
          workspace_id: "useful-workspace",
          short_term: false
        )

      result =
        "How should I run tests?"
        |> build_state(workspace_id: "useful-workspace")
        |> then(&MemoryProjection.call(:session_start, &1))

      assert result.config.system_prompt =~ "### Relevant Memory"
      assert result.config.system_prompt =~ "mise exec -- mix test"
      refute result.config.system_prompt =~ "Deployment region"
    end

    test "query recall keeps short-term preferences discoverable" do
      {:ok, _} =
        learn_scoped("For release notes use British spelling", :preference,
          workspace_id: "useful-workspace",
          short_term: true
        )

      result =
        "Write release notes with British spelling"
        |> build_state(workspace_id: "useful-workspace")
        |> then(&MemoryProjection.call(:session_start, &1))

      assert result.config.system_prompt =~ "### Relevant Memory"
      assert result.config.system_prompt =~ "British spelling"
      refute result.config.system_prompt =~ "### Persistent Rules & Preferences"
    end

    test "does not duplicate a persistent memory in query recall" do
      {:ok, memory} =
        learn_scoped("Always use mise for test commands", :rule,
          workspace_id: "useful-workspace",
          short_term: false
        )

      result =
        "Which mise test command should I use?"
        |> build_state(workspace_id: "useful-workspace")
        |> then(&MemoryProjection.call(:session_start, &1))

      assert result.config.system_prompt
             |> String.split("##{memory.id}")
             |> length() == 2
    end

    test "bounds persistent memories and prioritizes workspace over global" do
      for index <- 1..9 do
        {:ok, _} =
          learn_scoped("Workspace persistent rule number #{index}", :rule,
            workspace_id: "useful-workspace",
            short_term: false
          )
      end

      {:ok, _} =
        MemoryStore.learn(
          "Global persistent preference that should exceed the budget",
          :preference,
          short_term: false,
          memory_scope: :global,
          privacy_mode: :standard
        )

      result =
        "Unrelated request"
        |> build_state(workspace_id: "useful-workspace", memory_scope: "both")
        |> then(&MemoryProjection.call(:session_start, &1))

      assert length(
               Regex.scan(~r/\[workspace:(?:rule|preference):#\d+\]/, result.config.system_prompt)
             ) ==
               8

      refute result.config.system_prompt =~ "Global persistent preference"
    end

    test "does not inject memories from another workspace" do
      {:ok, _} =
        learn_scoped("Forbidden workspace rule", :rule,
          workspace_id: "other-workspace",
          short_term: false
        )

      result =
        "Fix the failure"
        |> build_state(workspace_id: "current-workspace")
        |> then(&MemoryProjection.call(:session_start, &1))

      refute result.config.system_prompt =~ "Forbidden workspace rule"
    end

    test "local_only excludes global memory" do
      {:ok, _} =
        MemoryStore.learn("Global response preference", :preference,
          short_term: false,
          memory_scope: :global,
          privacy_mode: :standard
        )

      {:ok, _} =
        learn_scoped("Private workspace response preference", :preference,
          workspace_id: "private-workspace",
          short_term: false
        )

      result =
        "Answer this"
        |> build_state(
          workspace_id: "private-workspace",
          memory_scope: "both",
          privacy_mode: "local_only"
        )
        |> then(&MemoryProjection.call(:session_start, &1))

      assert result.config.system_prompt =~ "Private workspace response preference"
      refute result.config.system_prompt =~ "Global response preference"
    end

    test "does nothing when built-in memory is disabled" do
      state = build_state("Fix the failure", workspace_id: "useful-workspace")
      state = %{state | config: %{state.config | builtin_memory_enabled: false}}

      assert MemoryProjection.call(:session_start, state) == state
    end
  end

  defp learn_scoped(content, kind, opts) do
    workspace_id = Keyword.fetch!(opts, :workspace_id)

    MemoryStore.learn(content, kind,
      short_term: Keyword.get(opts, :short_term, true),
      memory_scope: :workspace,
      workspace_id: workspace_id,
      privacy_mode: :standard
    )
  end

  defp build_state(user_prompt, opts) do
    context = %{
      workspace_id: Keyword.fetch!(opts, :workspace_id),
      memory_scope: Keyword.get(opts, :memory_scope, "workspace"),
      privacy_mode: Keyword.get(opts, :privacy_mode, "standard")
    }

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
      context: context,
      middleware: nil,
      provider_config: %{},
      max_messages: 200,
      max_tokens: 200_000,
      compaction: %{reserve_tokens: 16_384, keep_recent_tokens: 20_000, fallback: :truncate},
      on_compaction: nil,
      builtin_memory_enabled: true
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
