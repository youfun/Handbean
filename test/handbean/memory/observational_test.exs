defmodule Handbean.Memory.ObservationalTest do
  use ExUnit.Case, async: false

  alias Handbean.Memory.{Observation, ObservationStore}
  alias Handbean.Memory.ObservationalConfig, as: Config
  alias Handbean.Agent.Config, as: AgentConfig
  alias Handbean.Agent.{Message, State}

  @test_conversation_id "test-om-conv-#{:rand.uniform(100_000)}"

  setup do
    previous = Application.get_env(:handbean, :observational_memory)

    # Clean up test observation file after each test
    path = ObservationStore.file_path(@test_conversation_id)
    if File.exists?(path), do: File.rm!(path)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:handbean, :observational_memory, previous),
        else: Application.delete_env(:handbean, :observational_memory)

      if File.exists?(path), do: File.rm!(path)
    end)

    :ok
  end

  describe "Observation" do
    test "creates a new observation with defaults" do
      obs = Observation.new("User asked about project structure")

      assert obs.content == "User asked about project structure"
      assert obs.priority == :medium
      assert is_binary(obs.id)
      assert %DateTime{} = obs.timestamp
      assert obs.metadata == %{}
    end

    test "creates a new observation with options" do
      ts = ~U[2026-05-20 10:30:00Z]

      obs =
        Observation.new("Tool bash executed",
          priority: :high,
          source: :tool_execution,
          timestamp: ts,
          metadata: %{tool_name: "bash", turn: 3},
          id: "obs_123"
        )

      assert obs.id == "obs_123"
      assert obs.priority == :high
      assert obs.source == :tool_execution
      assert obs.timestamp == ts
      assert obs.metadata.tool_name == "bash"
      assert obs.metadata.turn == 3
    end

    test "to_map and from_map round-trip" do
      obs =
        Observation.new("Test observation",
          priority: :high,
          source: :completion,
          metadata: %{tokens: 150}
        )

      map = Observation.to_map(obs)
      restored = Observation.from_map(map)

      assert restored.content == obs.content
      assert restored.priority == obs.priority
      assert restored.source == obs.source
      assert restored.metadata.tokens == 150
    end

    test "from_map handles missing fields" do
      obs = Observation.from_map(%{"content" => "Minimal observation"})

      assert obs.content == "Minimal observation"
      assert obs.priority == :medium
      assert is_binary(obs.id)
    end

    test "to_context_line formats correctly" do
      ts = ~U[2026-05-20 10:30:00Z]
      obs = Observation.new("User prefers Elixir", priority: :high, timestamp: ts)

      line = Observation.to_context_line(obs)
      assert line =~ "重要"
      assert line =~ "User prefers Elixir"
    end
  end

  describe "ObservationStore" do
    test "append and load_recent" do
      obs1 = Observation.new("First observation", source: :tool_execution)
      obs2 = Observation.new("Second observation", source: :completion)
      obs3 = Observation.new("Third observation", source: :tool_execution)

      :ok = ObservationStore.append(@test_conversation_id, obs1)
      :ok = ObservationStore.append(@test_conversation_id, obs2)
      :ok = ObservationStore.append(@test_conversation_id, obs3)

      recent = ObservationStore.load_recent(@test_conversation_id, 2)
      assert length(recent) == 2

      # Most recent first
      assert Enum.at(recent, 0).content == "Third observation"
      assert Enum.at(recent, 1).content == "Second observation"
    end

    test "load_recent on non-existent file returns empty" do
      observations = ObservationStore.load_recent("nonexistent-conv-id-xyz", 5)
      assert observations == []
    end

    test "count_unprocessed returns correct count" do
      obs1 = Observation.new("Obs 1")
      obs2 = Observation.new("Obs 2")

      :ok = ObservationStore.append(@test_conversation_id, obs1)
      :ok = ObservationStore.append(@test_conversation_id, obs2)

      count = ObservationStore.count_unprocessed(@test_conversation_id)
      assert count == 2
    end

    test "count_unprocessed on non-existent file returns 0" do
      count = ObservationStore.count_unprocessed("nonexistent-conv-id-xyz")
      assert count == 0
    end

    test "mark_reflected updates observations" do
      obs1 = Observation.new("Obs 1", id: "mark-1")
      obs2 = Observation.new("Obs 2", id: "mark-2")
      obs3 = Observation.new("Obs 3", id: "mark-3")

      :ok = ObservationStore.append(@test_conversation_id, obs1)
      :ok = ObservationStore.append(@test_conversation_id, obs2)
      :ok = ObservationStore.append(@test_conversation_id, obs3)

      :ok = ObservationStore.mark_reflected(@test_conversation_id, ["mark-1", "mark-3"])

      # Load all
      all = ObservationStore.load_recent(@test_conversation_id, 10)

      marked = Enum.filter(all, &(&1.metadata[:reflected] || &1.metadata["reflected"]))
      assert length(marked) == 2

      unprocessed = ObservationStore.count_unprocessed(@test_conversation_id)
      assert unprocessed == 1
    end
  end

  describe "Config" do
    test "from_kw with enabled defaults" do
      config = Config.from_kw([])
      refute Config.enabled?(config)
      assert config.max_recent_context == 5
      assert config.model == "claude-haiku-4-5-20251001"
      assert is_nil(config.provider)
      assert is_nil(config.reasoning)
      assert config.observer_message_tokens == 30_000
      assert config.reflector_observation_tokens == 40_000
    end

    test "from_kw with enabled true" do
      config = Config.from_kw(enabled: true, observation: [max_recent_context: 10])
      assert Config.enabled?(config)
      assert config.max_recent_context == 10
    end

    test "from_kw applies one model and reasoning level to memory processing" do
      config =
        Config.from_kw(
          enabled: true,
          model: "claude-opus",
          reasoning: "high",
          observer: [message_tokens: 50_000]
        )

      assert config.model == "claude-opus"
      assert config.reasoning == "high"
      assert config.observer_message_tokens == 50_000
    end

    test "from_kw keeps reflector-specific thresholds" do
      config =
        Config.from_kw(
          enabled: true,
          model: "gpt-4o-mini",
          reflector: [observation_tokens: 80_000]
        )

      assert config.model == "gpt-4o-mini"
      assert config.reflector_observation_tokens == 80_000
    end

    test "from_kw with map" do
      config = Config.from_kw(%{"enabled" => true, "observation" => %{"max_recent_context" => 3}})
      assert Config.enabled?(config)
      assert config.max_recent_context == 3
    end

    test "from_kw with map nested observer override" do
      config =
        Config.from_kw(%{
          "enabled" => true,
          "model" => "claude-opus",
          "reasoning" => "low",
          "observer" => %{"message_tokens" => 20_000}
        })

      assert Config.enabled?(config)
      assert config.model == "claude-opus"
      assert config.reasoning == "low"
      assert config.observer_message_tokens == 20_000
    end

    test "provider falls back to agent provider when nil" do
      config = Config.from_kw([])
      assert Config.provider(config, :fallback_provider) == :fallback_provider
    end

    test "provider returns explicit provider when set" do
      config = Config.from_kw(provider: :explicit_provider)
      assert Config.provider(config, :fallback_provider) == :explicit_provider
    end

    test "enabled?/1 returns false for nil" do
      refute Config.enabled?(nil)
      refute Config.enabled?(%{})
    end
  end

  describe "runtime settings" do
    test "an enabled run loads observation middleware when application env is unset" do
      previous = Application.get_env(:handbean, :observational_memory)
      Application.delete_env(:handbean, :observational_memory)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:handbean, :observational_memory, previous),
          else: Application.delete_env(:handbean, :observational_memory)
      end)

      config =
        AgentConfig.from_opts(
          om: %{
            enabled: true,
            model: "stepfun/step-router-v1",
            reasoning: "high",
            max_recent_context: 2,
            memory_scope: "both",
            privacy_mode: "standard"
          }
        )

      assert Handbean.Agent.Middleware.ObservationalSessionStart in config.middleware
      assert Handbean.Agent.Middleware.ObservationalAfterCompletion in config.middleware
      assert Handbean.Agent.Middleware.ObservationalAfterToolExec in config.middleware
      assert config.context.observational.enabled
      assert config.context.observational.model == "stepfun/step-router-v1"
      assert config.context.observational.reasoning == "high"
      assert config.context.observational.max_recent_context == 2
      assert config.context.memory_scope == "both"
      assert config.context.privacy_mode == "standard"

      disabled = AgentConfig.from_opts(builtin_memory_enabled: false)
      refute Handbean.Agent.Middleware.ObservationalSessionStart in disabled.middleware

      sid = "test-om-runtime-#{System.unique_integer([:positive])}"
      path = ObservationStore.file_path(sid)
      on_exit(fn -> if File.exists?(path), do: File.rm!(path) end)

      state =
        build_test_state()
        |> put_in([Access.key!(:config)], config)
        |> Map.put(:run_metadata, %{session_id: sid})
        |> Map.put(:messages, [Message.assistant("done")])

      Handbean.Agent.Middleware.ObservationalAfterCompletion.call(:after_completion, state)
      assert [_] = ObservationStore.load_recent(sid, 1)
    end
  end

  describe "ObservationalSessionStart middleware" do
    alias Handbean.Agent.Middleware.ObservationalSessionStart

    test "passes through when OM is disabled" do
      state = build_test_state()
      result = ObservationalSessionStart.call(:session_start, state)
      assert result == state
    end

    test "passes through on non-session_start hooks" do
      state = build_test_state()
      result = ObservationalSessionStart.call(:after_completion, state)
      assert result == state
    end
  end

  describe "ObservationalAfterCompletion middleware" do
    alias Handbean.Agent.Middleware.ObservationalAfterCompletion

    test "passes through on non-after_completion hooks" do
      state = build_test_state()
      result = ObservationalAfterCompletion.call(:session_start, state)
      assert result == state
    end

    test "records scope metadata on completion observations" do
      Application.put_env(:handbean, :observational_memory, enabled: true)

      sid = "test-om-completion-scope-#{System.unique_integer([:positive])}"
      path = ObservationStore.file_path(sid)
      on_exit(fn -> if File.exists?(path), do: File.rm!(path) end)

      state =
        build_test_state()
        |> put_in([Access.key!(:config), Access.key!(:context)], %{
          workspace_id: "om-workspace",
          memory_scope: "workspace",
          privacy_mode: "local_only"
        })
        |> Map.put(:run_metadata, %{session_id: sid})
        |> Map.put(:messages, [Message.assistant("done")])

      ObservationalAfterCompletion.call(:after_completion, state)

      [obs] = ObservationStore.load_recent(sid, 1)
      assert obs.metadata["scope"] == "workspace"
      assert obs.metadata["workspace_id"] == "om-workspace"
      assert obs.metadata["privacy_mode"] == "local_only"
    end
  end

  describe "ObservationalAfterToolExec middleware" do
    alias Handbean.Agent.Middleware.ObservationalAfterToolExec

    test "passes through on non-after_tool_execution hooks" do
      state = build_test_state()
      result = ObservationalAfterToolExec.call(:session_end, state)
      assert result == state
    end

    test "records scope metadata on tool observations" do
      Application.put_env(:handbean, :observational_memory, enabled: true)

      sid = "test-om-tool-scope-#{System.unique_integer([:positive])}"
      path = ObservationStore.file_path(sid)
      on_exit(fn -> if File.exists?(path), do: File.rm!(path) end)

      state =
        build_test_state()
        |> put_in([Access.key!(:config), Access.key!(:context)], %{
          workspace_id: "om-tool-workspace",
          memory_scope: "workspace",
          privacy_mode: "local_only"
        })
        |> Map.put(:run_metadata, %{session_id: sid})
        |> Map.put(:messages, [
          Message.assistant_blocks([
            %{type: "tool_use", id: "toolu_1", name: "read", input: %{file_path: "README.md"}}
          ]),
          Message.tool_results([
            Message.tool_result_block("toolu_1", "content", false, %{duration_ms: 12})
          ])
        ])

      ObservationalAfterToolExec.call(:after_tool_execution, state)

      [obs] = ObservationStore.load_recent(sid, 1)
      assert obs.metadata["scope"] == "workspace"
      assert obs.metadata["workspace_id"] == "om-tool-workspace"
      assert obs.metadata["privacy_mode"] == "local_only"
    end
  end

  # ── Helpers ──

  defp build_test_state do
    config = %AgentConfig{
      provider: nil,
      system_prompt: "Test system prompt",
      working_directory: File.cwd!(),
      model: "test-model",
      max_turns: 50,
      max_budget_cents: nil,
      timeout_ms: 300_000,
      tool_timeout: 60_000,
      until_tool: nil,
      reasoning_level: "off",
      memory: nil,
      context: %{},
      middleware: nil,
      provider_config: %{},
      max_messages: 200,
      max_tokens: 200_000,
      compaction: %{reserve_tokens: 16_384, keep_recent_tokens: 20_000, fallback: :truncate},
      on_compaction: nil
    }

    %State{
      config: config,
      messages: [],
      turn: 0,
      status: :running,
      error: nil,
      usage: %{input_tokens: 0, output_tokens: 0},
      tool_calls: [],
      provider_state: %{},
      response_metadata: %{},
      run_metadata: %{},
      provider_response_metadata: %{},
      tool_guard_overrides: %{},
      interrupt_data: nil,
      tool_guard_denied_calls: [],
      tool_guard_result_blocks: []
    }
  end
end
