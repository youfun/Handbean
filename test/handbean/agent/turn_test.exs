defmodule Handbean.Agent.TurnTest do
  @moduledoc """
  Tests for the core agent loop (Handbean.Agent.Turn).

  Reference: `alloy/` (Agent Runtime Turn behavior)
  Test pattern reference: `jido_ai/test/support/fake_req_llm.ex` (fake provider)

  Covers:
    - Simple end_turn completion
    - tool_use → tool_result → final answer loop
    - Multi-tool parallel execution
    - Provider error handling
    - Max turns limit
    - Fake provider integration
  """

  use ExUnit.Case, async: true
  import ExUnit.CaptureLog, only: [with_log: 1]

  alias Handbean.Agent.{Config, State, Turn}
  alias Handbean.TestSupport.FakeProvider

  # Register tools needed for tests, avoiding re-registration warnings
  defp ensure_registered(mod) do
    case Handbean.Tool.Registry.get(mod.name()) do
      {:ok, _} -> :ok
      :error -> Handbean.Tool.Registry.register(mod)
    end
  end

  setup do
    ensure_registered(Handbean.Tool.Builtin.Read)
    ensure_registered(Handbean.Tool.Builtin.Bash)
    :ok
  end

  defmodule AuthFailureProvider do
    @behaviour Handbean.Agent.Provider

    @impl true
    def complete(_messages, _tools, _config) do
      {:error, "invalid_request_error: The OAuth2 access token could not be validated."}
    end

    @impl true
    def stream(messages, tools, config, _on_chunk), do: complete(messages, tools, config)
  end

  defmodule SensitiveInputProvider do
    @behaviour Handbean.Agent.Provider

    @impl true
    def complete(_messages, _tools, _config) do
      {:ok,
       %{
         stop_reason: :tool_use,
         messages: [
           Handbean.Agent.Message.tool_use([
             %{
               type: "tool_use",
               id: "sensitive",
               name: "read",
               input: %{"password" => "fixture-secret", "nested" => %{token: "nested-secret"}}
             }
           ])
         ],
         usage: %{input_tokens: 1, output_tokens: 1}
       }}
    end

    @impl true
    def stream(messages, tools, config, _on_chunk), do: complete(messages, tools, config)
  end

  defmodule FinalTurnProvider do
    @behaviour Handbean.Agent.Provider

    @impl true
    def complete(_messages, tools, config) do
      send(config.notify, {:final_turn_request, tools, config.system_prompt})

      {:ok,
       %{
         stop_reason: :end_turn,
         messages: [Handbean.Agent.Message.assistant("final summary")],
         usage: %{input_tokens: 1, output_tokens: 1}
       }}
    end

    @impl true
    def stream(messages, tools, config, _on_chunk), do: complete(messages, tools, config)
  end

  defmodule BufferLimitProvider do
    @behaviour Handbean.Agent.Provider

    alias Handbean.Agent.Message

    @impl true
    def complete(messages, _tools, config) do
      if String.starts_with?(config.system_prompt || "", "You are performing CONTEXT") do
        send(config.notify, :summary_request)
        {:error, :summary_unavailable}
      else
        send(config.notify, {:provider_request, messages})
        key = {__MODULE__, config.error}
        calls = Process.get(key, 0)
        Process.put(key, calls + 1)

        if calls == 0 do
          {:error, config.error}
        else
          {:ok,
           %{
             stop_reason: :end_turn,
             messages: [Message.assistant("Recovered after buffer compaction")],
             usage: %{input_tokens: 5, output_tokens: 5}
           }}
        end
      end
    end

    @impl true
    def stream(messages, tools, config, _on_chunk), do: complete(messages, tools, config)
  end

  defmodule NeverCalledProvider do
    @behaviour Handbean.Agent.Provider

    @impl true
    def complete(_messages, _tools, config) do
      send(config.notify, :provider_called)
      {:error, :should_not_be_called}
    end

    @impl true
    def stream(messages, tools, config, _on_chunk), do: complete(messages, tools, config)
  end

  test "tool_start redacts secrets for every tool, not just browser" do
    config = %Config{
      provider: SensitiveInputProvider,
      provider_config: %{},
      model: "fake",
      max_turns: 1
    }

    owner = self()
    Turn.run_loop(State.init(config, "test"), on_event: &send(owner, &1))

    assert_receive {:tool_start, %{tool: "read", input: input}}
    assert input["password"] == "[REDACTED]"
    assert input["nested"][:token] == "[REDACTED]"
  end

  defp injected_events(events) do
    events
    |> Agent.get(& &1)
    |> Enum.filter(&match?({:candidate_message_injected, _}, &1))
  end

  describe "simple completion (end_turn)" do
    test "returns completed state with assistant message" do
      config = %Config{
        provider: FakeProvider,
        model: "fake",
        max_turns: 50,
        provider_config: %{scenario: :simple_answer}
      }

      state = State.init(config, "Hello")
      result = Turn.run_loop(state, [])

      assert result.status == :completed
      last_msg = List.last(result.messages)
      assert last_msg.role == :assistant
      assert last_msg.content =~ "fake provider"
    end

    defmodule ThinkingOnlyEndTurnProvider do
      @behaviour Handbean.Agent.Provider

      alias Handbean.Agent.Message

      @impl true
      def complete(_messages, _tool_defs, _config) do
        {:ok,
         %{
           stop_reason: :end_turn,
           messages: [
             Message.assistant_blocks([
               %{type: "thinking", thinking: "I should call another tool, but did not emit it."}
             ])
           ],
           usage: %{input_tokens: 1, output_tokens: 1}
         }}
      end

      @impl true
      def stream(messages, tool_defs, config, _on_chunk),
        do: complete(messages, tool_defs, config)
    end

    test "does not mark thinking-only end_turn as completed" do
      config = %Config{
        provider: ThinkingOnlyEndTurnProvider,
        model: "fake",
        max_turns: 50,
        provider_config: %{}
      }

      state = State.init(config, "Continue after tools")
      result = Turn.run_loop(state, [])

      assert result.status == :error
      assert result.error =~ "no visible assistant response"
    end

    defmodule RecoveringEmptyEndTurnProvider do
      @behaviour Handbean.Agent.Provider

      alias Handbean.Agent.Message

      @impl true
      def complete(_messages, _tool_defs, _config) do
        count = Process.get(:empty_end_calls, 0) + 1
        Process.put(:empty_end_calls, count)

        if count == 1 do
          {:ok,
           %{
             stop_reason: :end_turn,
             messages: [
               Message.assistant_blocks([
                 %{type: "thinking", thinking: "need another pass"}
               ])
             ],
             usage: %{input_tokens: 1, output_tokens: 1}
           }}
        else
          {:ok,
           %{
             stop_reason: :end_turn,
             messages: [Message.assistant("continued after blank turn")],
             usage: %{input_tokens: 1, output_tokens: 1}
           }}
        end
      end

      @impl true
      def stream(messages, tool_defs, config, _on_chunk),
        do: complete(messages, tool_defs, config)
    end

    defmodule CommentaryThenFinalProvider do
      @behaviour Handbean.Agent.Provider

      alias Handbean.Agent.Message

      @impl true
      def complete(messages, _tool_defs, _config) do
        commentary? =
          Enum.any?(messages, fn
            %Message{content: blocks} when is_list(blocks) ->
              Enum.any?(blocks, &(&1[:phase] == "commentary"))

            _ ->
              false
          end)

        if commentary? do
          {:ok,
           %{
             stop_reason: :end_turn,
             messages: [
               Message.assistant_blocks([
                 %{type: "text", text: "Hello! How can I help?", phase: "final_answer"}
               ])
             ],
             usage: %{input_tokens: 1, output_tokens: 1}
           }}
        else
          {:ok,
           %{
             stop_reason: :end_turn,
             messages: [
               Message.assistant_blocks([
                 %{type: "text", text: "Hello! What can I help you with?", phase: "commentary"}
               ])
             ],
             usage: %{input_tokens: 1, output_tokens: 1}
           }}
        end
      end

      @impl true
      def stream(messages, _tool_defs, _config, on_chunk) do
        {:ok, result} = complete(messages, [], %{})
        text = Message.text(hd(result.messages))
        phase = hd(result.messages).content |> hd() |> Map.fetch!(:phase)
        on_chunk.(%{text: text, phase: phase, output_index: 0})
        {:ok, result}
      end
    end

    defmodule PhasedChunkProvider do
      @behaviour Handbean.Agent.Provider

      alias Handbean.Agent.Message

      @impl true
      def complete(_messages, _tool_defs, _config) do
        {:ok,
         %{
           stop_reason: :end_turn,
           messages: [
             Message.assistant_blocks([
               %{type: "text", text: "你好", phase: "final_answer", id: "msg_final"}
             ])
           ],
           usage: %{input_tokens: 1, output_tokens: 1}
         }}
      end

      @impl true
      def stream(_messages, _tool_defs, _config, on_chunk) do
        on_chunk.(%{text: "你", phase: "final_answer", output_index: 0})
        on_chunk.(%{text: "好", phase: "final_answer", output_index: 0})
        complete([], [], %{})
      end
    end

    test "phased stream chunks do not crash the streamed-text tracker" do
      config = %Config{
        provider: PhasedChunkProvider,
        model: "gpt-6-luna",
        max_turns: 2,
        provider_config: %{}
      }

      result = Turn.run_loop(State.init(config, "你好"), streaming: true, on_event: fn _ -> :ok end)

      assert result.status == :completed
      assert Handbean.Agent.Message.text(List.last(result.messages)) == "你好"
    end

    test "keeps commentary and requests one final answer without replaying it" do
      config = %Config{
        provider: CommentaryThenFinalProvider,
        model: "gpt-6-luna",
        max_turns: 4,
        provider_config: %{}
      }

      chunks = :counters.new(1, [])

      result =
        Turn.run_loop(State.init(config, "hello"),
          streaming: true,
          on_event: fn
            {:message_delta, %{chunk: chunk}} -> :counters.add(chunks, 1, byte_size(chunk))
            _ -> :ok
          end
        )

      texts = Enum.map(result.messages, &Handbean.Agent.Message.text/1)

      assert result.status == :completed
      assert Enum.join(texts, "\n") =~ "How can I help?"
      refute Enum.join(texts) =~ "What can I help you with?What can I help"

      assert :counters.get(chunks, 1) ==
               byte_size("Hello! What can I help you with?Hello! How can I help?")
    end

    test "retries a thinking-only end_turn once" do
      Process.delete(:empty_end_calls)

      config = %Config{
        provider: RecoveringEmptyEndTurnProvider,
        model: "fake",
        max_turns: 50,
        provider_config: %{}
      }

      state = State.init(config, "Continue after tools")
      result = Turn.run_loop(state, [])

      assert result.status == :completed
      assert List.last(result.messages).content == "continued after blank turn"
      assert Process.get(:empty_end_calls) == 2
    end

    defmodule TimeoutThenOkProvider do
      @behaviour Handbean.Agent.Provider

      alias Handbean.Agent.Message

      @impl true
      def complete(messages, _tool_defs, config) do
        stream(messages, [], config, fn _ -> :ok end)
      end

      @impl true
      def stream(messages, _tool_defs, _config, on_chunk) do
        count = Process.get(:timeout_then_ok_calls, 0) + 1
        Process.put(:timeout_then_ok_calls, count)

        if count == 1 do
          # Match production: grok already streamed tokens, so transport
          # retry is skipped and the follow_up path must take over.
          on_chunk.("partial")
          {:error, "HTTP request failed: %Finch.TransportError{reason: :timeout}"}
        else
          last = List.last(messages)

          {:ok,
           %{
             stop_reason: :end_turn,
             messages: [Message.assistant("resumed: #{last.content}")],
             usage: %{input_tokens: 1, output_tokens: 1}
           }}
        end
      end
    end

    test "continues with queued follow_up after a provider timeout" do
      Process.delete(:timeout_then_ok_calls)

      {:ok, queue} =
        Handbean.Agent.CandidateQueue.start_link(session_id: "turn-timeout-follow", owner: self())

      :ok = Handbean.Agent.CandidateQueue.enqueue(queue, "继续", deliver_as: :follow_up)

      config = %Config{
        provider: TimeoutThenOkProvider,
        model: "fake",
        max_turns: 50,
        provider_config: %{}
      }

      state = State.init(config, "write the manual")

      {:ok, events} = Agent.start_link(fn -> [] end)

      result =
        Turn.run_loop(state,
          candidate_queue: queue,
          streaming: true,
          on_event: fn event -> Agent.update(events, &(&1 ++ [event])) end
        )

      assert result.status == :completed
      assert List.last(result.messages).content == "resumed: 继续"
      assert Process.get(:timeout_then_ok_calls) == 2

      assert [
               {:candidate_message_injected,
                %{deliver_as: :follow_up, count: 1, message_ids: [follow_id]}}
             ] = injected_events(events)

      assert is_binary(follow_id)
    end
  end

  describe "tool_use → tool_result → final answer loop" do
    test "completes a full tool loop with fake provider" do
      config = %Config{
        provider: FakeProvider,
        model: "fake",
        max_turns: 50,
        working_directory: File.cwd!() |> Path.join("test/fixtures"),
        provider_config: %{scenario: :tool_use_chain}
      }

      state = State.init(config, "Read a file")
      result = Turn.run_loop(state, [])

      assert result.status == :completed

      # Ensure we got tool_use, tool_result, and assistant messages
      roles = Enum.map(result.messages, & &1.role)
      assert :assistant in roles
      assert :tool_result in roles

      final_msg = List.last(result.messages)
      assert final_msg.role == :assistant
      assert final_msg.content =~ "received the tool result"
    end

    test "handles multi-tool execution (parallel)" do
      config = %Config{
        provider: FakeProvider,
        model: "fake",
        max_turns: 50,
        working_directory: File.cwd!() |> Path.join("test/fixtures"),
        provider_config: %{scenario: :multi_tool}
      }

      state = State.init(config, "Read and list")
      result = Turn.run_loop(state, [])

      assert result.status == :completed

      # Verify tool results exist
      tool_result_msgs =
        Enum.filter(result.messages, &(&1.role == :tool_result))

      # At least one tool_result message (batched or individual)
      assert length(tool_result_msgs) >= 1

      # Final message should be the assistant's conclusion
      final_msg = List.last(result.messages)
      assert final_msg.role == :assistant
      assert final_msg.content =~ "healthy" or final_msg.content =~ "completed"
    end
  end

  describe "run_loop/1 with :after_compaction hook" do
    test "fires :after_compaction when compaction occurs" do
      test_pid = self()

      defmodule AfterCompactionTrackingMiddleware do
        @behaviour Handbean.Agent.Middleware

        def call(:after_compaction, state) do
          send(state.config.context[:test_pid], :after_compaction_fired)
          state
        end

        def call(_hook, state), do: state
      end

      config = %Config{
        provider: FakeProvider,
        model: "fake",
        provider_config: %{scenario: :simple_answer},
        middleware: [AfterCompactionTrackingMiddleware],
        context: %{test_pid: test_pid},
        max_tokens: 50,
        compaction: %{fallback: :truncate, reserve_tokens: 10, keep_recent_tokens: 5}
      }

      state =
        State.init(config, [
          Handbean.Agent.Message.user("original"),
          Handbean.Agent.Message.assistant(String.duplicate("a", 400)),
          Handbean.Agent.Message.user("latest")
        ])

      Turn.run_loop(state)

      assert_received :after_compaction_fired
    end

    test "does NOT fire :after_compaction when within budget" do
      test_pid = self()

      defmodule AfterCompactionNoFireMiddleware do
        @behaviour Handbean.Agent.Middleware

        def call(:after_compaction, state) do
          send(state.config.context[:test_pid], :after_compaction_should_not_fire)
          state
        end

        def call(_hook, state), do: state
      end

      config = %Config{
        provider: FakeProvider,
        model: "fake",
        provider_config: %{scenario: :simple_answer},
        middleware: [AfterCompactionNoFireMiddleware],
        context: %{test_pid: test_pid}
      }

      state = State.init(config, [Handbean.Agent.Message.user("Hi")])
      Turn.run_loop(state)

      refute_received :after_compaction_should_not_fire
    end

    test "halting in :after_compaction stops the turn" do
      defmodule AfterCompactionHaltMiddleware do
        @behaviour Handbean.Agent.Middleware

        def call(:after_compaction, _state), do: {:halt, "compaction policy violation"}
        def call(_hook, state), do: state
      end

      config = %Config{
        provider: FakeProvider,
        model: "fake",
        provider_config: %{scenario: :simple_answer, max_retries: 0, retry_delay_base_ms: 1},
        middleware: [AfterCompactionHaltMiddleware],
        max_tokens: 50,
        compaction: %{fallback: :truncate, reserve_tokens: 10, keep_recent_tokens: 5}
      }

      state =
        State.init(config, [
          Handbean.Agent.Message.user("original"),
          Handbean.Agent.Message.assistant(String.duplicate("a", 400)),
          Handbean.Agent.Message.user("latest")
        ])

      result = Turn.run_loop(state)

      assert result.status == :halted
      assert result.error =~ "compaction policy violation"
    end
  end

  describe "error handling" do
    test "names the subscription and model on an auth failure" do
      config = %Config{
        provider: AuthFailureProvider,
        model: "gpt-6-sol",
        max_turns: 1,
        provider_config: %{provider_key: "openai_codex", provider: "openai_codex"}
      }

      result = Turn.run_loop(State.init(config, "Trigger auth error"), [])

      assert result.status == :error
      assert result.error =~ "ChatGPT (Codex subscription)"
      assert result.error =~ "gpt-6-sol"
      assert result.error =~ "The OAuth2 access token could not be validated."
    end

    test "leaves non-auth provider errors unchanged" do
      config = %Config{
        provider: FakeProvider,
        model: "fake",
        max_turns: 50,
        provider_config: %{scenario: :error_response, provider_key: "openai_codex"}
      }

      result = Turn.run_loop(State.init(config, "Trigger error"), [])

      assert result.error == "Fake provider simulated error"
    end

    test "returns error state on provider error" do
      config = %Config{
        provider: FakeProvider,
        model: "fake",
        max_turns: 50,
        provider_config: %{scenario: :error_response}
      }

      state = State.init(config, "Trigger error")

      {result, _log} =
        with_log(fn ->
          Turn.run_loop(state, [])
        end)

      assert result.status == :error
      assert result.error != nil
      assert result.error =~ "Fake provider simulated error"
    end

    test "retries retryable provider errors before failing the turn" do
      config = %Config{
        provider: FakeProvider,
        model: "fake",
        max_turns: 50,
        provider_config: %{
          scenario: :transient_closed_once,
          max_retries: 1,
          retry_delay_base_ms: 1
        }
      }

      state = State.init(config, "Trigger transient error")
      test_pid = self()

      result =
        Turn.run_loop(state,
          on_progress: fn kind -> send(test_pid, {:progress, kind}) end
        )

      assert result.status == :completed
      assert List.last(result.messages).content =~ "Recovered after transient close"
      assert_received {:progress, :provider_retry}
    end

    test "does not retry streaming provider errors after a chunk was emitted" do
      config = %Config{
        provider: FakeProvider,
        model: "fake",
        max_turns: 50,
        provider_config: %{
          scenario: :streaming_error_after_chunk,
          max_retries: 2,
          retry_delay_base_ms: 1
        }
      }

      state = State.init(config, "Trigger streaming error")
      events = Agent.start_link(fn -> [] end) |> elem(1)

      {result, _log} =
        with_log(fn ->
          Turn.run_loop(state,
            streaming: true,
            on_event: fn event -> Agent.update(events, &(&1 ++ [event])) end
          )
        end)

      assert result.status == :error

      chunks =
        events
        |> Agent.get(& &1)
        |> Enum.filter(fn {kind, _payload} -> kind == :message_delta end)
        |> Enum.map(fn {_kind, payload} -> payload.chunk end)

      assert chunks == ["partial"]
    end

    test "nil max_turns does not stop a run past the old channel cap" do
      config = %Config{
        provider: FakeProvider,
        model: "fake",
        max_turns: nil,
        provider_config: %{scenario: :simple_answer}
      }

      result = Turn.run_loop(%{State.init(config, "hi") | turn: 200}, [])

      assert result.status == :completed
      assert result.turn == 201
    end

    test "unlimited runs do not strip tools to force a final answer" do
      config = %Config{
        provider: FinalTurnProvider,
        model: "fake",
        max_turns: nil,
        system_prompt: "base prompt",
        provider_config: %{notify: self()}
      }

      result = Turn.run_loop(State.init(config, "finish"), [])

      assert_receive {:final_turn_request, tools, system_prompt}
      assert tools != []
      refute system_prompt =~ "final agent step"
      assert result.status == :completed
    end

    test "returns max_turns state when limit exceeded" do
      config = %Config{
        provider: FakeProvider,
        model: "fake",
        max_turns: 1,
        provider_config: %{scenario: :tool_use_chain}
      }

      # This provider scenario would loop but max_turns stops it
      state = State.init(config, "Loop")
      # Set turn to max
      state = %{state | turn: 1}
      result = Turn.run_loop(state, [])

      assert result.status == :max_turns
    end

    test "final allowed turn disables tools and requests a closing summary" do
      config = %Config{
        provider: FinalTurnProvider,
        model: "fake",
        max_turns: 1,
        system_prompt: "base prompt",
        provider_config: %{notify: self()}
      }

      result = Turn.run_loop(State.init(config, "finish"), [])

      assert_receive {:final_turn_request, [], system_prompt}
      assert system_prompt =~ "base prompt"
      assert system_prompt =~ "final agent step"
      assert system_prompt =~ "Do not call tools"
      assert result.status == :completed
    end

    test "recovers from prompt-too-long by compacting and retrying" do
      config = %Config{
        provider: FakeProvider,
        model: "fake",
        max_turns: 50,
        max_tokens: 10_000,
        compaction: %{fallback: :truncate, reserve_tokens: 10, keep_recent_tokens: 5},
        provider_config: %{
          scenario: :prompt_too_long_once,
          max_retries: 0,
          retry_delay_base_ms: 1
        }
      }

      state =
        State.init(config, [
          Handbean.Agent.Message.user("original"),
          Handbean.Agent.Message.assistant(String.duplicate("a", 400)),
          Handbean.Agent.Message.user("latest")
        ])

      result = Turn.run_loop(state, [])

      assert result.status == :completed
      assert List.last(result.messages).content =~ "Recovered after compaction"
    end

    test "classifies the Magpie 507 buffer error as prompt-too-long and compacts once" do
      error =
        "Codex: 507 Insufficient Storage: exceeded request buffer limit while retrying upstream"

      config = %Config{
        provider: BufferLimitProvider,
        model: "fake",
        max_turns: 50,
        max_tokens: 10_000,
        compaction: %{fallback: :truncate, reserve_tokens: 1_000, keep_recent_tokens: 20},
        provider_config: %{error: error, notify: self(), max_retries: 3}
      }

      state =
        State.init(config, [
          Handbean.Agent.Message.user("original"),
          Handbean.Agent.Message.assistant(String.duplicate("a", 4_000)),
          Handbean.Agent.Message.user("latest")
        ])

      result = Turn.run_loop(state, [])

      assert_receive {:provider_request, first_request}
      assert_receive :summary_request
      assert_receive {:provider_request, second_request}
      assert length(second_request) == length(first_request)

      assert String.length(Enum.at(second_request, 1).content) <
               String.length(Enum.at(first_request, 1).content)

      assert result.status == :completed
    end

    test "does not classify an unrelated 507 as prompt-too-long" do
      error = "Codex: 507 Insufficient Storage: account storage unavailable"

      config = %Config{
        provider: BufferLimitProvider,
        model: "fake",
        max_turns: 50,
        max_tokens: 10_000,
        provider_config: %{error: error, notify: self(), max_retries: 0}
      }

      result = Turn.run_loop(State.init(config, "hello"), [])

      assert_receive {:provider_request, _messages}
      refute_receive :summary_request
      assert result.status == :error
      assert result.error == error
    end

    test "does not send a request that remains over the window after compaction" do
      config = %Config{
        provider: NeverCalledProvider,
        model: "fake",
        max_turns: 50,
        max_tokens: 100,
        compaction: %{fallback: :truncate, reserve_tokens: 10, keep_recent_tokens: 5},
        provider_config: %{notify: self()}
      }

      result = Turn.run_loop(State.init(config, String.duplicate("oversized", 2_000)), [])

      refute_receive :provider_called
      assert result.status == :error
      assert result.error =~ "Context remains too large after compaction"
      assert result.error =~ "request was not sent"
    end
  end

  describe "state management" do
    test "merges usage across turns" do
      config = %Config{
        provider: FakeProvider,
        model: "fake",
        max_turns: 50,
        provider_config: %{scenario: :simple_answer}
      }

      state = State.init(config, "Hello")
      result = Turn.run_loop(state, [])

      assert result.usage.input_tokens > 0
      assert result.usage.output_tokens > 0
    end

    test "increments turn counter" do
      config = %Config{
        provider: FakeProvider,
        model: "fake",
        max_turns: 50,
        provider_config: %{scenario: :simple_answer}
      }

      state = State.init(config, "Hello")
      result = Turn.run_loop(state, [])

      assert result.turn > 0
    end
  end

  describe "event emission" do
    test "streaming emits message_delta chunks" do
      config = %Config{
        provider: FakeProvider,
        model: "fake",
        max_turns: 50,
        provider_config: %{scenario: :streaming_chunks}
      }

      state = State.init(config, "Hello")
      events = Agent.start_link(fn -> [] end) |> elem(1)

      result =
        Turn.run_loop(state,
          streaming: true,
          on_event: fn event -> Agent.update(events, &(&1 ++ [event])) end
        )

      assert result.status == :completed

      chunks =
        events
        |> Agent.get(& &1)
        |> Enum.filter(fn {kind, _payload} -> kind == :message_delta end)
        |> Enum.map(fn {_kind, payload} -> payload.chunk end)

      assert chunks == ["Hello", " from", " stream"]
    end

    test "streaming emits final message when provider produces no chunks" do
      config = %Config{
        provider: FakeProvider,
        model: "fake",
        max_turns: 50,
        provider_config: %{scenario: :streaming_no_chunks}
      }

      state = State.init(config, "Hello")
      events = Agent.start_link(fn -> [] end) |> elem(1)

      result =
        Turn.run_loop(state,
          streaming: true,
          on_event: fn event -> Agent.update(events, &(&1 ++ [event])) end
        )

      assert result.status == :completed

      assert {:message_delta, %{chunk: "Fallback streamed response"}} in Agent.get(events, & &1)
    end

    test "streaming emits the missing final tail when final assistant text is longer than streamed chunks" do
      config = %Config{
        provider: FakeProvider,
        model: "fake",
        max_turns: 50,
        provider_config: %{scenario: :streaming_partial_then_final_longer}
      }

      state = State.init(config, "Hello")
      events = Agent.start_link(fn -> [] end) |> elem(1)

      result =
        Turn.run_loop(state,
          streaming: true,
          on_event: fn event -> Agent.update(events, &(&1 ++ [event])) end
        )

      assert result.status == :completed

      chunks =
        events
        |> Agent.get(& &1)
        |> Enum.filter(fn {kind, _payload} -> kind == :message_delta end)
        |> Enum.map(fn {_kind, payload} -> payload.chunk end)

      assert chunks == ["Now I have a", " complete", " picture of the codebase."]
    end

    test "provider thinking events are forwarded without becoming message text" do
      defmodule ThinkingEventProvider do
        @behaviour Handbean.Agent.Provider

        alias Handbean.Agent.Message

        def complete(messages, tool_defs, config),
          do: stream(messages, tool_defs, config, config.on_chunk)

        def stream(_messages, _tool_defs, config, _on_chunk) do
          config.on_event.({:thinking_delta, %{chunk: "private reasoning"}})

          {:ok,
           %{
             stop_reason: :end_turn,
             messages: [
               Message.assistant_blocks([
                 %{type: "thinking", thinking: "private reasoning"},
                 %{type: "text", text: "visible answer"}
               ])
             ],
             usage: %{input_tokens: 1, output_tokens: 2},
             response_metadata: %{}
           }}
        end
      end

      config = %Config{
        provider: ThinkingEventProvider,
        model: "fake",
        max_turns: 50,
        provider_config: %{}
      }

      state = State.init(config, "Hello")
      events = Agent.start_link(fn -> [] end) |> elem(1)

      result =
        Turn.run_loop(state,
          streaming: true,
          on_event: fn event -> Agent.update(events, &(&1 ++ [event])) end
        )

      assert result.status == :completed
      assert {:thinking_delta, %{chunk: "private reasoning"}} in Agent.get(events, & &1)
      assert {:message_delta, %{chunk: "visible answer"}} in Agent.get(events, & &1)
      refute {:message_delta, %{chunk: "private reasoning"}} in Agent.get(events, & &1)
    end

    test "usage updates are cumulative and arrive before tools and run_end" do
      config = %Config{
        provider: FakeProvider,
        model: "fake",
        max_turns: 50,
        provider_config: %{scenario: :tool_use_chain}
      }

      {:ok, events} = Agent.start_link(fn -> [] end)

      result =
        Turn.run_loop(State.init(config, "Read a file"),
          on_event: fn event -> Agent.update(events, &[event | &1]) end
        )

      assert result.status == :completed
      events = Agent.get(events, &Enum.reverse/1)

      relevant =
        Enum.filter(events, fn {kind, _} -> kind in [:usage_updated, :tool_start, :run_end] end)

      assert [
               {:usage_updated, %{usage: %{input_tokens: 10, output_tokens: 15}}},
               {:tool_start, _},
               {:usage_updated, %{usage: %{input_tokens: 25, output_tokens: 35}}},
               {:run_end, %{usage: %{input_tokens: 25, output_tokens: 35}}}
             ] = relevant
    end

    test "run_end event includes cumulative provider usage" do
      config = %Config{
        provider: FakeProvider,
        model: "fake",
        max_turns: 50,
        provider_config: %{scenario: :simple_answer}
      }

      state = State.init(config, "Hello")

      events =
        Agent.start_link(fn -> [] end)
        |> elem(1)

      result =
        Turn.run_loop(state,
          on_event: fn event ->
            Agent.update(events, &(&1 ++ [event]))
          end
        )

      assert result.status == :completed

      assert {:run_end, payload} =
               events
               |> Agent.get(& &1)
               |> Enum.find(fn {kind, _payload} -> kind == :run_end end)

      assert payload.usage.input_tokens > 0
      assert payload.usage.output_tokens > 0
    end
  end

  describe "candidate queue injection" do
    test "injects steer messages before provider call" do
      {:ok, queue} =
        Handbean.Agent.CandidateQueue.start_link(session_id: "turn-steer", owner: self())

      :ok =
        Handbean.Agent.CandidateQueue.enqueue(queue, "steer now",
          deliver_as: :steer,
          message_id: "msg-steer-start"
        )

      {:ok, events} = Agent.start_link(fn -> [] end)

      config = %Config{
        provider: FakeProvider,
        model: "fake",
        max_turns: 50,
        provider_config: %{scenario: :echo_last_user, notify: self()}
      }

      state = State.init(config, "initial")

      result =
        Turn.run_loop(state,
          candidate_queue: queue,
          on_event: fn event -> Agent.update(events, &(&1 ++ [event])) end
        )

      assert_receive {:provider_messages, provider_messages}
      assert Enum.map(provider_messages, & &1.content) == ["initial", "steer now"]
      assert result.status == :completed
      assert List.last(result.messages).content == "echo: steer now"

      assert [
               {:candidate_message_injected,
                %{deliver_as: :steer, count: 1, message_ids: ["msg-steer-start"]}}
             ] = injected_events(events)
    end

    test "injects steer messages after tool execution before the next provider call" do
      {:ok, queue} =
        Handbean.Agent.CandidateQueue.start_link(session_id: "turn-tool-steer", owner: self())

      test_pid = self()
      {:ok, events} = Agent.start_link(fn -> [] end)

      config = %Config{
        provider: FakeProvider,
        model: "fake",
        max_turns: 50,
        working_directory: File.cwd!() |> Path.join("test/fixtures"),
        provider_config: %{scenario: :steer_after_tool, notify: self()}
      }

      state = State.init(config, "read first")

      result =
        Turn.run_loop(state,
          candidate_queue: queue,
          on_event: fn
            {:tool_end, _payload} = event ->
              Agent.update(events, &(&1 ++ [event]))

              Handbean.Agent.CandidateQueue.enqueue(queue, "after tool",
                deliver_as: :steer,
                message_id: "msg-steer-after-tool"
              )

              send(test_pid, :tool_ended)

            event ->
              Agent.update(events, &(&1 ++ [event]))
          end
        )

      assert_receive :tool_ended
      assert_receive {:provider_messages, first_call}
      assert_receive {:provider_messages, second_call}
      refute Enum.any?(first_call, &(&1.content == "after tool"))
      assert Enum.any?(second_call, &(&1.role == :user and &1.content == "after tool"))
      assert result.status == :completed
      assert List.last(result.messages).content == "echo: after tool"

      assert [
               {:candidate_message_injected,
                %{deliver_as: :steer, count: 1, message_ids: ["msg-steer-after-tool"]}}
             ] = injected_events(events)
    end

    test "continues after end_turn when follow_up messages are pending" do
      {:ok, queue} =
        Handbean.Agent.CandidateQueue.start_link(session_id: "turn-follow", owner: self())

      :ok =
        Handbean.Agent.CandidateQueue.enqueue(queue, "follow up",
          deliver_as: :follow_up,
          message_id: "msg-follow-end"
        )

      {:ok, events} = Agent.start_link(fn -> [] end)

      config = %Config{
        provider: FakeProvider,
        model: "fake",
        max_turns: 50,
        provider_config: %{scenario: :echo_last_user, notify: self()}
      }

      state = State.init(config, "initial")

      result =
        Turn.run_loop(state,
          candidate_queue: queue,
          on_event: fn event -> Agent.update(events, &(&1 ++ [event])) end
        )

      assert_receive {:provider_messages, first_call}
      assert_receive {:provider_messages, second_call}
      assert Enum.map(first_call, & &1.content) == ["initial"]
      assert Enum.any?(second_call, &(&1.role == :user and &1.content == "follow up"))
      assert result.status == :completed
      assert result.turn == 2
      assert List.last(result.messages).content == "echo: follow up"

      assert injected_events(events) == [
               {:candidate_message_injected, %{deliver_as: :steer, count: 0, message_ids: []}},
               {:candidate_message_injected,
                %{deliver_as: :follow_up, count: 1, message_ids: ["msg-follow-end"]}}
             ]
    end

    test "emits message_ids for remaining follow_up after start-of-turn steer drain" do
      {:ok, queue} =
        Handbean.Agent.CandidateQueue.start_link(session_id: "turn-both-pending", owner: self())

      :ok =
        Handbean.Agent.CandidateQueue.enqueue(queue, "steer first",
          deliver_as: :steer,
          message_id: "msg-both-steer"
        )

      :ok =
        Handbean.Agent.CandidateQueue.enqueue(queue, "follow later",
          deliver_as: :follow_up,
          message_id: "msg-both-follow"
        )

      {:ok, events} = Agent.start_link(fn -> [] end)

      config = %Config{
        provider: FakeProvider,
        model: "fake",
        max_turns: 50,
        provider_config: %{scenario: :echo_last_user, notify: self()}
      }

      state = State.init(config, "initial")

      result =
        Turn.run_loop(state,
          candidate_queue: queue,
          on_event: fn event -> Agent.update(events, &(&1 ++ [event])) end
        )

      assert result.status == :completed

      assert injected_events(events) == [
               {:candidate_message_injected,
                %{deliver_as: :steer, count: 1, message_ids: ["msg-both-steer"]}},
               {:candidate_message_injected, %{deliver_as: :steer, count: 0, message_ids: []}},
               {:candidate_message_injected,
                %{deliver_as: :follow_up, count: 1, message_ids: ["msg-both-follow"]}}
             ]
    end

    test "keeps completed behavior when no pending messages exist" do
      {:ok, queue} =
        Handbean.Agent.CandidateQueue.start_link(session_id: "turn-none", owner: self())

      config = %Config{
        provider: FakeProvider,
        model: "fake",
        max_turns: 50,
        provider_config: %{scenario: :simple_answer}
      }

      state = State.init(config, "Hello")
      result = Turn.run_loop(state, candidate_queue: queue)

      assert result.status == :completed
      assert length(result.messages) == 2

      assert {:error, :sealed} =
               Handbean.Agent.CandidateQueue.enqueue(queue, "arrived after completion")
    end

    test "does not leak the streamed text tracker process" do
      config = %Config{
        provider: FakeProvider,
        model: "fake",
        max_turns: 50,
        provider_config: %{scenario: :streaming_chunks}
      }

      before_links = self() |> Process.info(:links) |> elem(1) |> MapSet.new()

      try do
        state = State.init(config, "Hello")
        assert %State{status: :completed} = Turn.run_loop(state, streaming: true)

        after_links = self() |> Process.info(:links) |> elem(1) |> MapSet.new()
        assert MapSet.equal?(after_links, before_links)
      after
        self()
        |> Process.info(:links)
        |> elem(1)
        |> MapSet.new()
        |> MapSet.difference(before_links)
        |> Enum.each(fn pid ->
          if Process.alive?(pid), do: Agent.stop(pid)
        end)
      end
    end
  end

  describe "fake provider scenarios" do
    test "simple_answer produces one message" do
      config = %Config{
        provider: FakeProvider,
        model: "fake",
        max_turns: 50,
        provider_config: %{scenario: :simple_answer}
      }

      state = State.init(config, "Hello")
      result = Turn.run_loop(state, [])

      # Should have: user message + assistant message = 2
      assert length(result.messages) == 2
    end
  end

  describe "tool_end event emission" do
    setup do
      ensure_registered(Handbean.Tool.Builtin.Read)
      ensure_registered(Handbean.Tool.Builtin.Bash)
      ensure_registered(Handbean.Tool.Builtin.Write)

      tmp_dir =
        Path.join(System.tmp_dir!(), "sigil_turn_tool_end_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      {:ok, tmp_dir: tmp_dir}
    end

    test "emits file_path in tool_end for write tool", %{tmp_dir: tmp_dir} do
      config = %Config{
        provider: FakeProvider,
        model: "fake",
        max_turns: 50,
        working_directory: tmp_dir,
        provider_config: %{scenario: :tool_use_chain}
      }

      state = State.init(config, "Write a file")

      # Directly test via Executor to verify ui_blocks have details
      alias Handbean.Agent.Tool.Executor

      tool_calls = [
        %{
          id: "tend_1",
          name: "write",
          input: %{"file_path" => "hello.exs", "content" => "IO.puts(\"hi\")"}
        }
      ]

      {:ok, _result_msg, ui_blocks} = Executor.execute_all_with_details(tool_calls, state)

      [ui_block] = ui_blocks
      assert ui_block[:details][:file_path] == Path.join(tmp_dir, "hello.exs")
      assert ui_block[:details][:bytes] == 13
    end

    test "provider result_msg has no details even when ui_blocks do", %{tmp_dir: tmp_dir} do
      alias Handbean.Agent.Tool.Executor

      config = %Config{
        working_directory: tmp_dir
      }

      state = State.init(config, "Write")

      tool_calls = [
        %{
          id: "nd_1",
          name: "write",
          input: %{"file_path" => "no_details.exs", "content" => ":ok"}
        }
      ]

      {:ok, result_msg, ui_blocks} = Executor.execute_all_with_details(tool_calls, state)

      [block] = result_msg.content
      refute Map.has_key?(block, :details)

      [ui_block] = ui_blocks
      assert Map.has_key?(ui_block, :details)
      assert ui_block[:details][:file_path] == Path.join(tmp_dir, "no_details.exs")
    end

    test "tool events via on_event contain stable tool_use_id", %{tmp_dir: tmp_dir} do
      config = %Config{
        provider: FakeProvider,
        model: "fake",
        max_turns: 50,
        working_directory: tmp_dir,
        provider_config: %{scenario: :tool_use_chain}
      }

      state = State.init(config, "Read a file")
      events = Agent.start_link(fn -> [] end) |> elem(1)

      _result =
        with_log(fn ->
          Turn.run_loop(state,
            on_event: fn event -> Agent.update(events, &(&1 ++ [event])) end
          )
        end)

      emitted = Agent.get(events, & &1)

      turn_events =
        Enum.filter(emitted, fn {kind, _payload} -> kind in [:turn_start, :turn_end] end)

      assert [
               {:turn_start, %{turn: 1}},
               {:turn_end, %{turn: 1, stop_reason: "tool_use"}},
               {:turn_start, %{turn: 2}},
               {:turn_end, %{turn: 2, stop_reason: "completed"}}
             ] = turn_events

      assert {:tool_start, %{tool_use_id: "toolu_001", tool: "read"}} =
               Enum.find(emitted, fn {kind, _payload} -> kind == :tool_start end)

      assert {:tool_end,
              %{
                tool_use_id: "toolu_001",
                tool: "read",
                file_path: file_path,
                duration_ms: duration_ms,
                started_at: started_at,
                completed_at: completed_at,
                timing_fidelity: "exact",
                turn_number: 1
              }} = Enum.find(emitted, fn {kind, _payload} -> kind == :tool_end end)

      assert file_path == "test_file.txt"
      assert is_integer(duration_ms) and duration_ms >= 0
      assert is_binary(started_at)
      assert is_binary(completed_at)
    end
  end
end

defmodule Handbean.Agent.TurnPermissionTest do
  use ExUnit.Case, async: true

  alias Handbean.Agent.{Config, Message, State, Turn}

  defmodule TouchFixtureTool do
    @behaviour Handbean.Agent.Tool

    def name, do: "permission_touch_fixture"
    def description, do: "Deterministic permission-flow fixture"
    def input_schema, do: %{type: "object", properties: %{file: %{type: "string"}}}

    def execute(%{"file" => file}, %{working_directory: workspace}) do
      :ok = File.write(Path.join(workspace, file), "approved")
      {:ok, "touched #{file}", %{file_path: file}}
    end
  end

  setup do
    :ok = Handbean.Tool.Registry.register(TouchFixtureTool, override: true)
    on_exit(fn -> Handbean.Tool.Registry.unregister(TouchFixtureTool.name()) end)
    :ok
  end

  defmodule TouchProvider do
    @behaviour Handbean.Agent.Provider

    @impl true
    def complete(messages, _tool_defs, _config) do
      if Enum.any?(messages, &match?(%Message{role: :tool_result}, &1)) do
        {:ok,
         %{
           stop_reason: :end_turn,
           messages: [Message.assistant("done")],
           usage: %{input_tokens: 1, output_tokens: 1}
         }}
      else
        {:ok,
         %{
           stop_reason: :tool_use,
           messages: [
             Message.tool_use([
               %{
                 type: "tool_use",
                 id: "touch_1",
                 name: "permission_touch_fixture",
                 input: %{"file" => "denied_marker"}
               }
             ])
           ],
           usage: %{input_tokens: 1, output_tokens: 1}
         }}
      end
    end

    @impl true
    def stream(messages, tool_defs, config, _on_chunk), do: complete(messages, tool_defs, config)
  end

  defp tmp_workspace(settings) do
    dir =
      Path.join(System.tmp_dir!(), "sigil_turn_permissions_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(dir, ".handbean"))
    File.write!(Path.join(dir, ".handbean/settings.jsonc"), Jason.encode!(settings))
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  test "deny policy returns a tool error result and does not execute the tool" do
    workspace =
      tmp_workspace(%{"tools" => %{"per_tool" => %{"permission_touch_fixture" => "deny"}}})

    config = %Config{
      provider: TouchProvider,
      model: "fake",
      max_turns: 5,
      working_directory: workspace,
      middleware: [Handbean.Agent.Middleware.ToolGuard],
      provider_config: %{}
    }

    result = Turn.run_loop(State.init(config, "touch a marker"), [])

    refute File.exists?(Path.join(workspace, "denied_marker"))
    assert result.status == :completed

    tool_result = Enum.find(result.messages, &(&1.role == :tool_result))
    assert [%{content: content, is_error: true}] = tool_result.content
    assert content =~ "Tool call denied by workspace permissions"
    refute content =~ "touch denied_marker"
  end

  test "deny policy injects steer candidates after blocked tools" do
    workspace =
      tmp_workspace(%{"tools" => %{"per_tool" => %{"permission_touch_fixture" => "deny"}}})

    {:ok, queue} =
      Handbean.Agent.CandidateQueue.start_link(session_id: "turn-deny-inject", owner: self())

    defmodule EnqueueSteerAfterToolRequest do
      @behaviour Handbean.Agent.Middleware

      def call(:after_tool_request, state) do
        queue = state.config.context[:queue]

        :ok =
          Handbean.Agent.CandidateQueue.enqueue(queue, "steer after deny-block",
            deliver_as: :steer,
            message_id: "msg-deny-block-steer"
          )

        state
      end

      def call(_hook, state), do: state
    end

    {:ok, events} = Agent.start_link(fn -> [] end)

    config = %Config{
      provider: TouchProvider,
      model: "fake",
      max_turns: 5,
      working_directory: workspace,
      middleware: [EnqueueSteerAfterToolRequest, Handbean.Agent.Middleware.ToolGuard],
      context: %{queue: queue},
      provider_config: %{}
    }

    result =
      Turn.run_loop(State.init(config, "touch a marker"),
        candidate_queue: queue,
        on_event: fn event -> Agent.update(events, &(&1 ++ [event])) end
      )

    assert result.status == :completed

    injected =
      events
      |> Agent.get(& &1)
      |> Enum.filter(&match?({:candidate_message_injected, _}, &1))

    assert [
             {:candidate_message_injected,
              %{deliver_as: :steer, count: 1, message_ids: ["msg-deny-block-steer"]}}
             | _
           ] = injected
  end

  test "prompt policy interrupts before tool execution and emits approval request" do
    workspace =
      tmp_workspace(%{"tools" => %{"per_tool" => %{"permission_touch_fixture" => "prompt"}}})

    events = Agent.start_link(fn -> [] end) |> elem(1)

    config = %Config{
      provider: TouchProvider,
      model: "fake",
      max_turns: 5,
      working_directory: workspace,
      middleware: [Handbean.Agent.Middleware.ToolGuard],
      provider_config: %{}
    }

    result =
      Turn.run_loop(State.init(config, "touch a marker"),
        on_event: fn event -> Agent.update(events, &(&1 ++ [event])) end
      )

    refute File.exists?(Path.join(workspace, "denied_marker"))
    assert result.status == :interrupted
    assert result.interrupt_data.type == :tool_approval
    assert result.interrupt_data.hitl_tool_call_ids == ["touch_1"]

    assert Enum.any?(Agent.get(events, & &1), fn
             {:tool_approval_requested, %{hitl_tool_call_ids: ["touch_1"]}} -> true
             _ -> false
           end)
  end

  describe "resume_after_tool_approval/3" do
    alias Handbean.Agent.Message

    # Build an interrupted state simulating a tool_guard deny scenario.
    # This mirrors the state produced when a deny policy intercepts a tool call.
    defp build_interrupted_state do
      config = %Config{
        provider: TouchProvider,
        model: "fake",
        max_turns: 5,
        provider_config: %{}
      }

      tool_call_block = %{
        type: "tool_use",
        id: "touch_1",
        name: "bash",
        input: %{"command" => "echo hello"}
      }

      %State{
        config: config,
        messages: [
          Message.user("do something"),
          Message.tool_use([tool_call_block])
        ],
        turn: 1,
        status: :interrupted,
        error: nil,
        usage: %{input_tokens: 0, output_tokens: 0},
        tool_calls: [],
        provider_state: %{},
        response_metadata: %{},
        run_metadata: %{},
        provider_response_metadata: %{},
        interrupt_data: %{
          type: :tool_approval,
          hitl_tool_call_ids: ["touch_1"]
        },
        tool_guard_overrides: %{},
        tool_guard_denied_calls: [],
        tool_guard_result_blocks: []
      }
    end

    test "returns unchanged state for non-interrupted state with warning" do
      state = State.init(%Config{provider: TouchProvider, model: "fake", max_turns: 5}, "hello")
      assert state.status == :running

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          result = Turn.resume_after_tool_approval(state, [], [])
          assert result == state
        end)

      assert log =~ "resume_after_tool_approval called on non-interrupted state"
    end

    test "all-denied decisions produce denied result blocks and clear interrupt" do
      state = build_interrupted_state()
      decisions = [%{"tool_call_id" => "touch_1", "action" => "deny"}]

      result =
        Turn.resume_after_tool_approval(state, decisions,
          on_event: &send(self(), {:resume_event, &1})
        )

      assert result.status == :completed
      assert result.interrupt_data == nil
      assert length(result.tool_guard_result_blocks) >= 1
      assert_receive {:resume_event, {:run_end, %{status: :completed, turns: 2, usage: usage}}}
      assert usage == result.usage
      assert_receive {:resume_event, {:agent_end, %{status: :completed}}}
      refute_receive {:resume_event, {:run_end, _}}
      refute_receive {:resume_event, {:run_start, _}}

      # Check the denied block format
      denied_block = hd(result.tool_guard_result_blocks)
      assert denied_block[:type] == "tool_result" || denied_block["type"] == "tool_result"
      assert denied_block[:is_error] == true || denied_block["is_error"] == true

      id = denied_block[:tool_use_id] || denied_block["tool_use_id"]
      assert id == "touch_1"
    end

    test "all-denied resume injects steer candidates with message_ids" do
      {:ok, queue} =
        Handbean.Agent.CandidateQueue.start_link(
          session_id: "turn-resume-deny-steer",
          owner: self()
        )

      :ok =
        Handbean.Agent.CandidateQueue.enqueue(queue, "steer after deny",
          deliver_as: :steer,
          message_id: "msg-resume-deny-steer"
        )

      state = build_interrupted_state()
      decisions = [%{"tool_call_id" => "touch_1", "action" => "deny"}]

      result =
        Turn.resume_after_tool_approval(state, decisions,
          candidate_queue: queue,
          on_event: &send(self(), {:resume_event, &1})
        )

      assert result.status == :completed

      assert_receive {:resume_event,
                      {:candidate_message_injected,
                       %{
                         deliver_as: :steer,
                         count: 1,
                         message_ids: ["msg-resume-deny-steer"]
                       }}}
    end

    test "remember deny sets tool_guard_overrides" do
      state = build_interrupted_state()
      decisions = [%{"tool_call_id" => "touch_1", "action" => "deny", "remember" => true}]

      result = Turn.resume_after_tool_approval(state, decisions, [])

      assert result.tool_guard_overrides["bash"] == :deny ||
               result.tool_guard_overrides[:bash] == :deny
    end

    test "deny plus skip on a mixed HITL batch does not hang" do
      config = %Config{
        provider: TouchProvider,
        model: "fake",
        max_turns: 5,
        provider_config: %{}
      }

      one = %{type: "tool_use", id: "a1", name: "open_url", input: %{}}
      two = %{type: "tool_use", id: "a2", name: "share_file", input: %{}}

      state = %State{
        config: config,
        messages: [Message.user("do"), Message.tool_use([one, two])],
        turn: 1,
        status: :interrupted,
        error: nil,
        usage: %{input_tokens: 0, output_tokens: 0},
        tool_calls: [],
        provider_state: %{},
        response_metadata: %{},
        run_metadata: %{},
        provider_response_metadata: %{},
        interrupt_data: %{
          type: :tool_approval,
          hitl_tool_call_ids: ["a1", "a2"]
        },
        tool_guard_overrides: %{},
        tool_guard_denied_calls: [],
        tool_guard_result_blocks: []
      }

      result =
        Turn.resume_after_tool_approval(
          state,
          [
            %{"tool_call_id" => "a1", "action" => "deny"},
            %{"tool_call_id" => "a2", "action" => "skip"}
          ],
          []
        )

      refute result.status == :interrupted

      skipped =
        Enum.find(
          result.tool_guard_result_blocks,
          &((&1[:tool_use_id] || &1["tool_use_id"]) == "a2")
        )

      assert skipped
      content = skipped[:content] || skipped["content"]
      assert content =~ "Not selected this round"
      refute content =~ "denied by user"
    end

    test "skip is distinct from a user deny" do
      state = build_interrupted_state()
      decisions = [%{"tool_call_id" => "touch_1", "action" => "skip"}]

      result = Turn.resume_after_tool_approval(state, decisions, [])
      denied_block = hd(result.tool_guard_result_blocks)
      content = denied_block[:content] || denied_block["content"]
      details = denied_block[:details] || denied_block["details"]
      assert content =~ "Not selected this round"
      refute content =~ "denied by user"
      assert (details[:permission] || details["permission"]) in [:skipped, "skipped"]
    end

    test "denying a HITL call leaves auto-approved siblings executable" do
      config = %Config{
        provider: TouchProvider,
        model: "fake",
        max_turns: 5,
        provider_config: %{}
      }

      opened = %{type: "tool_use", id: "open_1", name: "open_url", input: %{}}
      auto = %{type: "tool_use", id: "read_1", name: "read", input: %{"file_path" => "x"}}

      state = %State{
        config: config,
        messages: [Message.user("do"), Message.tool_use([opened, auto])],
        turn: 1,
        status: :interrupted,
        error: nil,
        usage: %{input_tokens: 0, output_tokens: 0},
        tool_calls: [],
        provider_state: %{},
        response_metadata: %{},
        run_metadata: %{},
        provider_response_metadata: %{},
        interrupt_data: %{
          type: :tool_approval,
          hitl_tool_call_ids: ["open_1"],
          auto_approved_tool_call_ids: ["read_1"]
        },
        tool_guard_overrides: %{},
        tool_guard_denied_calls: [],
        tool_guard_result_blocks: []
      }

      result =
        Turn.resume_after_tool_approval(
          state,
          [%{"tool_call_id" => "open_1", "action" => "deny"}],
          []
        )

      denied = result.tool_guard_result_blocks
      assert Enum.any?(denied, &((&1[:tool_use_id] || &1["tool_use_id"]) == "open_1"))
      refute Enum.any?(denied, &((&1[:tool_use_id] || &1["tool_use_id"]) == "read_1"))
    end

    test "resume executes only explicitly permitted ids and preserves hard denials" do
      workspace = tmp_workspace(%{})

      calls = [
        %{
          type: "tool_use",
          id: "hard-denied",
          name: "permission_touch_fixture",
          input: %{"file" => "hard-denied"}
        },
        %{
          type: "tool_use",
          id: "approved",
          name: "permission_touch_fixture",
          input: %{"file" => "approved"}
        },
        %{
          type: "tool_use",
          id: "unclassified",
          name: "permission_touch_fixture",
          input: %{"file" => "unclassified"}
        }
      ]

      hard_block =
        Message.tool_result_block(
          "hard-denied",
          "Tool call denied by workspace permissions",
          true,
          %{permission: :denied, tool: "permission_touch_fixture"}
        )

      config = %Config{
        provider: TouchProvider,
        model: "fake",
        max_turns: 5,
        working_directory: workspace,
        middleware: [],
        provider_config: %{}
      }

      state = %State{
        State.init(config, "do")
        | messages: [Message.user("do"), Message.tool_use(calls)],
          turn: 1,
          status: :interrupted,
          interrupt_data: %{
            type: :tool_approval,
            hitl_tool_call_ids: ["approved"],
            auto_approved_tool_call_ids: ["hard-denied"]
          },
          tool_guard_denied_calls: [hd(calls)],
          tool_guard_result_blocks: [hard_block]
      }

      result =
        Turn.resume_after_tool_approval(
          state,
          [%{"tool_call_id" => "approved", "action" => "approve"}],
          []
        )

      assert result.status == :completed
      assert File.read!(Path.join(workspace, "approved")) == "approved"
      refute File.exists?(Path.join(workspace, "hard-denied"))
      refute File.exists?(Path.join(workspace, "unclassified"))

      assert MapSet.new(Enum.map(result.tool_guard_result_blocks, & &1.tool_use_id)) ==
               MapSet.new(["hard-denied", "unclassified"])
    end

    test "empty decisions default all to deny" do
      state = build_interrupted_state()

      result = Turn.resume_after_tool_approval(state, [], [])

      assert result.status == :completed
      assert result.interrupt_data == nil
      assert length(result.tool_guard_result_blocks) >= 1
    end

    test "denied_result_block produces properly formatted block" do
      # This is a private function tested via the resume flow above,
      # but we verify the format is consistent.
      state = build_interrupted_state()
      decisions = [%{"tool_call_id" => "touch_1", "action" => "deny"}]

      result = Turn.resume_after_tool_approval(state, decisions, [])

      denied_block = hd(result.tool_guard_result_blocks)

      assert (denied_block[:type] || denied_block["type"]) == "tool_result"
      assert (denied_block[:tool_use_id] || denied_block["tool_use_id"]) == "touch_1"
      assert (denied_block[:is_error] || denied_block["is_error"]) == true

      content = denied_block[:content] || denied_block["content"]
      assert is_binary(content) and byte_size(content) > 0
    end

    test "approve executes the pending HITL tool call instead of skipping it" do
      workspace =
        tmp_workspace(%{"tools" => %{"per_tool" => %{"permission_touch_fixture" => "prompt"}}})

      marker = Path.join(workspace, "denied_marker")

      config = %Config{
        provider: TouchProvider,
        model: "fake",
        max_turns: 5,
        working_directory: workspace,
        middleware: [Handbean.Agent.Middleware.ToolGuard],
        provider_config: %{}
      }

      state = State.init(config, "touch approved_marker")
      interrupted = Turn.run_loop(state, [])

      assert interrupted.status == :interrupted
      assert interrupted.interrupt_data.hitl_tool_call_ids == ["touch_1"]
      refute File.exists?(marker)

      resumed =
        Turn.resume_after_tool_approval(
          interrupted,
          [
            %{
              "tool_call_id" => "touch_1",
              "tool_name" => "permission_touch_fixture",
              "action" => "approve"
            }
          ],
          on_event: &send(self(), {:resume_event, &1})
        )

      assert resumed.status == :completed
      assert resumed.interrupt_data == nil
      assert File.exists?(marker)

      assert_receive {:resume_event, {:tool_start, %{tool_use_id: "touch_1", turn_number: 1}}}

      assert_receive {:resume_event, {:tool_end, %{tool_use_id: "touch_1", turn_number: 1}}}

      assert_receive {:resume_event,
                      {:turn_end, %{turn: 1, status: :completed, stop_reason: "tool_use_resumed"}}}

      assert_receive {:resume_event, {:run_end, %{status: :completed, usage: usage}}}
      assert usage == resumed.usage
      assert_receive {:resume_event, {:agent_end, %{status: :completed}}}
      refute_receive {:resume_event, {:run_end, _}}
      refute_receive {:resume_event, {:run_start, _}}

      tool_result =
        resumed.messages
        |> Enum.flat_map(fn
          %Message{role: role, content: blocks}
          when role in [:tool, :tool_result] and is_list(blocks) ->
            blocks

          _ ->
            []
        end)
        |> Enum.find(
          &(Map.get(&1, :tool_use_id) == "touch_1" or Map.get(&1, "tool_use_id") == "touch_1")
        )

      refute is_nil(tool_result)
      refute tool_result[:is_error] || tool_result["is_error"]
    end

    test "approve resume injects steer candidates after the HITL tool executes" do
      workspace =
        tmp_workspace(%{"tools" => %{"per_tool" => %{"permission_touch_fixture" => "prompt"}}})

      marker = Path.join(workspace, "denied_marker")

      {:ok, queue} =
        Handbean.Agent.CandidateQueue.start_link(
          session_id: "turn-resume-approve-steer",
          owner: self()
        )

      :ok =
        Handbean.Agent.CandidateQueue.enqueue(queue, "steer after approve",
          deliver_as: :steer,
          message_id: "msg-resume-approve-steer"
        )

      config = %Config{
        provider: TouchProvider,
        model: "fake",
        max_turns: 5,
        working_directory: workspace,
        middleware: [Handbean.Agent.Middleware.ToolGuard],
        provider_config: %{}
      }

      interrupted = Turn.run_loop(State.init(config, "touch approved_marker"), [])
      assert interrupted.status == :interrupted

      resumed =
        Turn.resume_after_tool_approval(
          interrupted,
          [
            %{
              "tool_call_id" => "touch_1",
              "tool_name" => "permission_touch_fixture",
              "action" => "approve"
            }
          ],
          candidate_queue: queue,
          on_event: &send(self(), {:resume_event, &1})
        )

      assert resumed.status == :completed
      assert File.exists?(marker)

      assert_receive {:resume_event, {:tool_end, %{tool_use_id: "touch_1", turn_number: 1}}}

      assert_receive {:resume_event,
                      {:candidate_message_injected,
                       %{
                         deliver_as: :steer,
                         count: 1,
                         message_ids: ["msg-resume-approve-steer"]
                       }}}
    end

    test "full deny-approve flow: deny policy interrupts, then resume with deny completes" do
      workspace =
        tmp_workspace(%{"tools" => %{"per_tool" => %{"permission_touch_fixture" => "prompt"}}})

      config = %Config{
        provider: TouchProvider,
        model: "fake",
        max_turns: 5,
        working_directory: workspace,
        middleware: [Handbean.Agent.Middleware.ToolGuard],
        provider_config: %{}
      }

      state = State.init(config, "touch denied_marker")

      # First run: deny policy interrupts
      result = Turn.run_loop(state, [])

      assert result.status == :interrupted
      assert result.interrupt_data.type == :tool_approval
      assert result.interrupt_data.hitl_tool_call_ids == ["touch_1"]

      # Resume: deny the tool call
      resumed =
        Turn.resume_after_tool_approval(
          result,
          [%{"tool_call_id" => "touch_1", "action" => "deny"}],
          on_event: &send(self(), {:deny_resume_event, &1})
        )

      assert resumed.status == :completed
      assert resumed.interrupt_data == nil

      assert_receive {:deny_resume_event,
                      {:tool_end,
                       %{
                         tool_use_id: "touch_1",
                         turn_number: 1,
                         duration_ms: 0,
                         timing_fidelity: "not_started"
                       }}}

      assert_receive {:deny_resume_event,
                      {:turn_end, %{turn: 1, status: :completed, stop_reason: "tool_use_resumed"}}}

      # The denied marker file should NOT exist since we denied the touch call
      refute File.exists?(Path.join(workspace, "denied_marker"))
    end
  end
end
