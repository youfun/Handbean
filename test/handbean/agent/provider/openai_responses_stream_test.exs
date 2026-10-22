defmodule Handbean.Agent.Provider.OpenAIResponsesStreamTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Handbean.Agent.Provider.OpenAITestSupport

  alias Handbean.Agent.Message
  alias Handbean.Agent.Provider.OpenAI

  setup do
    Req.Test.stub(__MODULE__, nil)
    :ok
  end

  test "stream preserves a safe callback exception with its original stack" do
    config =
      config_with_sse_stream(__MODULE__, [sse_response_output_text_delta("private response")])

    assert {:error, {exception, stacktrace}} =
             OpenAI.stream([Message.user("Hi")], [], config, fn chunk ->
               raise ArgumentError, chunk
             end)

    assert Exception.message(exception) =~ "ArgumentError"
    assert Exception.message(exception) =~ "sse_event_handler"
    assert [{__MODULE__, _, _, _} | _] = stacktrace
    refute inspect({exception, stacktrace}) =~ "private response"
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
            __MODULE__,
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
          config_with_sse_stream(__MODULE__, [
            event,
            sse_response_completed([assistant_text_item("done")], %{})
          ])

        assert {:error, reason} = OpenAI.stream([Message.user("Hi")], [], config, on_chunk)
        refute inspect(reason) =~ "private callback data"

        message =
          case reason do
            {exception, stacktrace} when is_list(stacktrace) -> Exception.message(exception)
            message when is_binary(message) -> message
          end

        assert byte_size(message) < 200
      end
    end

    test "preserves invalid tool arguments errors in a completed stream" do
      config =
        config_with_sse_stream(__MODULE__, [
          sse_response_completed([function_call_item("call_bad", "read", "not JSON")], %{})
        ])

      assert {:error, reason} = OpenAI.stream([Message.user("Hi")], [], config, fn _ -> :ok end)
      assert reason =~ "Invalid JSON in tool call arguments"
    end

    test "malformed completed items cannot disappear behind a later completed response" do
      item = %{"type" => "function_call", "call_id" => "bad", "arguments" => "{}"}

      config =
        config_with_sse_stream(__MODULE__, [
          "event: response.output_item.done\ndata: #{Handbean.JSON.encode!(%{"item" => item})}\n\n",
          sse_response_completed([assistant_text_item("done")], %{})
        ])

      assert {:error, "Malformed OpenAI function_call"} =
               OpenAI.stream([Message.user("Hi")], [], config, fn _ -> :ok end)
    end

    test "emits text chunks and returns correct response" do
      config =
        config_with_sse_stream(__MODULE__, [
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
        config_with_sse_stream(__MODULE__, [
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
        config_with_sse_stream(__MODULE__, [
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
        config_with_sse_stream(__MODULE__, [
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
          __MODULE__,
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
        config_with_sse_stream(__MODULE__, [
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
        config_with_sse_stream(
          __MODULE__,
          List.duplicate(sse_response_output_text_delta(phrase), 20)
        )

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
          __MODULE__,
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
        config_with_sse_stream(__MODULE__, [
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
          __MODULE__,
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
          __MODULE__,
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
        config_with_sse_stream(__MODULE__, [
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
end
