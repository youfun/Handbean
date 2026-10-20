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
end
