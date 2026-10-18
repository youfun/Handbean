defmodule Handbean.Agent.Provider.AnthropicTest do
  use ExUnit.Case, async: false

  alias Handbean.Agent.Message
  alias Handbean.Agent.Provider.Anthropic

  setup do
    Req.Test.stub(__MODULE__, nil)
    :ok
  end

  describe "complete/3 with text response" do
    test "does not turn truncation or a missing stop reason into end_turn" do
      for reason <- ["max_tokens", "pause_turn", nil, "unknown"] do
        config =
          config_with_response(%{
            status: 200,
            body:
              Handbean.JSON.encode!(%{
                "type" => "message",
                "content" => [%{"type" => "text", "text" => "partial"}],
                "stop_reason" => reason
              })
          })

        assert {:error, _} = Anthropic.complete([Message.user("Hi")], [], config)
      end
    end

    test "returns normalized end_turn response" do
      config =
        config_with_response(%{
          status: 200,
          body:
            Jason.encode!(%{
              "id" => "msg_01",
              "type" => "message",
              "role" => "assistant",
              "content" => [%{"type" => "text", "text" => "Hello!"}],
              "stop_reason" => "end_turn",
              "usage" => %{
                "input_tokens" => 10,
                "output_tokens" => 5,
                "cache_read_input_tokens" => 70,
                "cache_creation_input_tokens" => 20
              }
            })
        })

      assert {:ok, result} = Anthropic.complete([Message.user("Hi")], [], config)
      assert result.stop_reason == :end_turn
      assert [%Message{role: :assistant}] = result.messages
      assert Message.text(hd(result.messages)) == "Hello!"
      assert result.usage.input_tokens == 10
      assert result.usage.output_tokens == 5
      assert result.usage.total_input_tokens == 100
      assert result.usage.cache_read_input_tokens == 70
      assert result.usage.cache_creation_input_tokens == 20
    end
  end

  describe "complete/3 with tool_use response" do
    test "malformed content or absent announced tool calls cannot become successful output" do
      for block <- [
            %{"type" => "tool_use", "id" => "bad", "input" => %{}},
            %{"type" => "tool_use", "id" => "bad", "name" => "read", "input" => []},
            %{"type" => "text", "text" => nil},
            %{"type" => "text", "text" => "partial"}
          ] do
        config =
          config_with_response(%{
            status: 200,
            body:
              Handbean.JSON.encode!(%{
                "type" => "message",
                "stop_reason" => "tool_use",
                "content" => [block]
              })
          })

        assert {:error, _} = Anthropic.complete([Message.user("Hi")], [], config)

        config =
          config_with_sse_stream([
            ant_event("content_block_start", %{"index" => 0, "content_block" => block}),
            ant_event("content_block_stop", %{"index" => 0}),
            ant_event("message_delta", %{"delta" => %{"stop_reason" => "tool_use"}}),
            ant_event("message_stop", %{})
          ])

        assert {:error, _} = Anthropic.stream([Message.user("Hi")], [], config, fn _ -> :ok end)
      end
    end

    test "returns normalized tool_use response" do
      config =
        config_with_response(%{
          status: 200,
          body:
            Jason.encode!(%{
              "id" => "msg_02",
              "type" => "message",
              "role" => "assistant",
              "content" => [
                %{"type" => "text", "text" => "Let me read that file."},
                %{
                  "type" => "tool_use",
                  "id" => "toolu_01",
                  "name" => "read",
                  "input" => %{"file_path" => "mix.exs"}
                }
              ],
              "stop_reason" => "tool_use",
              "usage" => %{"input_tokens" => 20, "output_tokens" => 15}
            })
        })

      assert {:ok, result} =
               Anthropic.complete(
                 [Message.user("Read mix.exs")],
                 [%{name: "read", description: "Read a file", input_schema: %{}}],
                 config
               )

      assert result.stop_reason == :tool_use
      assert [%Message{role: :assistant, content: blocks}] = result.messages
      tool_call = Enum.find(blocks, &(&1.type == "tool_use"))
      assert tool_call.name == "read"
      assert tool_call.id == "toolu_01"
      assert tool_call.input == %{"file_path" => "mix.exs"}
    end
  end

  describe "complete/3 message formatting" do
    test "formats user messages correctly" do
      config = config_that_captures_request()

      Anthropic.complete(
        [Message.user("Hello"), Message.assistant("Hi"), Message.user("How?")],
        [],
        config
      )

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)
      assert length(decoded["messages"]) == 3
      assert hd(decoded["messages"])["role"] == "user"
    end

    test "includes system prompt" do
      config = config_that_captures_request() |> Map.put(:system_prompt, "You are helpful.")
      Anthropic.complete([Message.user("Hi")], [], config)
      assert_received {:request_body, body}
      assert Jason.decode!(body)["system"] == "You are helpful."
    end

    test "includes tool definitions" do
      config = config_that_captures_request()

      Anthropic.complete(
        [Message.user("Hi")],
        [%{name: "read", description: "Read", input_schema: %{type: "object", properties: %{}}}],
        config
      )

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)
      assert hd(decoded["tools"])["name"] == "read"
    end

    test "formats tool_result messages correctly" do
      config = config_that_captures_request()

      messages = [
        Message.user("Read"),
        Message.assistant_blocks([
          %{type: "text", text: "Reading..."},
          %{type: "tool_use", id: "toolu_01", name: "read", input: %{"file_path" => "mix.exs"}}
        ]),
        Message.tool_results([Message.tool_result_block("toolu_01", "file contents")])
      ]

      Anthropic.complete(messages, [], config)
      assert_received {:request_body, body}
      decoded = Jason.decode!(body)
      tool_result_msg = List.last(decoded["messages"])
      assert tool_result_msg["role"] == "user"
      assert hd(tool_result_msg["content"])["type"] == "tool_result"
    end
  end

  describe "complete/3 error handling" do
    test "returns error on 500" do
      config = config_with_response(%{status: 500, body: "Server Error"})
      assert {:error, _} = Anthropic.complete([Message.user("Hi")], [], config)
    end

    test "returns error on API error" do
      config =
        config_with_response(%{
          status: 400,
          body:
            Jason.encode!(%{
              "type" => "error",
              "error" => %{"type" => "invalid_request_error", "message" => "bad request"}
            })
        })

      assert {:error, reason} = Anthropic.complete([Message.user("Hi")], [], config)
      assert reason =~ "invalid_request_error"
    end
  end

  describe "complete/3 with cache: true" do
    test "system prompt with cache_control" do
      config =
        config_that_captures_request()
        |> Map.put(:system_prompt, "Helpful")
        |> Map.put(:cache, true)

      Anthropic.complete([Message.user("Hi")], [], config)
      assert_received {:request_body, body}
      decoded = Jason.decode!(body)
      assert is_list(decoded["system"])
      assert hd(decoded["system"])["cache_control"] == %{"type" => "ephemeral"}
    end

    test "last tool gets cache_control" do
      config = config_that_captures_request() |> Map.put(:cache, true)

      tool_defs = [
        %{name: "read", description: "R", input_schema: %{}},
        %{name: "write", description: "W", input_schema: %{}}
      ]

      Anthropic.complete([Message.user("Hi")], tool_defs, config)
      assert_received {:request_body, body}
      decoded = Jason.decode!(body)
      refute Map.has_key?(hd(decoded["tools"]), "cache_control")
      assert List.last(decoded["tools"])["cache_control"] == %{"type" => "ephemeral"}
    end

    test "compaction fork marks the parent prefix, not the summary suffix" do
      config =
        config_that_captures_request()
        |> Map.put(:cache, true)
        |> Map.put(:cache_fork, true)
        |> Map.put(:cache_fork_suffix, 1)

      Anthropic.complete(
        [Message.user("Hi"), Message.assistant("OK"), Message.user("summarize now")],
        [],
        config
      )

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)
      [parent, _assistant, suffix] = decoded["messages"]

      assert parent["content"] |> List.last() |> Map.get("cache_control") == %{
               "type" => "ephemeral"
             }

      assert suffix["content"] == "summarize now"
    end
  end

  # ── stream/4 ──

  describe "stream/4" do
    test "requires message_stop and does not accept provider errors as success" do
      for chunks <- [
            [],
            [ant_event("message_delta", %{"delta" => %{"stop_reason" => "end_turn"}})],
            [
              ant_event("error", %{
                "type" => "error",
                "error" => %{
                  "type" => "overloaded_error",
                  "message" => "overloaded Bearer private-token " <> String.duplicate("x", 4_000)
                }
              }),
              ant_event("message_stop", %{})
            ],
            ["event: message_delta\ndata: not-json\n\n", ant_event("message_stop", %{})]
          ] do
        config = config_with_sse_stream(chunks)

        assert {:error, reason} =
                 Anthropic.stream([Message.user("Hi")], [], config, fn _ -> :ok end)

        assert is_binary(reason)
        assert byte_size(reason) <= 2_000
        refute reason =~ "private-token"
      end
    end

    test "does not replace malformed or unfinished streamed tool JSON with initial empty input" do
      for {args, block_stop} <- [{"not-json", true}, {"[]", true}, {"{\"path\":", false}] do
        events = [
          ant_event("content_block_start", %{
            "index" => 0,
            "content_block" => %{
              "type" => "tool_use",
              "id" => "bad",
              "name" => "read",
              "input" => %{}
            }
          }),
          ant_event("content_block_delta", %{
            "index" => 0,
            "delta" => %{"type" => "input_json_delta", "partial_json" => args}
          })
        ]

        events =
          if block_stop,
            do: events ++ [ant_event("content_block_stop", %{"index" => 0})],
            else: events

        config =
          config_with_sse_stream(
            events ++
              [
                ant_event("message_delta", %{"delta" => %{"stop_reason" => "tool_use"}}),
                ant_event("message_stop", %{})
              ]
          )

        assert {:error, reason} =
                 Anthropic.stream([Message.user("Hi")], [], config, fn _ -> :ok end)

        refute reason =~ args
      end
    end

    test "emits text chunks" do
      config =
        config_with_sse_stream([
          ant_event("message_start", %{
            "message" => %{
              "usage" => %{
                "input_tokens" => 10,
                "output_tokens" => 1,
                "cache_read_input_tokens" => 70,
                "cache_creation_input_tokens" => 20
              }
            }
          }),
          ant_event("content_block_start", %{
            "index" => 0,
            "content_block" => %{"type" => "text", "text" => ""}
          }),
          ant_event("content_block_delta", %{
            "index" => 0,
            "delta" => %{"type" => "text_delta", "text" => "Hello"}
          }),
          ant_event("content_block_delta", %{
            "index" => 0,
            "delta" => %{"type" => "text_delta", "text" => " world"}
          }),
          ant_event("content_block_stop", %{"index" => 0}),
          ant_event("message_delta", %{
            "delta" => %{"stop_reason" => "end_turn"},
            "usage" => %{"output_tokens" => 5}
          }),
          ant_event("message_stop", %{})
        ])

      test_pid = self()
      on_chunk = fn chunk -> send(test_pid, {:chunk, chunk}) end
      assert {:ok, result} = Anthropic.stream([Message.user("Hi")], [], config, on_chunk)
      assert result.stop_reason == :end_turn
      assert Message.text(hd(result.messages)) == "Hello world"
      assert result.usage.total_input_tokens == 100
      assert result.usage.cache_read_input_tokens == 70
      assert result.usage.output_tokens == 5
      assert_received {:chunk, "Hello"}
      assert_received {:chunk, " world"}
    end

    test "accumulates tool call stream" do
      config =
        config_with_sse_stream([
          ant_event("message_start", %{
            "message" => %{"usage" => %{"input_tokens" => 20, "output_tokens" => 0}}
          }),
          ant_event("content_block_start", %{
            "index" => 0,
            "content_block" => %{
              "type" => "tool_use",
              "id" => "toolu_01",
              "name" => "read",
              "input" => %{}
            }
          }),
          ant_event("content_block_delta", %{
            "index" => 0,
            "delta" => %{"type" => "input_json_delta", "partial_json" => "{\"file_path\""}
          }),
          ant_event("content_block_delta", %{
            "index" => 0,
            "delta" => %{"type" => "input_json_delta", "partial_json" => ": \"mix.exs\"}"}
          }),
          ant_event("content_block_stop", %{"index" => 0}),
          ant_event("message_delta", %{
            "delta" => %{"stop_reason" => "tool_use"},
            "usage" => %{"output_tokens" => 15}
          }),
          ant_event("message_stop", %{})
        ])

      assert {:ok, result} =
               Anthropic.stream([Message.user("Read mix.exs")], [], config, fn _ -> :ok end)

      assert result.stop_reason == :tool_use
      tool_call = Enum.find(hd(result.messages).content, &(&1.type == "tool_use"))
      assert tool_call.name == "read"
      assert tool_call.input == %{"file_path" => "mix.exs"}
    end

    test "concatenates thinking signatures and keeps latest non-null usage snapshots" do
      config =
        config_with_sse_stream([
          ant_event("message_start", %{
            "message" => %{
              "usage" => %{
                "input_tokens" => 10,
                "output_tokens" => 1,
                "cache_read_input_tokens" => 70
              }
            }
          }),
          ant_event("content_block_start", %{
            "index" => 0,
            "content_block" => %{"type" => "thinking", "thinking" => ""}
          }),
          ant_event("content_block_delta", %{
            "index" => 0,
            "delta" => %{"type" => "thinking_delta", "thinking" => "reasoning"}
          }),
          ant_event("content_block_delta", %{
            "index" => 0,
            "delta" => %{"type" => "signature_delta", "signature" => "sig-"}
          }),
          ant_event("content_block_delta", %{
            "index" => 0,
            "delta" => %{"type" => "signature_delta", "signature" => "part"}
          }),
          ant_event("content_block_stop", %{"index" => 0}),
          ant_event("message_delta", %{
            "delta" => %{"stop_reason" => "end_turn"},
            "usage" => %{
              "input_tokens" => nil,
              "output_tokens" => 5,
              "cache_read_input_tokens" => nil
            }
          }),
          ant_event("message_stop", %{})
        ])

      assert {:ok, result} =
               Anthropic.stream([Message.user("Think")], [], config, fn _ -> :ok end)

      [thinking] = hd(result.messages).content
      assert thinking.thinking == "reasoning"
      assert thinking.signature == "sig-part"
      assert thinking.provider_context.model == "claude-sonnet-4-6"
      assert result.usage.input_tokens == 10
      assert result.usage.cache_read_input_tokens == 70
      assert result.usage.output_tokens == 5
      assert result.usage.total_input_tokens == 80
    end
  end

  # ── Extended Thinking ──

  describe "complete/3 with thinking" do
    test "preserves thinking block" do
      config =
        config_with_response(%{
          status: 200,
          body:
            Jason.encode!(%{
              "id" => "msg_t",
              "type" => "message",
              "role" => "assistant",
              "content" => [
                %{"type" => "thinking", "thinking" => "Reasoning...", "signature" => "sig123"},
                %{"type" => "redacted_thinking", "data" => "redacted-data"},
                %{"type" => "text", "text" => "Answer: 42"}
              ],
              "stop_reason" => "end_turn",
              "usage" => %{"input_tokens" => 10, "output_tokens" => 30}
            })
        })

      assert {:ok, result} = Anthropic.complete([Message.user("Q")], [], config)
      [thinking, redacted, _] = hd(result.messages).content
      assert thinking.type == "thinking"
      assert thinking.signature == "sig123"

      assert thinking.provider_context == %{
               provider: "https://api.anthropic.com",
               api: "anthropic",
               model: "claude-sonnet-4-6"
             }

      assert redacted == %{
               type: "redacted_thinking",
               data: "redacted-data",
               provider_context: thinking.provider_context
             }
    end

    test "replays only same-origin signed thinking and drops foreign private blocks" do
      config = Map.put(config_that_captures_request(), :provider_key, "anthropic-account")

      same_origin = %{
        provider: "anthropic-account",
        api: "anthropic",
        model: "claude-sonnet-4-6"
      }

      messages = [
        Message.user("continue"),
        Message.assistant_blocks([
          %{
            type: "thinking",
            thinking: "same model reasoning",
            signature: "sig-same",
            provider_context: same_origin
          },
          %{
            type: "thinking",
            thinking: "foreign reasoning",
            signature: "sig-foreign",
            provider_context: %{same_origin | model: "claude-opus-4-6"}
          },
          %{type: "redacted_thinking", data: "same-redacted", provider_context: same_origin},
          %{
            type: "redacted_thinking",
            data: "foreign-redacted",
            provider_context: %{same_origin | model: "claude-opus-4-6"}
          },
          %{type: "thinking", thinking: "legacy reasoning", signature: "sig-legacy"},
          %{
            type: "responses_reasoning",
            item: %{type: "reasoning", encrypted_content: "opaque"}
          },
          %{type: "text", text: "visible"}
        ]),
        Message.assistant_blocks([
          %{
            type: "thinking",
            thinking: "foreign only",
            signature: "sig-foreign-only",
            provider_context: %{same_origin | provider: "other-account"}
          }
        ])
      ]

      assert {:ok, _result} = Anthropic.complete(messages, [], config)
      assert_received {:request_body, body}

      decoded = Jason.decode!(body)
      assert [_, assistant] = decoded["messages"]

      assert assistant["content"] == [
               %{
                 "type" => "thinking",
                 "thinking" => "same model reasoning",
                 "signature" => "sig-same"
               },
               %{"type" => "redacted_thinking", "data" => "same-redacted"},
               %{"type" => "text", "text" => "visible"}
             ]
    end

    test "extended_thinking in request" do
      config = config_that_captures_request() |> Map.put(:extended_thinking, budget_tokens: 5000)
      Anthropic.complete([Message.user("Think")], [], config)
      assert_received {:request_body, body}
      assert Jason.decode!(body)["thinking"] == %{"type" => "enabled", "budget_tokens" => 5000}
    end

    test "raises without budget_tokens" do
      config = config_that_captures_request() |> Map.put(:extended_thinking, [])

      assert_raise ArgumentError, ~r/budget_tokens/, fn ->
        Anthropic.complete([Message.user("Hi")], [], config)
      end
    end
  end

  # ── Retry behavior ──

  describe "retry behavior" do
    test "no retry on 429" do
      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 429, "Too Many") end)

      config = %{
        api_key: "sk-test",
        model: "claude-sonnet-4-6",
        max_tokens: 4096,
        req_options: [plug: {Req.Test, __MODULE__}]
      }

      assert {:error, "HTTP 429: Too Many"} = Anthropic.complete([Message.user("Hi")], [], config)
    end
  end

  # ── Helpers ──

  defp config_with_response(response) do
    %{
      api_key: "sk-ant-test-key",
      model: "claude-sonnet-4-6",
      max_tokens: 4096,
      req_options: [plug: {Req.Test, __MODULE__}, retry: false]
    }
    |> tap(fn _ ->
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, response.status, response.body)
      end)
    end)
  end

  defp ant_event(type, data) do
    "event: #{type}\ndata: #{Jason.encode!(data)}\n\n"
  end

  defp config_with_sse_stream(chunks) do
    %{
      api_key: "sk-ant-test-key",
      model: "claude-sonnet-4-6",
      max_tokens: 4096,
      req_options: [plug: {Req.Test, __MODULE__}, retry: false]
    }
    |> tap(fn _ ->
      Req.Test.stub(__MODULE__, fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)

        Enum.reduce(chunks, conn, fn chunk, conn ->
          {:ok, conn} = Plug.Conn.chunk(conn, chunk)
          conn
        end)
      end)
    end)
  end

  defp config_that_captures_request do
    test_pid = self()

    %{
      api_key: "sk-ant-test-key",
      model: "claude-sonnet-4-6",
      max_tokens: 4096,
      cache: false,
      req_options: [plug: {Req.Test, __MODULE__}, retry: false]
    }
    |> tap(fn _ ->
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, body})

        Plug.Conn.send_resp(
          conn,
          200,
          Jason.encode!(%{
            "id" => "msg_cap",
            "type" => "message",
            "role" => "assistant",
            "content" => [%{"type" => "text", "text" => "ok"}],
            "stop_reason" => "end_turn",
            "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
          })
        )
      end)
    end)
  end
end
