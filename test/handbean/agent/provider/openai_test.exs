defmodule Handbean.Agent.Provider.OpenAITest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Handbean.Agent.Message
  alias Handbean.Agent.Provider.OpenAI

  setup do
    Req.Test.stub(__MODULE__, nil)
    :ok
  end

  describe "complete/3 with text response" do
    test "returns normalized end_turn response" do
      config =
        config_with_response(%{
          status: 200,
          body:
            Jason.encode!(
              response_payload(
                [assistant_text_item("Hello!")],
                %{
                  "input_tokens" => 10,
                  "output_tokens" => 5,
                  "total_tokens" => 15,
                  "input_tokens_details" => %{"cached_tokens" => 8}
                }
              )
            )
        })

      assert {:ok, result} = OpenAI.complete([Message.user("Hi")], [], config)
      assert result.stop_reason == :end_turn
      assert [%Message{role: :assistant}] = result.messages
      assert Message.text(hd(result.messages)) == "Hello!"
      assert result.usage.input_tokens == 10
      assert result.usage.output_tokens == 5
      assert result.usage.total_input_tokens == 10
      assert result.usage.cache_read_input_tokens == 8
      assert result.usage.cache_creation_input_tokens == 0

      assert result.provider_state == %{
               response_id: "resp_test",
               provider_context: %{
                 provider: "openai",
                 api: "openai_responses",
                 model: "gpt-5.2"
               }
             }
    end

    test "accepts Responses-compatible text content item" do
      config =
        config_with_response(%{
          status: 200,
          body:
            Jason.encode!(
              response_payload([
                %{
                  "id" => "msg_test",
                  "type" => "message",
                  "role" => "assistant",
                  "content" => [%{"type" => "text", "text" => "compat text"}]
                }
              ])
            )
        })

      assert {:ok, result} = OpenAI.complete([Message.user("Hi")], [], config)
      assert result.stop_reason == :end_turn
      assert Message.text(hd(result.messages)) == "compat text"
    end

    test "falls back to top-level output_text when output has no parseable content" do
      config =
        config_with_response(%{
          status: 200,
          body:
            Jason.encode!(
              response_payload([])
              |> Map.put("output_text", "fallback text")
            )
        })

      assert {:ok, result} = OpenAI.complete([Message.user("Hi")], [], config)
      assert result.stop_reason == :end_turn
      assert Message.text(hd(result.messages)) == "fallback text"
    end
  end

  describe "complete/3 with tool calls response" do
    test "returns normalized tool_use response" do
      config =
        config_with_response(%{
          status: 200,
          body:
            Jason.encode!(
              response_payload(
                [
                  function_call_item(
                    "call_abc123",
                    "read",
                    Jason.encode!(%{"file_path" => "mix.exs"})
                  )
                ],
                %{"input_tokens" => 20, "output_tokens" => 15, "total_tokens" => 35}
              )
            )
        })

      assert {:ok, result} =
               OpenAI.complete(
                 [Message.user("Read mix.exs")],
                 [%{name: "read", description: "Read", input_schema: %{}}],
                 config
               )

      assert result.stop_reason == :tool_use

      tool_call = Enum.find(hd(result.messages).content, &(&1.type == "tool_use"))
      assert tool_call.name == "read"
      assert tool_call.id == "call_abc123"
      assert tool_call.input == %{"file_path" => "mix.exs"}
    end
  end

  describe "complete/3 request formatting" do
    test "formats user messages correctly" do
      config = config_that_captures_request()

      OpenAI.complete(
        [Message.user("Hello"), Message.assistant("Hi"), Message.user("How?")],
        [],
        config
      )

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)
      user_msgs = Enum.filter(decoded["input"], &(&1["role"] == "user"))
      assert length(user_msgs) == 2
    end

    test "includes system prompt" do
      config = config_that_captures_request() |> Map.put(:system_prompt, "Helpful")
      OpenAI.complete([Message.user("Hi")], [], config)
      assert_received {:request_body, body}
      decoded = Jason.decode!(body)
      assert hd(decoded["input"])["role"] == "system"
    end

    test "formats tool flow as function_call + function_call_output" do
      config = config_that_captures_request()

      messages = [
        Message.user("Read"),
        Message.assistant_blocks([
          %{type: "tool_use", id: "call_abc", name: "read", input: %{"file_path" => "mix.exs"}}
        ]),
        Message.tool_results([Message.tool_result_block("call_abc", "file contents")])
      ]

      OpenAI.complete(messages, [], config)
      assert_received {:request_body, body}
      decoded = Jason.decode!(body)
      fc = Enum.find(decoded["input"], &(&1["type"] == "function_call"))
      assert fc["call_id"] == "call_abc"
      fco = Enum.find(decoded["input"], &(&1["type"] == "function_call_output"))
      assert fco["output"] == "file contents"
    end

    test "does not send previous_response_id from provider_state by default" do
      config =
        config_that_captures_request()
        |> Map.put(:provider_state, %{response_id: "resp_prev"})

      OpenAI.complete([Message.user("Hi")], [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)
      refute Map.has_key?(decoded, "previous_response_id")
    end

    test "can opt into previous_response_id from matching provider state" do
      config =
        config_that_captures_request()
        |> Map.put(:provider_state, %{
          response_id: "resp_prev",
          provider_context: %{
            provider: "openai",
            api: "openai_responses",
            model: "gpt-5.2"
          }
        })
        |> Map.put(:use_previous_response_id, true)

      OpenAI.complete([Message.user("Hi")], [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)
      assert decoded["previous_response_id"] == "resp_prev"
    end

    test "drops previous_response_id after a provider, API, or model switch" do
      source = %{
        response_id: "resp_prev",
        provider_context: %{
          provider: "openai",
          api: "openai_responses",
          model: "gpt-5.2"
        }
      }

      targets = [
        %{provider_key: "xai"},
        %{api: :openai},
        %{model: "gpt-5.4"}
      ]

      for target <- targets do
        config =
          config_that_captures_request()
          |> Map.put(:provider_state, source)
          |> Map.put(:use_previous_response_id, true)
          |> Map.merge(target)

        OpenAI.complete([Message.user("Hi")], [], config)

        assert_received {:request_body, body}
        refute Map.has_key?(Jason.decode!(body), "previous_response_id")
      end
    end

    test "explicit previous_response_id is still sent" do
      config =
        config_that_captures_request()
        |> Map.put(:provider_state, %{response_id: "resp_prev"})
        |> Map.put(:previous_response_id, "resp_explicit")

      OpenAI.complete([Message.user("Hi")], [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)
      assert decoded["previous_response_id"] == "resp_explicit"
    end

    test "drops previous_response_id after the model context is forked" do
      config =
        config_that_captures_request()
        |> Map.put(:context_generation, 1)
        |> Map.put(:provider_state, %{response_id: "resp_prev", context_generation: 0})
        |> Map.put(:use_previous_response_id, true)
        |> Map.put(:previous_response_id, "resp_explicit")

      OpenAI.complete([Message.user("edited context")], [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)
      refute Map.has_key?(decoded, "previous_response_id")
    end

    test "includes reasoning effort for Responses reasoning models" do
      config =
        config_that_captures_request()
        |> Map.put(:reasoning, %{effort: "medium"})

      OpenAI.complete([Message.user("Hi")], [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)
      assert decoded["reasoning"] == %{"effort" => "medium"}
    end
  end

  describe "complete/3 error handling" do
    test "rejects malformed known output items instead of returning partial success" do
      for item <- [
            %{"type" => "function_call", "call_id" => "call_bad", "arguments" => "{}"},
            function_call_item("call_bad", "", "{}"),
            function_call_item(nil, "read", "{}") |> Map.delete("id"),
            function_call_item("call_bad", "read", "[1,2]"),
            function_call_item("call_bad", "read", ""),
            %{"type" => "message", "role" => "assistant"},
            %{
              "type" => "message",
              "role" => "assistant",
              "content" => [
                %{"type" => "output_text", "text" => 42}
              ]
            }
          ] do
        config =
          config_with_response(%{
            status: 200,
            body: Handbean.JSON.encode!(response_payload([assistant_text_item("partial"), item]))
          })

        assert {:error, reason} = OpenAI.complete([Message.user("Hi")], [], config)
        assert is_binary(reason)
      end
    end

    test "does not accept failed or incomplete response output as success" do
      for status <- ["failed", "incomplete", "in_progress", "cancelled"] do
        body = response_payload([assistant_text_item("partial")]) |> Map.put("status", status)
        config = config_with_response(%{status: 200, body: Handbean.JSON.encode!(body)})
        assert {:error, _reason} = OpenAI.complete([Message.user("Hi")], [], config)
      end
    end

    test "returns error on API error" do
      config =
        config_with_response(%{
          status: 400,
          body:
            Jason.encode!(%{
              "error" => %{"type" => "invalid_request_error", "message" => "bad"}
            })
        })

      assert {:error, reason} = OpenAI.complete([Message.user("Hi")], [], config)
      assert reason =~ "invalid_request_error"
    end
  end

  describe "stream/4" do
    test "requires response.completed even when partial text and valid or invalid tool calls exist" do
      for output <- [
            [function_call_item("call_bad", "read", "not JSON")],
            [],
            [function_call_item("call_ok", "read", "{}")]
          ] do
        events =
          Enum.map(output, fn item ->
            "event: response.output_item.done\ndata: #{Handbean.JSON.encode!(%{"item" => item})}\n\n"
          end)

        config =
          config_with_sse_stream(
            [sse_response_output_text_delta("partial") | events] ++ ["data: [DONE]\n\n"]
          )

        assert {:error, reason} =
                 OpenAI.stream([Message.user("Hi")], [], config, fn _ -> :ok end)

        assert reason in [
                 "OpenAI stream ended without response.completed",
                 "Invalid JSON in tool call arguments: expected an object"
               ]
      end
    end

    test "does not lose malformed JSON events or callback failures before completion" do
      for {event, on_chunk} <- [
            {"event: response.output_text.delta\ndata: not-json\n\n", fn _ -> :ok end},
            {sse_response_output_text_delta("partial"), fn _ -> raise "private callback data" end}
          ] do
        config =
          config_with_sse_stream([
            event,
            sse_response_completed([assistant_text_item("done")], %{})
          ])

        assert {:error, reason} = OpenAI.stream([Message.user("Hi")], [], config, on_chunk)
        refute reason =~ "private callback data"
        assert byte_size(reason) < 200
      end
    end

    test "preserves invalid tool arguments errors in a completed stream" do
      config =
        config_with_sse_stream([
          sse_response_completed([function_call_item("call_bad", "read", "not JSON")], %{})
        ])

      assert {:error, reason} = OpenAI.stream([Message.user("Hi")], [], config, fn _ -> :ok end)
      assert reason =~ "Invalid JSON in tool call arguments"
    end

    test "malformed completed items cannot disappear behind a later completed response" do
      item = %{"type" => "function_call", "call_id" => "bad", "arguments" => "{}"}

      config =
        config_with_sse_stream([
          "event: response.output_item.done\ndata: #{Handbean.JSON.encode!(%{"item" => item})}\n\n",
          sse_response_completed([assistant_text_item("done")], %{})
        ])

      assert {:error, "Malformed OpenAI function_call"} =
               OpenAI.stream([Message.user("Hi")], [], config, fn _ -> :ok end)
    end

    test "emits text chunks and returns correct response" do
      config =
        config_with_sse_stream([
          sse_response_output_text_delta("Hello"),
          sse_response_output_text_delta(" world"),
          sse_response_completed(
            [assistant_text_item("Hello world")],
            %{
              "input_tokens" => 10,
              "output_tokens" => 5,
              "input_tokens_details" => %{"cached_tokens" => 8}
            }
          ),
          "data: [DONE]\n\n"
        ])

      test_pid = self()
      on_chunk = fn chunk -> send(test_pid, {:chunk, chunk}) end
      assert {:ok, result} = OpenAI.stream([Message.user("Hi")], [], config, on_chunk)
      assert result.stop_reason == :end_turn
      assert Message.text(hd(result.messages)) == "Hello world"
      assert result.usage.total_input_tokens == 10
      assert result.usage.cache_read_input_tokens == 8
      assert_received {:chunk, "Hello"}
      assert_received {:chunk, " world"}
    end

    test "uses completed response output_text when SSE deltas are absent" do
      response =
        response_payload([])
        |> Map.put("output_text", "completed fallback")

      config =
        config_with_sse_stream([
          "event: response.completed\ndata: #{Jason.encode!(%{"type" => "response.completed", "response" => response})}\n\n",
          "data: [DONE]\n\n"
        ])

      assert {:ok, result} = OpenAI.stream([Message.user("Hi")], [], config, fn _ -> :ok end)
      assert result.stop_reason == :end_turn
      assert Message.text(hd(result.messages)) == "completed fallback"
    end

    test "keeps sui2api output item when completed response output is empty" do
      item_id = "msg_sui"
      response = response_payload([])

      config =
        config_with_sse_stream([
          sse_response_output_text_delta("OK"),
          "event: response.output_text.done\ndata: #{Jason.encode!(%{"type" => "response.output_text.done", "item_id" => item_id, "text" => "OK"})}\n\n",
          "event: response.content_part.done\ndata: #{Jason.encode!(%{"type" => "response.content_part.done", "item_id" => item_id, "part" => %{"type" => "output_text", "annotations" => [], "text" => "OK"}})}\n\n",
          "event: response.output_item.done\ndata: #{Jason.encode!(%{"type" => "response.output_item.done", "item" => %{"id" => item_id, "type" => "message", "status" => "completed", "content" => [%{"type" => "output_text", "annotations" => [], "text" => "OK"}], "role" => "assistant"}})}\n\n",
          "event: response.completed\ndata: #{Jason.encode!(%{"type" => "response.completed", "response" => response})}\n\n",
          "data: [DONE]\n\n"
        ])

      test_pid = self()
      on_chunk = fn chunk -> send(test_pid, {:chunk, chunk}) end
      assert {:ok, result} = OpenAI.stream([Message.user("Hi")], [], config, on_chunk)
      assert result.stop_reason == :end_turn
      assert Message.text(hd(result.messages)) == "OK"
      assert_received {:chunk, "OK"}
    end

    test "keeps sui2api function calls when completed response output is empty" do
      response = response_payload([])

      config =
        config_with_sse_stream([
          "event: response.output_item.done\ndata: #{Jason.encode!(%{"type" => "response.output_item.done", "item" => function_call_item("call_sui", "read", Jason.encode!(%{"file_path" => "mix.exs"}))})}\n\n",
          "event: response.completed\ndata: #{Jason.encode!(%{"type" => "response.completed", "response" => response})}\n\n",
          "data: [DONE]\n\n"
        ])

      assert {:ok, result} =
               OpenAI.stream([Message.user("Read mix.exs")], [], config, fn _ -> :ok end)

      assert result.stop_reason == :tool_use

      assert [
               %{
                 type: "tool_use",
                 id: "call_sui",
                 name: "read",
                 input: %{"file_path" => "mix.exs"}
               }
             ] = hd(result.messages).content
    end

    test "returns parsed error on non-200 stream" do
      config =
        config_with_sse_error_stream(
          400,
          Jason.encode!(%{
            "error" => %{"type" => "invalid_request_error", "message" => "bad"}
          })
        )

      assert {:error, reason} = OpenAI.stream([Message.user("Hi")], [], config, fn _ -> :ok end)
      assert reason =~ "invalid_request_error"
    end

    test "extracts a bounded retryable error from a nested response.failed event" do
      failed = %{
        "type" => "response.failed",
        "response" => %{
          "error" => %{
            "code" => "server_error",
            "message" => "The model is currently at capacity due to high demand."
          },
          "tools" => List.duplicate(%{"description" => String.duplicate("internal", 1_000)}, 20)
        }
      }

      config =
        config_with_sse_stream([
          "event: response.failed\ndata: #{Jason.encode!(failed)}\n\n",
          "data: [DONE]\n\n"
        ])

      assert {:error, reason} =
               OpenAI.stream([Message.user("Hi")], [], config, fn _ -> :ok end)

      assert reason ==
               "server_error: The model is currently at capacity due to high demand."

      refute reason =~ "tools"
      assert Handbean.Agent.Provider.Retry.retryable?(reason)
    end

    test "cancels a degenerate stream that repeats the same phrase" do
      phrase = "Hex 的版本号在页面源码里，我直接抓那一段。\n"

      config =
        config_with_sse_stream(List.duplicate(sse_response_output_text_delta(phrase), 20))

      test_pid = self()
      on_chunk = fn chunk -> send(test_pid, {:chunk, chunk}) end

      assert {:error, reason} =
               OpenAI.stream([Message.user("Check dependencies")], [], config, on_chunk)

      assert reason =~ "repeated output"

      chunks = collect_chunks([])
      assert length(chunks) < 20
      assert Enum.join(chunks) == String.duplicate(phrase, length(chunks))
    end

    test "does not reject a long run of punctuation or box drawing" do
      chunks = [String.duplicate("─", 64), String.duplicate("=", 128)]

      config =
        config_with_sse_stream(
          Enum.map(chunks, &sse_response_output_text_delta/1) ++
            [
              sse_response_completed([assistant_text_item(Enum.join(chunks))], %{}),
              "data: [DONE]\n\n"
            ]
        )

      assert {:ok, result} =
               OpenAI.stream([Message.user("Draw a rule")], [], config, fn _ -> :ok end)

      assert Message.text(hd(result.messages)) == Enum.join(chunks)
    end

    test "replays encrypted reasoning only for the exact provider API and model" do
      item = %{
        "type" => "reasoning",
        "id" => "rs_test",
        "encrypted_content" => "enc-1",
        "summary" => []
      }

      source = %{
        "provider" => "openai",
        "api" => "openai_responses",
        "model" => "gpt-5.2"
      }

      message =
        Message.assistant_blocks([
          %{"type" => "responses_reasoning", "provider_context" => source, "item" => item},
          %{type: "text", text: "done"}
        ])

      config = %{provider_key: "openai", api: :openai_responses, model: "gpt-5.2"}
      items = OpenAI.build_input_items([message], config)

      assert items == [
               item,
               %{"role" => "assistant", "content" => "done"}
             ]
    end

    test "drops encrypted reasoning after a provider, API, or model switch" do
      item = %{
        "type" => "reasoning",
        "id" => "rs_old",
        "encrypted_content" => "old-secret",
        "summary" => []
      }

      message =
        Message.assistant_blocks([
          %{
            type: "responses_reasoning",
            provider_context: %{
              provider: "openai",
              api: "openai_responses",
              model: "gpt-5.2"
            },
            item: item
          },
          %{type: "text", text: "Prior answer"},
          %{type: "tool_use", id: "call-1", name: "read", input: %{file_path: "README.md"}}
        ])

      targets = [
        %{provider_key: "xai", api: :openai_responses, model: "gpt-5.2"},
        %{provider_key: "openai", api: :openai, model: "gpt-5.2"},
        %{provider_key: "openai", api: :openai_responses, model: "gpt-5.4"}
      ]

      for target <- targets do
        items = OpenAI.build_input_items([message], target)

        refute Enum.any?(items, &(&1["type"] == "reasoning"))
        assert %{"role" => "assistant", "content" => "Prior answer"} in items

        assert %{
                 "type" => "function_call",
                 "call_id" => "call-1",
                 "name" => "read"
               } = Enum.find(items, &(&1["type"] == "function_call"))
      end
    end

    test "does not replay legacy encrypted reasoning without source provenance" do
      message =
        Message.assistant_blocks([
          %{
            type: "responses_reasoning",
            item: %{"type" => "reasoning", "encrypted_content" => "legacy-secret"}
          },
          %{type: "text", text: "Visible history"}
        ])

      items =
        OpenAI.build_input_items(message |> List.wrap(), %{
          provider_key: "xai",
          api: :openai_responses,
          model: "grok-4.6"
        })

      assert items == [%{"role" => "assistant", "content" => "Visible history"}]
    end

    test "keeps encrypted reasoning from a completed stream" do
      reasoning = %{
        "type" => "reasoning",
        "id" => "rs_stream",
        "encrypted_content" => "enc-stream",
        "summary" => []
      }

      config =
        config_with_sse_stream([
          "event: response.output_item.done\ndata: #{Jason.encode!(%{"type" => "response.output_item.done", "item" => reasoning})}\n\n",
          sse_response_output_text_delta("visible"),
          sse_response_completed([reasoning, assistant_text_item("visible")], %{}),
          "data: [DONE]\n\n"
        ])

      assert {:ok, result} =
               OpenAI.stream([Message.user("Think")], [], config, fn _ -> :ok end)

      assert [
               %{
                 type: "responses_reasoning",
                 provider_context: %{
                   provider: "openai",
                   api: "openai_responses",
                   model: "gpt-5.2"
                 },
                 item: ^reasoning
               },
               %{type: "text", text: "visible"}
             ] = hd(result.messages).content
    end

    test "does not reject repeated short formatting tokens" do
      chunks = List.duplicate("- ", 20) ++ ["done"]

      config =
        config_with_sse_stream(
          Enum.map(chunks, &sse_response_output_text_delta/1) ++
            [
              sse_response_completed([assistant_text_item(Enum.join(chunks))], %{}),
              "data: [DONE]\n\n"
            ]
        )

      assert {:ok, result} =
               OpenAI.stream([Message.user("Format a list")], [], config, fn _ -> :ok end)

      assert Message.text(hd(result.messages)) == Enum.join(chunks)
    end

    test "does not reject a normal continuation after the observed Chinese prefix" do
      chunks = [
        "我继续把会话重命名接上：先定位侧边栏列表、标题存储和现有归档交互，再按同样的方式补改",
        "。接下来读取相关模块，确认状态更新路径。"
      ]

      config =
        config_with_sse_stream(
          Enum.map(chunks, &sse_response_output_text_delta/1) ++
            [
              sse_response_completed([assistant_text_item(Enum.join(chunks))], %{}),
              "data: [DONE]\n\n"
            ]
        )

      assert {:ok, result} =
               OpenAI.stream([Message.user("继续")], [], config, fn _ -> :ok end)

      assert Message.text(hd(result.messages)) == Enum.join(chunks)
    end

    test "logs bounded loop diagnostics when repetition follows normal output" do
      prefix =
        "我继续把会话重命名接上：先定位侧边栏列表、标题存储和现有归档交互，再按同样的方式补改"

      loop = "然后读取相关文件。"

      config =
        config_with_sse_stream([
          sse_response_output_text_delta(prefix),
          sse_response_output_text_delta(String.duplicate(loop, 12))
        ])

      log =
        capture_log(fn ->
          assert {:error, reason} =
                   OpenAI.stream([Message.user("继续")], [], config, fn _ -> :ok end)

          assert reason =~ "repeated output"
        end)

      assert log =~ "repeated stream output detected"
      assert log =~ "period_bytes=#{byte_size(loop)}"
      assert log =~ "repeated_bytes=#{byte_size(loop) * 8}"
      refute log =~ String.duplicate(loop, 8)
    end
  end

  describe "HTTP timeouts" do
    defmodule CaptureTimeoutReq do
      def request(opts) do
        Process.put(:openai_last_receive_timeout, opts[:receive_timeout])
        connect = opts[:connect_options]
        Process.put(:openai_last_connect_timeout, connect[:timeout])

        {:ok,
         %{
           status: 200,
           body:
             Jason.encode!(%{
               "id" => "resp_test",
               "object" => "response",
               "status" => "completed",
               "output" => [
                 %{
                   "id" => "msg_test",
                   "type" => "message",
                   "role" => "assistant",
                   "content" => [%{"type" => "output_text", "text" => "ok"}]
                 }
               ],
               "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
             })
         }}
      end
    end

    test "uses a long receive timeout by default so streamed reasoning can pause" do
      config = %{
        api_key: "sk-test",
        model: "grok-4.6",
        req_module: CaptureTimeoutReq
      }

      assert {:ok, _} = OpenAI.complete([Message.user("hi")], [], config)
      assert Process.get(:openai_last_receive_timeout) == 180_000
      assert Process.get(:openai_last_connect_timeout) == 30_000
    end

    test "allows overriding receive and connect timeouts" do
      config = %{
        api_key: "sk-test",
        model: "grok-4.6",
        req_module: CaptureTimeoutReq,
        receive_timeout: 120_000,
        connect_timeout: 45_000
      }

      assert {:ok, _} = OpenAI.complete([Message.user("hi")], [], config)
      assert Process.get(:openai_last_receive_timeout) == 120_000
      assert Process.get(:openai_last_connect_timeout) == 45_000
    end

    test "req_options override default timeouts" do
      config = %{
        api_key: "sk-test",
        model: "grok-4.6",
        req_module: CaptureTimeoutReq,
        req_options: [receive_timeout: 240_000, connect_options: [timeout: 60_000]]
      }

      assert {:ok, _} = OpenAI.complete([Message.user("hi")], [], config)
      assert Process.get(:openai_last_receive_timeout) == 240_000
      assert Process.get(:openai_last_connect_timeout) == 60_000
    end
  end

  # --- Helpers ---

  defp response_payload(output, usage \\ %{}) do
    base = %{
      "id" => "resp_test",
      "object" => "response",
      "status" => "completed",
      "output" => output
    }

    if usage == %{}, do: base, else: Map.put(base, "usage", usage)
  end

  defp assistant_text_item(text) do
    %{
      "id" => "msg_test",
      "type" => "message",
      "role" => "assistant",
      "content" => [%{"type" => "output_text", "text" => text}]
    }
  end

  defp function_call_item(call_id, name, arguments) do
    %{
      "id" => "fc_test",
      "type" => "function_call",
      "call_id" => call_id,
      "name" => name,
      "arguments" => arguments
    }
  end

  defp sse_response_output_text_delta(text) do
    "event: response.output_text.delta\ndata: #{Jason.encode!(%{"type" => "response.output_text.delta", "delta" => text})}\n\n"
  end

  defp sse_response_completed(output_items, usage) do
    "event: response.completed\ndata: #{Jason.encode!(%{"type" => "response.completed", "response" => response_payload(output_items, usage)})}\n\n"
  end

  defp config_with_response(response) do
    %{
      api_key: "sk-test-key",
      provider_key: "openai",
      api: :openai_responses,
      model: "gpt-5.2",
      max_tokens: 4096,
      req_options: [plug: {Req.Test, __MODULE__}, retry: false]
    }
    |> tap(fn _ ->
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, response.status, response.body)
      end)
    end)
  end

  defp config_that_captures_request do
    test_pid = self()

    %{
      api_key: "sk-test-key",
      provider_key: "openai",
      api: :openai_responses,
      model: "gpt-5.2",
      max_tokens: 4096,
      req_options: [plug: {Req.Test, __MODULE__}, retry: false]
    }
    |> tap(fn _ ->
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, body})

        Plug.Conn.send_resp(
          conn,
          200,
          Jason.encode!(response_payload([assistant_text_item("ok")]))
        )
      end)
    end)
  end

  defp config_with_sse_stream(chunks) do
    %{
      api_key: "sk-test-key",
      provider_key: "openai",
      api: :openai_responses,
      model: "gpt-5.2",
      max_tokens: 4096,
      req_options: [plug: {Req.Test, __MODULE__}, retry: false]
    }
    |> tap(fn _ -> Req.Test.stub(__MODULE__, sse_chunks_plug(chunks)) end)
  end

  defp config_with_sse_error_stream(status, body) do
    %{
      api_key: "sk-test-key",
      provider_key: "openai",
      api: :openai_responses,
      model: "gpt-5.2",
      max_tokens: 4096,
      req_options: [plug: {Req.Test, __MODULE__}, retry: false]
    }
    |> tap(fn _ -> Req.Test.stub(__MODULE__, sse_error_plug(status, body)) end)
  end

  defp sse_chunks_plug(chunks) do
    fn conn ->
      conn = Plug.Conn.send_chunked(conn, 200)

      Enum.reduce(chunks, conn, fn chunk, conn ->
        {:ok, conn} = Plug.Conn.chunk(conn, chunk)
        conn
      end)
    end
  end

  defp sse_error_plug(status, body) do
    fn conn ->
      conn = Plug.Conn.send_chunked(conn, status)
      {:ok, conn} = Plug.Conn.chunk(conn, body)
      conn
    end
  end

  describe "openai usage cache writes" do
    # Parser contract:
    # - Responses: input_tokens_details.cache_write_tokens
    # - Chat Completions: prompt_tokens_details.cache_write_tokens
    # - input_tokens already includes reads and writes; do not add the write again
    # - an explicit 0 is kept; a missing field stays 0
    test "keeps GPT-5.6 cache writes without changing the inclusive input total" do
      responses =
        Handbean.Agent.Provider.openai_usage(%{
          "input_tokens" => 2600,
          "output_tokens" => 10,
          "input_tokens_details" => %{"cached_tokens" => 2000, "cache_write_tokens" => 400}
        })

      chat =
        Handbean.Agent.Provider.openai_usage(%{
          "prompt_tokens" => 2600,
          "completion_tokens" => 10,
          "prompt_tokens_details" => %{"cached_tokens" => 2000, "cache_write_tokens" => 400}
        })

      for usage <- [responses, chat] do
        assert usage.input_tokens == 2600
        assert usage.total_input_tokens == 2600
        assert usage.cache_read_input_tokens == 2000
        assert usage.cache_creation_input_tokens == 400
      end

      explicit_zero =
        Handbean.Agent.Provider.openai_usage(%{
          "input_tokens" => 10,
          "input_tokens_details" => %{"cached_tokens" => 0, "cache_write_tokens" => 0},
          "cache_creation_input_tokens" => 99
        })

      assert explicit_zero.cache_creation_input_tokens == 0

      missing =
        Handbean.Agent.Provider.openai_usage(%{
          "input_tokens" => 10,
          "input_tokens_details" => %{"cached_tokens" => 4}
        })

      assert missing.cache_creation_input_tokens == 0
    end
  end

  defp collect_chunks(chunks) do
    receive do
      {:chunk, chunk} -> collect_chunks([chunk | chunks])
    after
      0 -> Enum.reverse(chunks)
    end
  end
end
