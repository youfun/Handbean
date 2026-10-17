defmodule Handbean.Agent.Provider.OpenAIStreamTest do
  @moduledoc """
  Unit tests for Handbean.Agent.Provider.OpenAIStream — OpenAI SSE stream decoder.

  Tests the pure-function internals: event processing, tool call accumulation,
  and response building. Does not require HTTP or Req.
  """

  use ExUnit.Case, async: true

  alias Handbean.Agent.Provider.OpenAIStream

  test "stream/5 rejects malformed events and unresolvable tool calls instead of returning success" do
    tool_events =
      for function <- [%{"arguments" => "{}"}, %{"name" => "read", "arguments" => "[]"}] do
        Handbean.JSON.encode!(%{
          "choices" => [
            %{
              "delta" => %{
                "tool_calls" => [%{"index" => 0, "id" => "bad", "function" => function}]
              }
            }
          ]
        })
      end

    finish =
      Handbean.JSON.encode!(%{
        "choices" => [%{"delta" => %{}, "finish_reason" => "tool_calls"}]
      })

    for data <- ["not-json", "{}" | tool_events] do
      body = "data: #{data}\n\ndata: #{finish}\n\ndata: [DONE]\n\n"

      Req.Test.stub(__MODULE__, fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)
        {:ok, conn} = Plug.Conn.chunk(conn, body)
        conn
      end)

      assert {:error, reason} =
               OpenAIStream.stream(
                 "https://provider.test/chat/completions",
                 [],
                 %{},
                 fn _ -> :ok end,
                 plug: {Req.Test, __MODULE__}
               )

      assert is_binary(reason)
      assert byte_size(reason) < 200
    end
  end

  defp new_acc do
    %{
      buffer: "",
      content: "",
      reasoning_content: "",
      tool_calls: %{},
      finish_reason: nil,
      usage: %{},
      on_chunk: fn _ -> :ok end,
      tool_defs: []
    }
  end

  defp with_on_chunk(acc, fun) do
    %{acc | on_chunk: fun}
  end

  describe "process_event/2 — text accumulation" do
    test "accumulates text content from delta" do
      acc = new_acc()

      event = %{
        "choices" => [
          %{"index" => 0, "delta" => %{"content" => "Hello"}}
        ]
      }

      acc = OpenAIStream.process_event(acc, event)
      assert acc.content == "Hello"
    end

    test "calls on_chunk for text content" do
      acc =
        with_on_chunk(new_acc(), fn text ->
          Process.put(:test_chunk, text)
        end)

      event = %{
        "choices" => [
          %{"index" => 0, "delta" => %{"content" => "World"}}
        ]
      }

      OpenAIStream.process_event(acc, event)
      assert Process.get(:test_chunk) == "World"
      Process.delete(:test_chunk)
    end

    test "accumulates reasoning_content" do
      acc = new_acc()

      event = %{
        "choices" => [
          %{"index" => 0, "delta" => %{"reasoning_content" => "Let me think..."}}
        ]
      }

      acc = OpenAIStream.process_event(acc, event)
      assert acc.reasoning_content == "Let me think..."
    end

    test "accumulates multiple deltas" do
      acc = new_acc()

      e1 = %{"choices" => [%{"index" => 0, "delta" => %{"content" => "A"}}]}
      e2 = %{"choices" => [%{"index" => 0, "delta" => %{"content" => "B"}}]}
      e3 = %{"choices" => [%{"index" => 0, "delta" => %{"content" => "C"}}]}

      acc =
        acc
        |> OpenAIStream.process_event(e1)
        |> OpenAIStream.process_event(e2)
        |> OpenAIStream.process_event(e3)

      assert acc.content == "ABC"
    end
  end

  describe "process_event/2 — finish_reason" do
    test "captures finish_reason from choice" do
      acc = new_acc()

      event = %{
        "choices" => [
          %{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}
        ]
      }

      acc = OpenAIStream.process_event(acc, event)
      assert acc.finish_reason == "stop"
    end

    test "captures tool_calls finish_reason" do
      acc = new_acc()

      event = %{
        "choices" => [
          %{"index" => 0, "delta" => %{}, "finish_reason" => "tool_calls"}
        ]
      }

      acc = OpenAIStream.process_event(acc, event)
      assert acc.finish_reason == "tool_calls"
    end
  end

  describe "process_event/2 — tool call accumulation" do
    test "accumulates tool call id, name, and arguments" do
      acc = new_acc()

      event = %{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "tool_calls" => [
                %{
                  "index" => 0,
                  "id" => "call_001",
                  "type" => "function",
                  "function" => %{
                    "name" => "read",
                    "arguments" => Jason.encode!(%{file_path: "test.txt"})
                  }
                }
              ]
            }
          }
        ]
      }

      acc = OpenAIStream.process_event(acc, event)

      assert map_size(acc.tool_calls) == 1
      tc = acc.tool_calls[0]
      assert tc.id == "call_001"
      assert tc.name == "read"
      assert tc.arguments_buffer == Jason.encode!(%{file_path: "test.txt"})
    end

    test "accumulates tool call arguments in fragments" do
      acc = new_acc()

      args = Jason.encode!(%{file_path: "test.txt"})
      {part1, part2} = String.split_at(args, 8)

      e1 = %{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "tool_calls" => [
                %{
                  "index" => 0,
                  "id" => "call_001",
                  "type" => "function",
                  "function" => %{"name" => "read", "arguments" => part1}
                }
              ]
            }
          }
        ]
      }

      e2 = %{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "tool_calls" => [
                %{
                  "index" => 0,
                  "type" => "function",
                  "function" => %{"arguments" => part2}
                }
              ]
            }
          }
        ]
      }

      acc = acc |> OpenAIStream.process_event(e1) |> OpenAIStream.process_event(e2)

      tc = acc.tool_calls[0]
      assert tc.arguments_buffer == args
    end

    test "handles multiple parallel tool calls" do
      acc = new_acc()

      e1 = %{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "tool_calls" => [
                %{
                  "index" => 0,
                  "id" => "c0",
                  "type" => "function",
                  "function" => %{"name" => "read", "arguments" => "{}"}
                }
              ]
            }
          }
        ]
      }

      e2 = %{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "tool_calls" => [
                %{
                  "index" => 1,
                  "id" => "c1",
                  "type" => "function",
                  "function" => %{"name" => "write", "arguments" => "{}"}
                }
              ]
            }
          }
        ]
      }

      acc = acc |> OpenAIStream.process_event(e1) |> OpenAIStream.process_event(e2)

      assert map_size(acc.tool_calls) == 2
      assert acc.tool_calls[0].name == "read"
      assert acc.tool_calls[1].name == "write"
    end
  end

  describe "process_event/2 — usage" do
    test "preserves cache usage on both final usage chunks and choice chunks" do
      usage = %{
        "prompt_tokens" => 100,
        "completion_tokens" => 17,
        "prompt_tokens_details" => %{"cached_tokens" => 80}
      }

      for choices <- [
            [],
            [%{"delta" => nil}],
            [%{"delta" => %{"content" => "Done"}, "finish_reason" => "stop"}]
          ] do
        acc =
          OpenAIStream.process_event(%{new_acc() | finish_reason: "stop"}, %{
            "choices" => choices,
            "usage" => usage
          })

        assert {:ok, %{usage: result}} = OpenAIStream.build_response(acc)
        assert result.input_tokens == 100
        assert result.total_input_tokens == 100
        assert result.cache_read_input_tokens == 80
        assert result.cache_creation_input_tokens == 0
        assert result.output_tokens == 17
      end
    end

    test "keeps prompt cache writes from the final usage chunk" do
      usage = %{
        "prompt_tokens" => 2600,
        "completion_tokens" => 10,
        "prompt_tokens_details" => %{"cached_tokens" => 2000, "cache_write_tokens" => 400}
      }

      acc =
        OpenAIStream.process_event(%{new_acc() | finish_reason: "stop"}, %{
          "choices" => [],
          "usage" => usage
        })

      assert {:ok, %{usage: result}} = OpenAIStream.build_response(acc)
      assert result.input_tokens == 2600
      assert result.total_input_tokens == 2600
      assert result.cache_read_input_tokens == 2000
      assert result.cache_creation_input_tokens == 400
    end

    test "captures usage from final chunk" do
      acc = new_acc()

      event = %{
        "choices" => [],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}
      }

      acc = OpenAIStream.process_event(acc, event)
      assert acc.usage["prompt_tokens"] == 10
      assert acc.usage["completion_tokens"] == 5
    end

    test "captures usage without choices" do
      acc = new_acc()

      event = %{"usage" => %{"prompt_tokens" => 20}}

      acc = OpenAIStream.process_event(acc, event)
      assert acc.usage["prompt_tokens"] == 20
    end
  end

  describe "process_event/2 — edge cases" do
    test "ignores unknown event types" do
      acc = new_acc()
      acc = OpenAIStream.process_event(acc, %{"object" => "chat.completion.chunk"})
      assert acc.content == ""
    end

    test "handles nil delta" do
      acc = new_acc()
      event = %{"choices" => [%{"index" => 0, "delta" => nil}]}
      acc = OpenAIStream.process_event(acc, event)
      assert acc.content == ""
    end
  end

  describe "handle_event/2" do
    test "passes through [DONE] event" do
      acc = new_acc()
      acc2 = OpenAIStream.handle_event(acc, %{data: "[DONE]"})
      assert acc2 == acc
    end

    test "processes JSON data event" do
      acc = new_acc()
      event = %{data: Jason.encode!(%{choices: [%{delta: %{content: "test"}}]})}
      acc = OpenAIStream.handle_event(acc, event)
      assert acc.content == "test"
    end
  end

  describe "build_response/1" do
    test "builds end_turn response from text-only stream" do
      acc = %{new_acc() | content: "Hello World", finish_reason: "stop"}

      assert {:ok, %{stop_reason: :end_turn, messages: [msg], usage: usage}} =
               OpenAIStream.build_response(acc)

      assert is_list(msg.content)
      text_block = hd(msg.content)
      assert text_block[:type] == "text"
      assert text_block[:text] == "Hello World"
      assert usage[:input_tokens] == 0
      assert usage[:output_tokens] == 0
    end

    test "builds tool_use response when tool calls were accumulated" do
      args = Jason.encode!(%{file_path: "test.txt"})

      acc = %{
        new_acc()
        | tool_calls: %{0 => %{id: "call_001", name: "read", arguments_buffer: args}},
          finish_reason: "tool_calls"
      }

      assert {:ok, %{stop_reason: :tool_use, messages: [msg]}} = OpenAIStream.build_response(acc)

      assert is_list(msg.content)
      tc = Enum.find(msg.content, &(&1[:type] == "tool_use"))
      assert tc[:id] == "call_001"
      assert tc[:name] == "read"
      assert tc[:input]["file_path"] == "test.txt"
    end

    test "includes reasoning content when present" do
      acc = %{
        new_acc()
        | content: "Answer",
          reasoning_content: "Let me think...",
          finish_reason: "stop"
      }

      assert {:ok, %{messages: [msg]}} = OpenAIStream.build_response(acc)

      thinking_block = Enum.find(msg.content, &(&1[:type] == "thinking"))
      assert thinking_block[:thinking] == "Let me think..."
    end

    test "handles empty content" do
      acc = %{new_acc() | content: "", finish_reason: "stop"}

      assert {:ok, %{stop_reason: :end_turn, messages: [msg]}} =
               OpenAIStream.build_response(acc)

      assert Enum.all?(msg.content, &(&1[:type] != "text" or &1[:text] == ""))
    end

    test "recovers a missing streamed tool name when arguments match one definition" do
      args = Jason.encode!(%{url: "https://example.com"})

      acc = %{
        new_acc()
        | tool_calls: %{0 => %{id: "", name: nil, arguments_buffer: args}},
          finish_reason: "tool_calls",
          tool_defs: [
            %{
              "type" => "function",
              "function" => %{
                "name" => "web_fetch",
                "parameters" => %{
                  "type" => "object",
                  "properties" => %{"url" => %{"type" => "string"}},
                  "required" => ["url"]
                }
              }
            },
            %{
              "type" => "function",
              "function" => %{
                "name" => "read",
                "parameters" => %{
                  "type" => "object",
                  "properties" => %{"file_path" => %{"type" => "string"}},
                  "required" => ["file_path"]
                }
              }
            }
          ]
      }

      assert {:ok, %{stop_reason: :tool_use, messages: [msg]}} = OpenAIStream.build_response(acc)
      tc = Enum.find(msg.content, &(&1[:type] == "tool_use"))
      assert tc[:name] == "web_fetch"
      assert tc[:id] == "call_0"
      assert tc[:input]["url"] == "https://example.com"
    end

    test "recovers a missing name from atom-keyed tool definitions" do
      args = Jason.encode!(%{url: "https://example.com"})

      acc = %{
        new_acc()
        | tool_calls: %{0 => %{id: "", name: nil, arguments_buffer: args}},
          finish_reason: "tool_calls",
          tool_defs: [
            %{
              type: "function",
              function: %{
                name: "web_fetch",
                parameters: %{
                  type: "object",
                  properties: %{url: %{type: "string"}},
                  required: ["url"]
                }
              }
            }
          ]
      }

      assert {:ok, %{messages: [msg]}} = OpenAIStream.build_response(acc)
      assert Enum.find(msg.content, &(&1[:type] == "tool_use"))[:name] == "web_fetch"
    end

    test "rejects a missing tool name when more than one definition matches" do
      args = Jason.encode!(%{url: "https://example.com"})

      url_tool = fn name ->
        %{
          "type" => "function",
          "function" => %{
            "name" => name,
            "parameters" => %{
              "type" => "object",
              "properties" => %{"url" => %{"type" => "string"}},
              "required" => ["url"]
            }
          }
        }
      end

      acc = %{
        new_acc()
        | tool_calls: %{0 => %{id: "", name: "", arguments_buffer: args}},
          finish_reason: "tool_calls",
          tool_defs: [url_tool.("web_fetch"), url_tool.("open_url")]
      }

      assert {:error, "Missing or ambiguous tool call name"} = OpenAIStream.build_response(acc)
    end

    test "returns error for invalid tool call JSON" do
      acc = %{
        new_acc()
        | tool_calls: %{
            0 => %{id: "call_001", name: "read", arguments_buffer: "not valid json {{"}
          },
          finish_reason: "tool_calls"
      }

      assert {:error, reason} = OpenAIStream.build_response(acc)
      assert reason =~ "Invalid tool call JSON"
    end

    test "maps finish_reason correctly" do
      assert {:ok, %{stop_reason: :end_turn}} =
               OpenAIStream.build_response(%{new_acc() | finish_reason: "stop"})

      assert {:error, "Provider response announced tool calls but supplied none"} =
               OpenAIStream.build_response(%{new_acc() | finish_reason: "tool_calls"})

      assert {:error, "Provider output truncated (finish_reason=length)"} =
               OpenAIStream.build_response(%{new_acc() | finish_reason: "length"})

      assert {:error, "Provider output blocked (finish_reason=content_filter)"} =
               OpenAIStream.build_response(%{new_acc() | finish_reason: "content_filter"})

      assert {:error, "Provider stream ended with missing finish_reason"} =
               OpenAIStream.build_response(%{new_acc() | finish_reason: nil})
    end
  end
end
