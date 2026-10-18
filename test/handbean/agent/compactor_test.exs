defmodule Handbean.Agent.CompactorTest do
  use ExUnit.Case, async: true

  alias Handbean.Agent.{Compactor, Config, Message, ModelContext, State}

  defmodule ProbeProvider do
    @behaviour Handbean.Agent.Provider

    @impl Handbean.Agent.Provider
    def complete(
          messages,
          tool_defs,
          %{summary_response: summary_response, test_pid: test_pid} = config
        ) do
      send(test_pid, {:summary_request, messages, tool_defs, config})

      case summary_response do
        {:ok, text} when is_binary(text) ->
          {:ok,
           %{
             stop_reason: :end_turn,
             messages: [Message.assistant(text)],
             usage: %{input_tokens: 5, output_tokens: 8},
             response_metadata: %{id: "summary-msg-001", model: "probe-model"}
           }}

        :tool_call ->
          {:ok,
           %{
             stop_reason: :tool_use,
             messages: [
               Message.assistant_blocks([
                 %{type: "tool_use", id: "t", name: "read", input: %{}}
               ])
             ],
             usage: %{input_tokens: 5, output_tokens: 1}
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end

    @impl Handbean.Agent.Provider
    def stream(messages, tool_defs, config, _on_chunk), do: complete(messages, tool_defs, config)
  end

  defp build_state(messages, opts) do
    provider = Keyword.get(opts, :provider, ProbeProvider)
    provider_config = Keyword.get(opts, :provider_config, %{})
    max_tokens = Keyword.get(opts, :max_tokens, 200)
    compaction = Keyword.get(opts, :compaction, reserve_tokens: 20, keep_recent_tokens: 20)
    on_compaction = Keyword.get(opts, :on_compaction)
    on_compaction_complete = Keyword.get(opts, :on_compaction_complete)

    config =
      Config.from_opts(
        provider: provider,
        provider_config: provider_config,
        max_tokens: max_tokens,
        compaction: compaction,
        on_compaction: on_compaction,
        on_compaction_complete: on_compaction_complete
      )

    %State{config: config, messages: messages}
  end

  defp summary_text(label) do
    """
    ## Goal
    #{label} goal

    ## Constraints & Preferences
    - keep exact paths

    ## Progress
    ### Done
    - [x] #{label} done

    ### In Progress
    - [ ] #{label} in progress

    ### Blocked
    - (none)

    ## Key Decisions
    - **#{label} decision**: preserve evidence

    ## Evidence & References
    - /tmp/#{String.downcase(label)}.ex

    ## Next Steps
    1. Continue #{String.downcase(label)}

    ## Critical Context
    - #{label} context
    """
  end

  defp summary_message?(%Message{content: content}) when is_binary(content) do
    String.starts_with?(content, Compactor.summary_prefix())
  end

  defp summary_message?(_message), do: false

  defp tool_result_message?(%Message{role: :tool_result}), do: true

  defp tool_result_message?(%Message{role: :user, content: blocks}) when is_list(blocks) do
    Enum.any?(blocks, fn
      %{type: type} when type in ["tool_result", "server_tool_result"] -> true
      _ -> false
    end)
  end

  defp tool_result_message?(_message), do: false

  defp assistant_tool_call_message?(%Message{role: :assistant, content: blocks})
       when is_list(blocks) do
    Enum.any?(blocks, fn
      %{type: type} when type in ["tool_use", "server_tool_use"] -> true
      _ -> false
    end)
  end

  defp assistant_tool_call_message?(_message), do: false

  defp tool_pairs_intact?(messages) do
    Enum.with_index(messages)
    |> Enum.all?(fn
      {%Message{} = message, index} when index > 0 ->
        if tool_result_message?(message) do
          assistant_tool_call_message?(Enum.at(messages, index - 1))
        else
          true
        end

      {%Message{} = message, 0} ->
        not tool_result_message?(message)
    end)
  end

  test "counts encrypted reasoning once in request estimates" do
    blocks = [
      %{
        type: "responses_reasoning",
        item: %{
          type: "reasoning",
          id: "rs_estimate",
          encrypted_content: String.duplicate("cipher", 2_000)
        }
      },
      %{type: "text", text: "visible"}
    ]

    expected = max(1, div(byte_size(Handbean.JSON.encode!(blocks)), 4))

    assert Compactor.request_tokens([Message.assistant_blocks(blocks)], nil) == expected
  end

  describe "maybe_compact/1" do
    test "returns state unchanged when within reserve budget" do
      messages = [Message.user("hello"), Message.assistant("hi")]

      state =
        build_state(messages,
          max_tokens: 200,
          compaction: [reserve_tokens: 20, keep_recent_tokens: 20],
          provider_config: %{summary_response: {:ok, summary_text("unused")}, test_pid: self()}
        )

      assert {:unchanged, ^state} = Compactor.maybe_compact(state)
      refute_received {:summary_request, _, _, _}
    end

    test "invokes the provider summarizer and stores a synthetic summary message" do
      messages = [
        Message.user("original request"),
        Message.assistant(String.duplicate("a", 900)),
        Message.user("middle question"),
        Message.assistant("recent reply"),
        Message.user("latest")
      ]

      state =
        build_state(messages,
          max_tokens: 250,
          compaction: [reserve_tokens: 25, keep_recent_tokens: 20],
          provider_config: %{summary_response: {:ok, summary_text("Alpha")}, test_pid: self()}
        )

      {:compacted, compacted} = Compactor.maybe_compact(state)

      assert_received {:summary_request, request_messages, [], config}
      assert [%Message{role: :user, content: prompt}] = request_messages
      assert prompt =~ String.duplicate("a", 900)
      refute prompt =~ "original request"
      refute prompt =~ "latest"
      refute config.system_prompt == state.config.system_prompt
      refute Map.has_key?(config, :cache_fork)
      assert prompt =~ "<conversation>"
      assert prompt =~ "## Goal"

      assert hd(compacted.messages).content == "original request"
      assert Enum.at(compacted.messages, 1).role == :user
      assert summary_message?(Enum.at(compacted.messages, 1))
      assert Enum.at(compacted.messages, 1).content =~ "Alpha goal"
      assert Compactor.request_tokens(compacted.messages, nil) < state.config.max_tokens
    end

    test "removes parent tool definitions and ignores a summary that calls tools" do
      messages = [
        Message.user("original request"),
        Message.assistant(String.duplicate("a", 900)),
        Message.user("latest")
      ]

      tool_defs = [%{name: "read", description: "Read", input_schema: %{}}]

      state =
        build_state(messages,
          max_tokens: 250,
          compaction: [reserve_tokens: 25, keep_recent_tokens: 20],
          provider_config: %{summary_response: :tool_call, test_pid: self()}
        )

      {:compacted, compacted} = Compactor.maybe_compact(state, tool_defs: tool_defs)

      assert_received {:summary_request, request_messages, [], config}
      refute config.system_prompt == state.config.system_prompt
      refute Enum.any?(request_messages, &(&1.content == "original request"))
      refute Enum.any?(compacted.messages, &summary_message?/1)
    end

    test "isolates and sanitizes the history sent to the summarizer" do
      encrypted = String.duplicate("cipher", 2_000)
      tool_output = "tool-prefix-" <> String.duplicate("x", 3_000) <> "-tool-tail"

      old_reasoning = %{
        type: "responses_reasoning",
        item: %{type: "reasoning", encrypted_content: encrypted}
      }

      old_thinking = %{
        type: "thinking",
        thinking: "private-anthropic-reasoning",
        signature: "sig-private"
      }

      recent_reasoning = %{
        type: "responses_reasoning",
        item: %{type: "reasoning", encrypted_content: "recent-cipher"}
      }

      messages = [
        Message.user("original request"),
        Message.assistant_blocks([
          old_reasoning,
          old_thinking,
          %{type: "image", data: "old-image"},
          %{type: "tool_use", id: "old", name: "read", input: %{path: "large.txt"}}
        ]),
        Message.tool_results([
          %{type: "tool_result", tool_use_id: "old", content: tool_output, images: ["image"]}
        ]),
        Message.user(String.duplicate("boundary", 500)),
        Message.assistant_blocks([recent_reasoning, %{type: "text", text: "recent"}]),
        Message.user("latest")
      ]

      state =
        build_state(messages,
          max_tokens: 2_000,
          compaction: [reserve_tokens: 100, keep_recent_tokens: 1_500],
          provider_config: %{
            "reasoning_effort" => "high",
            summary_response: {:ok, summary_text("Sanitized")},
            test_pid: self(),
            cache_fork: true,
            previous_response_id: "parent-response",
            use_previous_response_id: true,
            max_tokens: 777,
            extended_thinking: [budget_tokens: 5_000],
            thinking: %{type: "adaptive"},
            output_config: %{effort: "high"},
            reasoning: %{effort: "high"}
          }
        )

      {:compacted, compacted} = Compactor.maybe_compact(state)

      assert_received {:summary_request, request_messages, [], config}
      assert [%Message{role: :user, content: prompt}] = request_messages
      refute prompt =~ encrypted
      refute prompt =~ "private-anthropic-reasoning"
      refute prompt =~ "old-image"
      refute prompt =~ "-tool-tail"
      assert prompt =~ "[Assistant tool call] read("
      assert prompt =~ "[Tool result]\ntool-prefix-"
      assert prompt =~ "[truncated for compaction]"
      refute Map.has_key?(config, :cache_fork)
      refute Map.has_key?(config, :previous_response_id)
      refute config.use_previous_response_id
      assert config.max_tokens == 777

      for key <- [
            :extended_thinking,
            :thinking,
            :output_config,
            :reasoning,
            "reasoning_effort"
          ] do
        refute Map.has_key?(config, key)
      end

      assert Enum.any?(compacted.messages, &(&1 == Enum.at(messages, 4)))
      assert Compactor.request_tokens(compacted.messages, nil) < state.config.max_tokens
    end

    test "truncates large write and edit arguments and fallback blocks in the summary prompt" do
      write_content = "write-prefix-" <> String.duplicate("w", 3_000) <> "-write-tail"
      edit_content = "edit-prefix-" <> String.duplicate("e", 3_000) <> "-edit-tail"
      fallback_content = "fallback-prefix-" <> String.duplicate("f", 3_000) <> "-fallback-tail"

      messages = [
        Message.user("original request"),
        Message.assistant_blocks([
          %{
            type: "tool_use",
            id: "write-call",
            name: "write",
            input: %{file_path: "large.txt", content: write_content}
          },
          %{
            type: "tool_use",
            id: "edit-call",
            name: "edit",
            input: %{file_path: "large.txt", old_text: "old", new_text: edit_content}
          },
          %{type: "custom_payload", payload: fallback_content}
        ]),
        Message.tool_results([
          %{type: "tool_result", tool_use_id: "write-call", content: "wrote file"},
          %{type: "tool_result", tool_use_id: "edit-call", content: "edited file"}
        ]),
        Message.user(String.duplicate("boundary", 500)),
        Message.assistant("recent"),
        Message.user("latest")
      ]

      state =
        build_state(messages,
          max_tokens: 3_000,
          compaction: [reserve_tokens: 100, keep_recent_tokens: 1_500],
          provider_config: %{
            summary_response: {:ok, summary_text("Tool arguments")},
            test_pid: self()
          }
        )

      {:compacted, _} = Compactor.maybe_compact(state)

      assert_received {:summary_request, [%Message{content: prompt}], [], _config}
      assert prompt =~ "[Assistant tool call] write("
      assert prompt =~ "write-prefix-"
      refute prompt =~ "-write-tail"
      assert prompt =~ "[Assistant tool call] edit("
      assert prompt =~ "edit-prefix-"
      refute prompt =~ "-edit-tail"
      assert prompt =~ "[Assistant block custom_payload]"
      assert prompt =~ "fallback-prefix-"
      refute prompt =~ "-fallback-tail"
      assert prompt =~ "[truncated for compaction]"
      assert String.length(prompt) < 10_000
    end

    test "preserves recent messages intact based on the keep_recent_tokens budget" do
      messages = [
        Message.user("original"),
        Message.assistant(String.duplicate("a", 800)),
        Message.user(String.duplicate("b", 400)),
        Message.assistant("recent 1"),
        Message.user("recent 2"),
        Message.assistant("recent 3"),
        Message.user("recent 4"),
        Message.assistant("recent 5")
      ]

      state =
        build_state(messages,
          max_tokens: 260,
          compaction: [reserve_tokens: 25, keep_recent_tokens: 50],
          provider_config: %{summary_response: {:ok, summary_text("Recent")}, test_pid: self()}
        )

      {:compacted, compacted} = Compactor.maybe_compact(state)

      assert Enum.take(compacted.messages, -5) == Enum.take(messages, -5)
    end

    test "updates the existing summary instead of duplicating it" do
      initial_messages = [
        Message.user("original"),
        Message.assistant(String.duplicate("a", 900)),
        Message.user("recent")
      ]

      first_state =
        build_state(initial_messages,
          max_tokens: 180,
          compaction: [reserve_tokens: 20, keep_recent_tokens: 20],
          provider_config: %{summary_response: {:ok, summary_text("First")}, test_pid: self()}
        )

      {:compacted, first_compaction} = Compactor.maybe_compact(first_state)

      second_state = %{
        first_compaction
        | config: %{
            first_compaction.config
            | provider_config: %{
                summary_response: {:ok, summary_text("Updated")},
                test_pid: self()
              }
          },
          messages:
            first_compaction.messages ++
              [Message.assistant(String.duplicate("b", 900)), Message.user("new latest")]
      }

      {:compacted, second_compaction} = Compactor.maybe_compact(second_state)

      summary_messages = Enum.filter(second_compaction.messages, &summary_message?/1)

      assert length(summary_messages) == 1
      assert hd(summary_messages).content =~ "Updated goal"
      refute hd(summary_messages).content =~ "First goal"
    end

    test "never leaves a kept tool result without its assistant tool call" do
      big_result = String.duplicate("r", 900)

      messages = [
        Message.user("original"),
        Message.user("inspect the file"),
        Message.assistant_blocks([
          %{type: "tool_use", id: "t1", name: "read_file", input: %{path: "lib/foo.ex"}}
        ]),
        Message.tool_results([
          %{type: "tool_result", tool_use_id: "t1", content: big_result}
        ]),
        Message.assistant("analysis after tool"),
        Message.assistant("latest note")
      ]

      state =
        build_state(messages,
          max_tokens: 260,
          compaction: [reserve_tokens: 20, keep_recent_tokens: 5],
          provider_config: %{summary_response: {:ok, summary_text("Tool")}, test_pid: self()}
        )

      {:compacted, compacted} = Compactor.maybe_compact(state)

      assert tool_pairs_intact?(Enum.drop(compacted.messages, 2))
      refute tool_result_message?(Enum.at(compacted.messages, 2))
    end

    test "can compact a large single turn by keeping an assistant suffix verbatim" do
      messages = [
        Message.user("original"),
        Message.user("one big turn"),
        Message.assistant(String.duplicate("a", 900)),
        Message.assistant(String.duplicate("b", 900)),
        Message.assistant("tail that should stay verbatim")
      ]

      state =
        build_state(messages,
          max_tokens: 300,
          compaction: [reserve_tokens: 20, keep_recent_tokens: 20],
          provider_config: %{summary_response: {:ok, summary_text("Split")}, test_pid: self()}
        )

      {:compacted, compacted} = Compactor.maybe_compact(state)

      assert summary_message?(Enum.at(compacted.messages, 1))
      assert Enum.at(compacted.messages, 2) == Enum.at(messages, 3)
      assert Enum.at(compacted.messages, 3) == Enum.at(messages, 4)
    end

    test "falls back to truncation when summary generation fails" do
      long_text = String.duplicate("a", 5_000)
      encrypted = String.duplicate("encrypted", 2_000)
      tool_output = String.duplicate("tool-result", 1_000)

      old_blocks = [
        %{
          type: "responses_reasoning",
          item: %{type: "reasoning", encrypted_content: encrypted}
        },
        %{type: "tool_result", tool_use_id: "old", content: tool_output, images: ["image"]}
      ]

      recent_reasoning = %{
        type: "responses_reasoning",
        item: %{type: "reasoning", encrypted_content: "recent-encrypted"}
      }

      messages = [
        Message.user("original"),
        Message.assistant_blocks(old_blocks),
        Message.assistant(long_text),
        Message.assistant_blocks([recent_reasoning, %{type: "text", text: "recent"}]),
        Message.user("latest")
      ]

      state =
        build_state(messages,
          max_tokens: 4_000,
          compaction: [reserve_tokens: 20, keep_recent_tokens: 20],
          provider_config: %{summary_response: {:error, :boom}, test_pid: self()}
        )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:compacted, compacted} = Compactor.maybe_compact(state)
          compacted_msg = Enum.at(compacted.messages, 1)
          serialized = inspect(compacted_msg, limit: :infinity, printable_limit: :infinity)
          refute serialized =~ encrypted
          refute serialized =~ "image"
          assert serialized =~ "[truncated for compaction]"
          assert String.length(hd(compacted_msg.content).content) <= 2_030
          assert Enum.at(compacted.messages, 3) == Enum.at(messages, 3)
          refute Enum.any?(compacted.messages, &summary_message?/1)
          assert Compactor.request_tokens(compacted.messages, nil) < state.config.max_tokens
        end)

      assert log =~ "summary compaction failed, falling back to truncation"
    end

    test "compacts when cached input fills the window" do
      messages = [
        Message.user("original"),
        Message.assistant("notes " <> String.duplicate("x", 80)),
        Message.user("current request")
      ]

      state =
        build_state(messages,
          max_tokens: 200_000,
          compaction: [reserve_tokens: 16_384, keep_recent_tokens: 20],
          provider_config: %{summary_response: {:ok, summary_text("Cache")}, test_pid: self()}
        )

      usage = %{
        input_tokens: 1_000,
        cache_read_input_tokens: 180_000,
        cache_creation_input_tokens: 9_000
      }

      anchored = ModelContext.note_anchor(state, usage, length(messages))
      assert anchored.usage_anchor.input_tokens == 190_000

      assert {:unchanged, _} =
               Compactor.maybe_compact(state, usage_anchor: %{input_tokens: 1_000, sent_count: 3})

      refute_received {:summary_request, _, _, _}

      assert {:compacted, compacted} =
               Compactor.maybe_compact(anchored, usage_anchor: anchored.usage_anchor)

      assert_received {:summary_request, _, _, _}
      assert Enum.any?(compacted.messages, &summary_message?/1)
      assert List.last(compacted.messages).content == "current request"
    end

    test "uses the selected model context window for the compaction threshold" do
      messages = [
        Message.user("original"),
        Message.assistant("notes " <> String.duplicate("x", 80)),
        Message.user("current request")
      ]

      config =
        Config.from_opts(
          provider: ProbeProvider,
          provider_config: %{
            model_meta: %{"contextWindow" => 272_000},
            summary_response: {:ok, summary_text("Window")},
            test_pid: self()
          },
          compaction: [reserve_tokens: 16_384, keep_recent_tokens: 20]
        )

      state = %State{config: config, messages: messages}

      assert {:unchanged, _} =
               Compactor.maybe_compact(state,
                 usage_anchor: %{input_tokens: 200_000, sent_count: length(messages)}
               )

      refute_received {:summary_request, _, _, _}

      assert {:compacted, _} =
               Compactor.maybe_compact(state,
                 usage_anchor: %{input_tokens: 255_617, sent_count: length(messages)}
               )

      assert_received {:summary_request, _, _, _}
    end
  end

  describe "on_compaction callback" do
    test "successful summary receives a checkpoint id after entry-aligned provenance" do
      parent = self()

      callback = fn event, _state ->
        send(parent, {:compaction_complete, event})
        {:ok, %{"id" => "checkpoint-1"}}
      end

      shared = "tool-entry-1"

      messages = [
        %{Message.user("original") | id: "user-1"},
        %{Message.assistant(String.duplicate("old", 500)) | id: "assistant-1"},
        %{
          Message.tool_use([%{type: "tool_use", id: "call-1", name: "read", input: %{}}])
          | id: shared
        },
        %{
          Message.tool_results([
            Message.tool_result_block("call-1", String.duplicate("result", 300))
          ])
          | id: shared
        },
        %{Message.user("latest") | id: "user-2"}
      ]

      state =
        build_state(messages,
          max_tokens: 250,
          compaction: [reserve_tokens: 20, keep_recent_tokens: 20],
          provider_config: %{summary_response: {:ok, summary_text("Complete")}, test_pid: self()},
          on_compaction_complete: callback
        )

      assert {:compacted, compacted} = Compactor.maybe_compact(state)
      assert_received {:compaction_complete, event}

      summarized_ids = Enum.map(event.messages_to_summarize, & &1.id)
      recent_ids = compacted.messages |> Enum.drop(2) |> Enum.map(& &1.id)
      assert Enum.count(summarized_ids, &(&1 == shared)) in [0, 2]
      assert Enum.count(recent_ids, &(&1 == shared)) in [0, 2]
      assert Enum.at(compacted.messages, 1).id == "checkpoint-1"
    end

    test "failed summary does not fire completion callback" do
      callback = fn _event, _state -> send(self(), :should_not_complete) end

      state =
        build_state(
          [
            Message.user("original"),
            Message.assistant(String.duplicate("x", 1_200)),
            Message.user("latest")
          ],
          max_tokens: 250,
          compaction: [reserve_tokens: 20, keep_recent_tokens: 20],
          provider_config: %{summary_response: {:error, :offline}, test_pid: self()},
          on_compaction_complete: callback
        )

      assert {:compacted, _compacted} = Compactor.maybe_compact(state)
      refute_received :should_not_complete
    end

    test "fires callback with messages about to be summarized" do
      test_pid = self()

      callback = fn middle_messages, state ->
        send(test_pid, {:compaction_fired, middle_messages, state})
        :ok
      end

      messages = [
        Message.user("original request"),
        Message.assistant(String.duplicate("x", 1200)),
        Message.user("middle question"),
        Message.assistant("middle answer"),
        Message.assistant("recent reply"),
        Message.user("latest")
      ]

      state =
        build_state(messages,
          max_tokens: 250,
          compaction: [reserve_tokens: 20, keep_recent_tokens: 20],
          provider_config: %{summary_response: {:ok, summary_text("Callback")}, test_pid: self()},
          on_compaction: callback
        )

      {:compacted, _compacted} = Compactor.maybe_compact(state)

      assert_received {:compaction_fired, middle_messages, received_state}
      assert middle_messages != []
      assert %State{} = received_state
    end

    test "does not fire callback when within budget" do
      test_pid = self()

      callback = fn _middle, _state ->
        send(test_pid, :should_not_fire)
        :ok
      end

      messages = [Message.user("hi"), Message.assistant("hello")]

      state =
        build_state(messages,
          max_tokens: 200,
          compaction: [reserve_tokens: 20, keep_recent_tokens: 20],
          provider_config: %{summary_response: {:ok, summary_text("unused")}, test_pid: self()},
          on_compaction: callback
        )

      {:unchanged, _result} = Compactor.maybe_compact(state)

      refute_received :should_not_fire
    end

    test "compaction proceeds even when on_compaction crashes" do
      callback = fn _middle, _state ->
        raise "Boom! Callback crashed!"
      end

      messages = [
        Message.user("original"),
        Message.assistant(String.duplicate("x", 1200)),
        Message.user("middle"),
        Message.assistant("recent"),
        Message.user("latest")
      ]

      state =
        build_state(messages,
          max_tokens: 250,
          compaction: [reserve_tokens: 20, keep_recent_tokens: 20],
          provider_config: %{summary_response: {:ok, summary_text("Crash")}, test_pid: self()},
          on_compaction: callback
        )

      {:compacted, compacted} = Compactor.maybe_compact(state)
      assert %State{} = compacted
      assert Enum.any?(compacted.messages, &summary_message?/1)
    end

    test "keeps a current user message when that message is the tail boundary" do
      request = "EXACT-REQUEST " <> String.duplicate("q", 4_000)

      messages = [
        Message.user("original"),
        Message.user(request)
      ]

      state =
        build_state(messages,
          max_tokens: 200,
          compaction: [reserve_tokens: 20, keep_recent_tokens: 20],
          provider_config: %{summary_response: {:ok, summary_text("Request")}, test_pid: self()}
        )

      {:compacted, compacted} = Compactor.maybe_compact(state)

      refute_received {:summary_request, _, _, _}
      assert Enum.at(compacted.messages, 1).content == request
    end

    test "summarizes an oversized tool result that sits after the only assistant boundary" do
      body = String.duplicate("r", 4_000)

      messages = [
        Message.user("read big.txt"),
        Message.assistant_blocks([
          %{type: "tool_use", id: "t1", name: "read", input: %{}}
        ]),
        Message.tool_results([%{type: "tool_result", tool_use_id: "t1", content: body}])
      ]

      state =
        build_state(messages,
          max_tokens: 200,
          compaction: [reserve_tokens: 20, keep_recent_tokens: 20],
          provider_config: %{summary_response: {:ok, summary_text("Result")}, test_pid: self()}
        )

      {:compacted, compacted} = Compactor.maybe_compact(state)

      assert_received {:summary_request, _, _, _}
      assert hd(compacted.messages).content == "read big.txt"
      assert summary_message?(Enum.at(compacted.messages, 1))

      refute Enum.any?(compacted.messages, fn
               %Message{content: content} when is_binary(content) ->
                 String.contains?(content, body)

               %Message{content: blocks} when is_list(blocks) ->
                 Enum.any?(blocks, &(is_map(&1) and String.contains?(&1[:content] || "", body)))

               _ ->
                 false
             end)
    end

    test "summarizes a tail that is only an oversized tool result" do
      body = String.duplicate("r", 4_000)

      messages = [
        Message.user("original"),
        Message.tool_results([%{type: "tool_result", tool_use_id: "t1", content: body}])
      ]

      state =
        build_state(messages,
          max_tokens: 200,
          compaction: [reserve_tokens: 20, keep_recent_tokens: 20],
          provider_config: %{summary_response: {:ok, summary_text("Overflow")}, test_pid: self()}
        )

      {:compacted, compacted} = Compactor.maybe_compact(state)

      assert_received {:summary_request, _, _, _}
      assert summary_message?(Enum.at(compacted.messages, 1))

      refute Enum.any?(compacted.messages, fn
               %Message{content: content} when is_binary(content) ->
                 String.contains?(content, body)

               %Message{content: blocks} when is_list(blocks) ->
                 Enum.any?(blocks, &(is_map(&1) and String.contains?(&1[:content] || "", body)))

               _ ->
                 false
             end)
    end
  end
end
