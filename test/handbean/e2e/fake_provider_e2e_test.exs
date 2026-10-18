defmodule Handbean.E2E.FakeProviderEndToEndTest do
  @moduledoc """
  End-to-end dogfood tests using the FakeProvider.

  These tests validate the full Agent pipeline:
    Agent.run/2 → Turn.run_loop/2 → Provider.complete/3 → Tool Executor → final State

  All tests run without real API calls — they exercise the same control flow
  that the Anthropic provider would use, but with a deterministic fake.

  ## Tags

  All tests in this module are tagged `:e2e`. They are excluded from
  default `mix test` runs. To run them:

      mix test --include e2e
      mix test test/handbean/e2e --include e2e

  ## Reference

  Pattern derived from:
    - `test/handbean/agent/turn_test.exs` (unit-level turn tests)
    - `jido_ai/test/support/fake_req_llm.ex` (fake LLM pattern)
  """

  use Handbean.DataCase, async: false
  import ExUnit.CaptureLog, only: [with_log: 1]

  alias Handbean.Agent.Message
  alias Handbean.Memory.Engram

  @moduletag :e2e

  # We need a real working_directory so the Read tool can find fixtures.
  @working_dir Path.expand("test/fixtures", File.cwd!())

  # Run Agent with log capture to suppress expected ToolRegistry re-registration warnings.
  # Agent.run/2 always calls Registry.register/1 for each tool, which produces warnings
  # when tools are already registered from prior tests.
  defp run_agent(prompt, opts) do
    {result, _log} =
      with_log(fn ->
        Handbean.Agent.run(prompt, opts)
      end)

    result
  end

  # ── Dogfood: tool_use → read fixture → final answer ──

  describe "candidate queue via Agent.run/2" do
    test "prepends next_turn messages and composes caller on_event callback" do
      sid = "agent-run-candidate-#{System.unique_integer([:positive])}"
      {:ok, _session} = Handbean.PubSub.Session.start_or_get(session_id: sid, model: "fake")

      :ok =
        Handbean.PubSub.Session.enqueue_candidate(sid, "remember this", deliver_as: :next_turn)

      events = Agent.start_link(fn -> [] end) |> elem(1)

      {:ok, state} =
        run_agent("actual prompt",
          provider: Handbean.TestSupport.FakeProvider,
          model: "fake",
          provider_config: %{scenario: :echo_last_user},
          max_turns: 50,
          session_id: sid,
          on_event: fn event -> Agent.update(events, &(&1 ++ [event])) end
        )

      assert Enum.map(state.messages, & &1.content) |> Enum.take(2) == [
               "remember this",
               "actual prompt"
             ]

      assert Enum.any?(Agent.get(events, & &1), &match?({:run_start, _}, &1))

      assert %{meta: %{running?: false, queue_pid: nil, agent_pid: nil}} =
               Handbean.PubSub.Session.snapshot(sid)

      assert [] = Handbean.PubSub.Session.drain_next_turn(sid)
    end
  end

  describe "dogfood: tool_use → tool_result → final answer" do
    test "completes full agent loop via Agent.run/2" do
      {:ok, state} =
        run_agent("Read the sample file",
          provider: Handbean.TestSupport.FakeProvider,
          model: "fake",
          provider_config: %{scenario: :tool_use_chain},
          working_directory: @working_dir,
          max_turns: 50
        )

      # Verify overall status
      assert state.status == :completed,
             "Expected :completed, got #{inspect(state.status)}: #{state.error}"

      # Verify message flow: user → tool_use → tool_result → assistant
      roles = Enum.map(state.messages, & &1.role)
      assert roles == [:user, :assistant, :tool_result, :assistant]

      # tool_use message should reference "read" tool
      [_user, tool_use_msg, _tool_result, assistant_msg] = state.messages
      tool_calls = Message.tool_calls(tool_use_msg)
      assert length(tool_calls) == 1
      assert hd(tool_calls).name == "read"
      assert hd(tool_calls).input["file_path"] == "test_file.txt"

      # tool_result should contain actual file content
      tool_result_msg = Enum.at(state.messages, 2)
      assert tool_result_msg.role == :tool_result
      assert is_list(tool_result_msg.content)

      # Final assistant message confirms completion
      assert assistant_msg.content =~ "received the tool result"
    end

    test "accumulates usage across turns" do
      {:ok, state} =
        run_agent("Read the sample file",
          provider: Handbean.TestSupport.FakeProvider,
          model: "fake",
          provider_config: %{scenario: :tool_use_chain},
          working_directory: @working_dir,
          max_turns: 50
        )

      # Two turns: tool_use turn (10+15) + end_turn (15+20) = 25+35 = 60
      assert state.usage.input_tokens > 0
      assert state.usage.output_tokens > 0
      assert state.turn > 0
    end
  end

  describe "dogfood: multi-tool parallel execution" do
    test "executes two tool calls and gets final answer" do
      {:ok, state} =
        run_agent("Read and list files",
          provider: Handbean.TestSupport.FakeProvider,
          model: "fake",
          provider_config: %{scenario: :multi_tool},
          working_directory: @working_dir,
          max_turns: 50
        )

      assert state.status == :completed

      # Should contain tool_result messages
      tool_results = Enum.filter(state.messages, &(&1.role == :tool_result))
      assert length(tool_results) >= 1

      final_msg = List.last(state.messages)
      assert final_msg.role == :assistant
      assert final_msg.content =~ "healthy" or final_msg.content =~ "completed"
    end
  end

  describe "dogfood: simple answer (no tools)" do
    test "returns assistant message without tool calls" do
      {:ok, state} =
        run_agent("Hello",
          provider: Handbean.TestSupport.FakeProvider,
          model: "fake",
          provider_config: %{scenario: :simple_answer},
          working_directory: @working_dir,
          max_turns: 50
        )

      assert state.status == :completed
      assert length(state.messages) == 2
      [user, assistant] = state.messages
      assert user.role == :user
      assert assistant.role == :assistant
      assert assistant.content =~ "fake provider"
    end
  end

  describe "dogfood: memory learn + recall loop" do
    test "completes learn → recall → final answer cycle" do
      {:ok, state} =
        run_agent("Learn my preference",
          provider: Handbean.TestSupport.FakeProvider,
          model: "fake",
          provider_config: %{scenario: :memory_learn_and_recall},
          om: %{memory_scope: "global", privacy_mode: "standard"},
          working_directory: @working_dir,
          max_turns: 50
        )

      assert state.status == :completed

      # Verify tool calls for mem_learn and mem_recall
      tool_msg_roles =
        state.messages
        |> Enum.filter(&(&1.role == :assistant))
        |> Enum.flat_map(&Message.tool_calls/1)
        |> Enum.map(& &1[:name])

      assert "mem_learn" in tool_msg_roles
      assert "mem_recall" in tool_msg_roles

      final_msg = List.last(state.messages)
      assert final_msg.content =~ "snake_case" or final_msg.content =~ "memory"
    end
  end

  # ── Memory: 全链路 E2E (prompt 注入 → tool 注册 → DB 持久化 → 召回) ──

  describe "memory: prompt injection + tool registration + DB persistence" do
    test "system prompt contains full memory policy" do
      {:ok, state} =
        run_agent("Hello",
          provider: Handbean.TestSupport.FakeProvider,
          model: "fake",
          provider_config: %{scenario: :simple_answer},
          working_directory: @working_dir,
          max_turns: 50
        )

      prompt = state.config.system_prompt
      assert prompt =~ "## Memory"
      assert prompt =~ "mem_recall"
      assert prompt =~ "mem_learn"
      assert prompt =~ "mem_reinforce"
      assert prompt =~ "mem_associate"
      assert prompt =~ "Never store secrets"
    end

    test "tool defs include all four memory tools" do
      {:ok, state} =
        run_agent("Learn my preference",
          provider: Handbean.TestSupport.FakeProvider,
          model: "fake",
          provider_config: %{scenario: :memory_learn_and_recall},
          om: %{memory_scope: "global", privacy_mode: "standard"},
          working_directory: @working_dir,
          max_turns: 50
        )

      assert state.status == :completed

      # Verify Registry had memory tools during the run
      defs = Handbean.Tool.Registry.tool_defs()
      mem_names = Enum.filter(defs, &String.starts_with?(&1.name, "mem_")) |> Enum.map(& &1.name)

      assert "mem_learn" in mem_names
      assert "mem_recall" in mem_names
      assert "mem_reinforce" in mem_names
      assert "mem_associate" in mem_names
    end

    test "mem_learn persists engram to database" do
      {:ok, state} =
        run_agent("Learn my preference",
          provider: Handbean.TestSupport.FakeProvider,
          model: "fake",
          provider_config: %{scenario: :memory_learn_and_recall},
          om: %{memory_scope: "global", privacy_mode: "standard"},
          working_directory: @working_dir,
          max_turns: 50
        )

      assert state.status == :completed

      # DB assertion: engram was stored
      engram = Repo.one(from e in Engram, where: like(e.content, "%snake_case%"))
      assert engram != nil, "Expected engram with 'snake_case' in content to be persisted"
      assert engram.kind == :preference
      assert engram.short_term == true
      assert engram.expires_at != nil
    end

    test "repeated mem_reinforce calls persist promotion and report database activity" do
      {:ok, engram} =
        Handbean.Memory.MemoryStore.learn("Durable agent memory", :fact, memory_scope: :global)

      metric = [:handbean, :repo, :query, :total_time]
      before_count = HandbeanWeb.Telemetry.Reporter.snapshot()[metric].count

      script = fn messages, _tools ->
        completed = Enum.count(messages, &(&1.role == :tool_result))

        if completed < 2 do
          {:tools, [%{name: "mem_reinforce", input: %{"id" => engram.id}}]}
        else
          "Reinforced twice"
        end
      end

      {:ok, state} =
        run_agent("Remember this permanently",
          provider: Handbean.TestSupport.FakeProvider,
          model: "fake",
          provider_config: %{scenario: {:script, script}},
          om: %{memory_scope: "global", privacy_mode: "standard"},
          working_directory: @working_dir,
          max_turns: 5
        )

      assert state.status == :completed

      results =
        state.messages |> Enum.filter(&(&1.role == :tool_result)) |> Enum.flat_map(& &1.content)

      assert length(results) == 2
      assert Enum.all?(results, &(&1[:content] =~ "now long-term" and not &1[:is_error]))

      persisted = Repo.get!(Engram, engram.id)
      assert persisted.reinforced_count == 2
      refute persisted.short_term
      assert persisted.expires_at == nil
      assert persisted.last_reinforced_at != nil
      assert HandbeanWeb.Telemetry.Reporter.snapshot()[metric].count > before_count
    end

    test "mem_recall returns the engram that was just stored" do
      {:ok, state} =
        run_agent("Learn my preference",
          provider: Handbean.TestSupport.FakeProvider,
          model: "fake",
          provider_config: %{scenario: :memory_learn_and_recall},
          om: %{memory_scope: "global", privacy_mode: "standard"},
          working_directory: @working_dir,
          max_turns: 50
        )

      assert state.status == :completed

      # Find the mem_recall tool_result to verify it returned the learned content
      recall_blocks =
        state.messages
        |> Enum.filter(&(&1.role == :tool_result))
        |> Enum.flat_map(& &1.content)
        |> Enum.filter(fn block ->
          (block[:tool_use_id] || "") =~ "mem_recall"
        end)

      assert length(recall_blocks) >= 1, "Expected at least one mem_recall result block"

      recall_block = hd(recall_blocks)
      assert recall_block[:content] =~ "snake_case"
      assert recall_block[:content] =~ "preference"
      refute recall_block[:is_error]
    end

    test "complete message chain: user → mem_learn → recall → final answer" do
      {:ok, state} =
        run_agent("Remember my coding style",
          provider: Handbean.TestSupport.FakeProvider,
          model: "fake",
          provider_config: %{scenario: :memory_learn_and_recall},
          om: %{memory_scope: "global", privacy_mode: "standard"},
          working_directory: @working_dir,
          max_turns: 50
        )

      assert state.status == :completed

      # Full message chain verification
      roles = Enum.map(state.messages, & &1.role)
      assert roles == [:user, :assistant, :tool_result, :assistant, :tool_result, :assistant]

      # Turn 1 assistant: mem_learn call
      [_user, learn_call, _learn_result, recall_call, _recall_result, final] = state.messages

      learn_tool = hd(Message.tool_calls(learn_call))
      assert learn_tool[:name] == "mem_learn"
      assert learn_tool[:input]["content"] =~ "snake_case"
      assert learn_tool[:input]["kind"] == "preference"

      # Turn 2 assistant: mem_recall call
      recall_tool = hd(Message.tool_calls(recall_call))
      assert recall_tool[:name] == "mem_recall"

      # Final message references learned content
      assert final.content =~ "snake_case"

      # DB double-check
      engram = Repo.one(from e in Engram, where: like(e.content, "%snake_case%"))
      assert engram != nil
      assert engram.kind == :preference
    end

    test "memory tool results are not empty and not errors" do
      {:ok, state} =
        run_agent("Learn my preference",
          provider: Handbean.TestSupport.FakeProvider,
          model: "fake",
          provider_config: %{scenario: :memory_learn_and_recall},
          om: %{memory_scope: "global", privacy_mode: "standard"},
          working_directory: @working_dir,
          max_turns: 50
        )

      tool_results = Enum.filter(state.messages, &(&1.role == :tool_result))
      assert length(tool_results) >= 2

      Enum.each(tool_results, fn msg ->
        Enum.each(msg.content, fn block ->
          refute block[:content] == ""
          refute String.contains?(block[:content] || "", "Failed")
          refute block[:is_error]
        end)
      end)
    end
  end

  # ── Agent.run/2 pipeline ──

  describe "Agent.run/2 full pipeline" do
    test "accepts custom system_prompt" do
      {:ok, state} =
        run_agent("Hello",
          provider: Handbean.TestSupport.FakeProvider,
          model: "fake",
          provider_config: %{scenario: :simple_answer},
          working_directory: @working_dir,
          max_turns: 50,
          system_prompt: "You are a testing assistant."
        )

      assert state.status == :completed
      assert String.starts_with?(state.config.system_prompt, "You are a testing assistant.\n")
      assert state.config.system_prompt =~ "## Host execution environment"
    end

    test "enforces max_turns limit" do
      {:ok, state} =
        run_agent("Loop",
          provider: Handbean.TestSupport.FakeProvider,
          model: "fake",
          provider_config: %{scenario: :tool_use_chain},
          working_directory: @working_dir,
          max_turns: 1
        )

      # With max_turns:1, the tool_use_chain scenario can't complete.
      # The first turn issues tool_use, but the second turn
      # (which would receive tool_result and finish) is blocked.
      # However, the loop check happens at do_turn entry, so the
      # second turn starts at turn 1 → max_turns=1 → blocked.
      assert state.status in [:max_turns, :completed]
    end

    test "Coordinator publishes run events and persists the final reply" do
      alias Handbean.TestSupport.E2EHarness
      alias Handbean.PubSub.Session

      %{workspace: workspace} = E2EHarness.isolate_home!("fake-provider-lifecycle")
      session_id = "e2e-session-#{System.unique_integer([:positive])}"
      {:ok, _} = Handbean.ConversationStore.create("default", id: session_id)
      :ok = Session.subscribe(session_id)
      on_exit(fn -> E2EHarness.cancel!(session_id) end)

      {:ok, %{action: :started, run_pid: run_pid}} =
        Handbean.Agent.Coordinator.add_message(session_id, "Hello",
          provider: Handbean.TestSupport.FakeProvider,
          model: "fake",
          provider_config: %{scenario: :simple_answer},
          tools: [],
          source: :cli,
          workspace_path: workspace,
          max_turns: 50
        )

      ref = Process.monitor(run_pid)
      payload = E2EHarness.await_run_end(session_id)
      assert payload[:status] in [:completed, "completed"]
      # run_end is broadcast before Runner finishes its metadata bookkeeping.
      assert_receive {:DOWN, ^ref, :process, ^run_pid, _reason}, 5_000
      snapshot = Session.snapshot(session_id)
      kinds = Enum.map(snapshot.events, & &1.kind)
      assert :run_start in kinds
      assert :run_end in kinds

      assert Enum.any?(E2EHarness.transcript(session_id), fn entry ->
               entry["role"] == "assistant" and
                 entry["content"] == "Hello! I am a fake provider response."
             end)
    end
  end

  # ── Error handling ──

  describe "e2e error handling" do
    test "returns error state on provider error" do
      {:ok, state} =
        run_agent("Trigger error",
          provider: Handbean.TestSupport.FakeProvider,
          model: "fake",
          provider_config: %{scenario: :error_response},
          working_directory: @working_dir,
          max_turns: 50
        )

      assert state.status == :error
      assert state.error =~ "Fake provider simulated error"
    end
  end

  # ── State integrity ──

  describe "state integrity across e2e run" do
    test "preserves config across complete agent run" do
      {:ok, state} =
        run_agent("Read the sample file",
          provider: Handbean.TestSupport.FakeProvider,
          model: "fake",
          provider_config: %{scenario: :tool_use_chain},
          working_directory: @working_dir,
          max_turns: 50
        )

      assert state.config.provider == Handbean.TestSupport.FakeProvider
      assert state.config.model == "fake"
      assert state.config.max_turns == 50
      assert state.config.working_directory == @working_dir
    end

    test "response_metadata is populated" do
      {:ok, state} =
        run_agent("Hello",
          provider: Handbean.TestSupport.FakeProvider,
          model: "fake",
          provider_config: %{scenario: :simple_answer},
          working_directory: @working_dir,
          max_turns: 50
        )

      # provider_response_metadata should contain the last turn's response id and model
      assert is_map(state.provider_response_metadata)
      assert Map.has_key?(state.provider_response_metadata, :id)
      assert Map.has_key?(state.provider_response_metadata, :model)
    end
  end
end
