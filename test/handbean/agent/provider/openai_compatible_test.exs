defmodule Handbean.Agent.Provider.OpenAICompatibleTest do
  @moduledoc """
  Tests for Handbean.Agent.Provider.OpenAICompat (vendored from Alloy).

  Uses injectable `:req_module` config to mock HTTP calls without real API requests.
  Covers:
    - Missing API key error
    - API key from env var fallback
    - Base URL concatenation to /chat/completions
    - Simple assistant text response (end_turn)
    - Tool calls response (tool_use) with arguments parsing
    - Invalid tool arguments JSON returns an error
    - tool_result message → OpenAI role=tool mapping
    - 401 no retry
    - 429 retry → success
    - 5xx retry exhausted
    - Tool definitions → OpenAI function tools format
  """

  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Handbean.Agent.Message
  alias Handbean.Agent.Provider.OpenAICompat

  # ── Mock helpers ──

  defmodule TestMockReq do
    def post(url, opts) do
      case Process.get(:openai_mock_responses, []) do
        [response | rest] ->
          Process.put(:openai_mock_responses, rest)
          Process.put(:openai_last_url, url)
          Process.put(:openai_last_body, opts[:json])
          response

        [] ->
          {:ok,
           %{status: 500, body: %{"error" => %{"message" => "mock response list exhausted"}}}}
      end
    end
  end

  setup do
    Process.put(:openai_mock_responses, [])
    Process.put(:openai_last_url, nil)
    Process.put(:openai_last_body, nil)
    :ok
  end

  # ── Fixtures ──

  defp success_body do
    %{
      "id" => "chatcmpl-001",
      "object" => "chat.completion",
      "model" => "step-router-v1",
      "choices" => [
        %{
          "index" => 0,
          "message" => %{"role" => "assistant", "content" => "Hello from OpenAI!"},
          "finish_reason" => "stop"
        }
      ],
      "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}
    }
  end

  defp tool_calls_body do
    %{
      "id" => "chatcmpl-002",
      "object" => "chat.completion",
      "model" => "step-router-v1",
      "choices" => [
        %{
          "index" => 0,
          "message" => %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [
              %{
                "id" => "call_001",
                "type" => "function",
                "function" => %{
                  "name" => "read",
                  "arguments" => ~s({"file_path":"test.txt"})
                }
              }
            ]
          },
          "finish_reason" => "tool_calls"
        }
      ],
      "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 20, "total_tokens" => 30}
    }
  end

  defp multi_tool_calls_body do
    %{
      "id" => "chatcmpl-003",
      "object" => "chat.completion",
      "model" => "step-router-v1",
      "choices" => [
        %{
          "index" => 0,
          "message" => %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [
              %{
                "id" => "call_001",
                "type" => "function",
                "function" => %{
                  "name" => "read",
                  "arguments" => ~s({"file_path":"foo.txt"})
                }
              },
              %{
                "id" => "call_002",
                "type" => "function",
                "function" => %{
                  "name" => "write",
                  "arguments" => ~s({"file_path":"bar.txt","content":"hey"})
                }
              }
            ]
          },
          "finish_reason" => "tool_calls"
        }
      ],
      "usage" => %{"prompt_tokens" => 15, "completion_tokens" => 30, "total_tokens" => 45}
    }
  end

  defp error_body(message) do
    %{"error" => %{"message" => message}}
  end

  defp base_config do
    %{
      api_key: "test-api-key",
      req_module: TestMockReq,
      model: "step-router-v1",
      max_tokens: 100,
      max_retries: 3,
      retry_delay_base_ms: 10
    }
  end

  defp mock_response(status, body) do
    {:ok, %{status: status, body: body}}
  end

  defp user_msg, do: Message.user("Hello")
  defp tool_defs, do: []

  # ── Helper: capture expected logs without losing the return value ──
  defp with_captured_log(fun) do
    capture_log(fn -> Process.put(:captured_result, fun.()) end)
    Process.get(:captured_result)
  end

  # ── Missing API key ──

  describe "missing API key" do
    test "returns error when no api_key in config and no env var" do
      System.delete_env("OPENAI_API_KEY")
      config = base_config() |> Map.delete(:api_key)

      result = OpenAICompat.complete([user_msg()], tool_defs(), config)

      assert {:error, error_msg} = result
      assert error_msg =~ "OPENAI_API_KEY not configured"
    end

    test "uses OPENAI_API_KEY env var when config has no api_key" do
      System.put_env("OPENAI_API_KEY", "env-key-123")
      config = base_config() |> Map.delete(:api_key)

      set_responses([mock_response(200, success_body())])

      assert {:ok, response} = OpenAICompat.complete([user_msg()], tool_defs(), config)
      assert response.stop_reason == :end_turn
      assert hd(response.messages).content == "Hello from OpenAI!"

      System.delete_env("OPENAI_API_KEY")
    end
  end

  # ── URL construction ──

  describe "base_url construction" do
    test "defaults to StepFun Step Plan chat completions endpoint" do
      set_responses([mock_response(200, success_body())])

      OpenAICompat.complete([user_msg()], tool_defs(), base_config())

      assert Process.get(:openai_last_url) ==
               "https://api.stepfun.com/step_plan/v1/chat/completions"
    end

    test "uses custom base_url to build /chat/completions endpoint" do
      config = Map.put(base_config(), :base_url, "http://localhost:8000/v1")

      set_responses([mock_response(200, success_body())])

      OpenAICompat.complete([user_msg()], tool_defs(), config)

      assert Process.get(:openai_last_url) == "http://localhost:8000/v1/chat/completions"
    end

    test "strips trailing slash from custom base_url" do
      config = Map.put(base_config(), :base_url, "http://localhost:8000/v1/")

      set_responses([mock_response(200, success_body())])

      OpenAICompat.complete([user_msg()], tool_defs(), config)

      assert Process.get(:openai_last_url) == "http://localhost:8000/v1/chat/completions"
    end
  end

  # ── Request body construction ──

  describe "request body" do
    test "includes model, messages, and stream false" do
      set_responses([mock_response(200, success_body())])

      OpenAICompat.complete([user_msg()], tool_defs(), base_config())

      body = Process.get(:openai_last_body)

      assert body[:model] == "step-router-v1"
      assert body[:stream] == false
      assert is_list(body[:messages])
    end

    test "injects system prompt as first system message" do
      config = Map.put(base_config(), :system_prompt, "You are helpful")

      set_responses([mock_response(200, success_body())])

      OpenAICompat.complete([user_msg()], tool_defs(), config)

      body = Process.get(:openai_last_body)
      [system_msg | rest] = body[:messages]

      assert system_msg[:role] == "system"
      assert system_msg[:content] == "You are helpful"
      assert length(rest) == 1
    end

    test "omits system message when no system_prompt configured" do
      set_responses([mock_response(200, success_body())])

      OpenAICompat.complete([user_msg()], tool_defs(), base_config())

      body = Process.get(:openai_last_body)

      refute Enum.any?(body[:messages], &(&1[:role] == "system"))
    end

    test "maps user message to role=user" do
      set_responses([mock_response(200, success_body())])

      OpenAICompat.complete([user_msg()], tool_defs(), base_config())

      body = Process.get(:openai_last_body)
      user_msgs = body[:messages] |> Enum.filter(&(&1[:role] == "user"))

      assert length(user_msgs) == 1
      assert hd(user_msgs)[:content] == "Hello"
    end

    test "maps user message with list content (text + image) to role=user with image_url" do
      image_msg = %Message{
        role: :user,
        content: [
          %{type: "text", text: "Look at this:"},
          %{type: "image", mime_type: "image/png", data: "BASE64DATA"}
        ]
      }

      set_responses([mock_response(200, success_body())])

      OpenAICompat.complete([image_msg], tool_defs(), base_config())

      body = Process.get(:openai_last_body)
      user_msgs = body[:messages] |> Enum.filter(&(&1[:role] == "user"))

      assert length(user_msgs) == 1
      content = hd(user_msgs)[:content]
      assert is_list(content)
      assert length(content) == 2
      assert Enum.at(content, 0) == %{type: "text", text: "Look at this:"}

      assert Enum.at(content, 1) == %{
               type: "image_url",
               image_url: %{url: "data:image/png;base64,BASE64DATA"}
             }
    end

    test "includes tool definitions as OpenAI function tools" do
      tool_def = [%{name: "read", description: "Read a file", input_schema: %{type: "object"}}]
      config = base_config()

      set_responses([mock_response(200, success_body())])

      OpenAICompat.complete([user_msg()], tool_def, config)

      body = Process.get(:openai_last_body)

      assert length(body[:tools]) == 1
      tool = hd(body[:tools])
      assert tool[:type] == "function"
      assert tool[:function][:name] == "read"
      assert tool[:function][:description] == "Read a file"
      assert tool[:function][:parameters][:type] == "object"
    end

    test "sets tool_choice to auto when tools are present" do
      tool_def = [%{name: "read", description: "Read a file", input_schema: %{}}]
      config = base_config()

      set_responses([mock_response(200, success_body())])

      OpenAICompat.complete([user_msg()], tool_def, config)

      body = Process.get(:openai_last_body)
      assert body[:tool_choice] == "auto"
    end

    test "omits tools and tool_choice when no tool_defs" do
      set_responses([mock_response(200, success_body())])

      OpenAICompat.complete([user_msg()], tool_defs(), base_config())

      body = Process.get(:openai_last_body)
      refute Map.has_key?(body, :tools)
      refute Map.has_key?(body, :tool_choice)
    end

    test "maps tool_result message to role=tool with atom-key content block" do
      tool_result_msg =
        Message.tool_result(%{
          type: "tool_result",
          tool_use_id: "call_001",
          content: "file contents here",
          is_error: false
        })

      set_responses([mock_response(200, success_body())])

      OpenAICompat.complete([user_msg(), tool_result_msg], tool_defs(), base_config())

      body = Process.get(:openai_last_body)
      tool_msgs = body[:messages] |> Enum.filter(&(&1[:role] == "tool"))

      assert length(tool_msgs) == 1
      assert hd(tool_msgs)[:tool_call_id] == "call_001"
      assert hd(tool_msgs)[:content] == "file contents here"
    end

    test "maps tool_results list to multiple role=tool messages" do
      tool_results_msg =
        Message.tool_results([
          Message.tool_result_block("call_001", "result one"),
          Message.tool_result_block("call_002", "result two")
        ])

      set_responses([mock_response(200, success_body())])

      OpenAICompat.complete([user_msg(), tool_results_msg], tool_defs(), base_config())

      body = Process.get(:openai_last_body)
      tool_msgs = body[:messages] |> Enum.filter(&(&1[:role] == "tool"))

      assert length(tool_msgs) == 2
      assert Enum.at(tool_msgs, 0)[:tool_call_id] == "call_001"
      assert Enum.at(tool_msgs, 0)[:content] == "result one"
      assert Enum.at(tool_msgs, 1)[:tool_call_id] == "call_002"
      assert Enum.at(tool_msgs, 1)[:content] == "result two"
    end

    test "maps assistant text message to role=assistant" do
      msgs = [user_msg(), Message.assistant("I can help!")]

      set_responses([mock_response(200, success_body())])

      OpenAICompat.complete(msgs, tool_defs(), base_config())

      body = Process.get(:openai_last_body)
      assistant_msgs = body[:messages] |> Enum.filter(&(&1[:role] == "assistant"))

      assert length(assistant_msgs) == 1
      assert hd(assistant_msgs)[:content] == "I can help!"
    end

    test "maps assistant tool_use message (atom keys) to OpenAI tool_calls format" do
      tool_use_msg =
        Message.tool_use([
          %{
            type: "tool_use",
            id: "call_001",
            name: "read",
            input: %{"file_path" => "test.txt"}
          }
        ])

      set_responses([mock_response(200, success_body())])

      OpenAICompat.complete([user_msg(), tool_use_msg], tool_defs(), base_config())

      body = Process.get(:openai_last_body)
      assistant_msgs = body[:messages] |> Enum.filter(&(&1[:role] == "assistant"))
      msg = hd(assistant_msgs)

      assert is_list(msg[:tool_calls])
      tc = hd(msg[:tool_calls])
      assert tc[:id] == "call_001"
      assert tc[:type] == "function"
      assert tc[:function][:name] == "read"
      assert Jason.decode!(tc[:function][:arguments]) == %{"file_path" => "test.txt"}
    end
  end

  # ── Successful completion ──

  describe "successful completion" do
    test "preserves standard and DeepSeek cache reads without adding them to total input" do
      for cache <- [
            %{"prompt_tokens_details" => %{"cached_tokens" => 8}},
            %{"prompt_cache_hit_tokens" => 8}
          ] do
        body = update_in(success_body(), ["usage"], &Map.merge(&1, cache))
        set_responses([mock_response(200, body)])
        assert {:ok, %{usage: usage}} = OpenAICompat.complete([user_msg()], [], base_config())
        assert usage.input_tokens == 10
        assert usage.total_input_tokens == 10
        assert usage.cache_read_input_tokens == 8
        assert usage.cache_creation_input_tokens == 0
      end
    end

    test "returns parsed response for end_turn with atom-key tool_use blocks" do
      set_responses([mock_response(200, success_body())])

      result = OpenAICompat.complete([user_msg()], tool_defs(), base_config())

      assert {:ok, %{stop_reason: :end_turn, messages: [msg], usage: usage}} = result
      assert msg.role == :assistant
      assert msg.content == "Hello from OpenAI!"
      assert usage.input_tokens == 10
      assert usage.output_tokens == 5
    end

    test "returns tool_use response with atom-key content blocks" do
      set_responses([mock_response(200, tool_calls_body())])

      result = OpenAICompat.complete([user_msg()], tool_defs(), base_config())

      assert {:ok, %{stop_reason: :tool_use, messages: [msg], usage: usage}} = result
      assert msg.role == :assistant
      assert is_list(msg.content)

      tool_call = List.first(msg.content)
      assert tool_call[:type] == "tool_use"
      assert tool_call[:id] == "call_001"
      assert tool_call[:name] == "read"
      assert tool_call[:input]["file_path"] == "test.txt"
      assert usage.input_tokens == 10
      assert usage.output_tokens == 20
    end

    test "parses multiple tool calls in response" do
      set_responses([mock_response(200, multi_tool_calls_body())])

      result = OpenAICompat.complete([user_msg()], tool_defs(), base_config())

      assert {:ok, %{stop_reason: :tool_use, messages: [msg]}} = result
      assert length(msg.content) == 2

      [tc1, tc2] = msg.content
      assert tc1[:id] == "call_001"
      assert tc1[:name] == "read"
      assert tc1[:input]["file_path"] == "foo.txt"

      assert tc2[:id] == "call_002"
      assert tc2[:name] == "write"
      assert tc2[:input]["file_path"] == "bar.txt"
      assert tc2[:input]["content"] == "hey"
    end

    test "defaults usage to 0 when missing" do
      body = %{
        "id" => "chatcmpl-004",
        "choices" => [
          %{
            "index" => 0,
            "message" => %{"role" => "assistant", "content" => "OK"},
            "finish_reason" => "stop"
          }
        ]
      }

      set_responses([mock_response(200, body)])

      result = OpenAICompat.complete([user_msg()], tool_defs(), base_config())

      assert {:ok, %{usage: usage}} = result
      assert usage.input_tokens == 0
      assert usage.output_tokens == 0
    end
  end

  # ── Invalid tool arguments JSON ──

  describe "invalid tool arguments JSON" do
    test "returns an error for malformed JSON arguments" do
      body = %{
        "id" => "chatcmpl-005",
        "choices" => [
          %{
            "index" => 0,
            "message" => %{
              "role" => "assistant",
              "content" => nil,
              "tool_calls" => [
                %{
                  "id" => "call_bad",
                  "type" => "function",
                  "function" => %{
                    "name" => "read",
                    "arguments" => "not valid json {{"
                  }
                }
              ]
            },
            "finish_reason" => "tool_calls"
          }
        ],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5}
      }

      set_responses([mock_response(200, body)])

      result = OpenAICompat.complete([user_msg()], tool_defs(), base_config())

      assert {:error, reason} = result
      assert reason =~ "Invalid JSON in tool call arguments"
      refute reason =~ "not valid json"
    end

    test "rejects malformed calls and non-object arguments without partial execution" do
      for call <- [
            %{"id" => "bad", "function" => %{"arguments" => "{}"}},
            %{"id" => "bad", "function" => %{"name" => "read", "arguments" => "[]"}},
            %{"id" => "bad", "function" => %{"name" => "read"}},
            %{"function" => %{"name" => "read", "arguments" => "{}"}}
          ] do
        body =
          put_in(tool_calls_body(), ["choices", Access.at(0), "message", "tool_calls"], [call])

        set_responses([mock_response(200, body)])
        assert {:error, _reason} = OpenAICompat.complete([user_msg()], [], base_config())
      end
    end

    test "rejects truncation, missing completion reason, or announced but absent tool calls" do
      for reason <- ["length", "content_filter", nil, "tool_calls"] do
        body = put_in(success_body(), ["choices", Access.at(0), "finish_reason"], reason)
        set_responses([mock_response(200, body)])
        assert {:error, _reason} = OpenAICompat.complete([user_msg()], [], base_config())
      end
    end
  end

  # ── 401/403: no retry ──

  describe "non-retryable errors (401/403)" do
    test "returns error immediately on 401 without retrying" do
      set_responses([
        mock_response(401, error_body("Invalid API key"))
      ])

      result =
        with_captured_log(fn ->
          OpenAICompat.complete([user_msg()], tool_defs(), base_config())
        end)

      assert {:error, error_msg} = result
      assert error_msg =~ "OpenAI API error 401"
      assert error_msg =~ "Invalid API key"
      assert_responses_consumed()
    end

    test "returns error immediately on 403" do
      set_responses([
        mock_response(403, error_body("Forbidden"))
      ])

      result =
        with_captured_log(fn ->
          OpenAICompat.complete([user_msg()], tool_defs(), base_config())
        end)

      assert {:error, error_msg} = result
      assert error_msg =~ "OpenAI API error 403"
      assert error_msg =~ "Forbidden"
    end

    test "returns error immediately on 400" do
      set_responses([
        mock_response(400, error_body("Bad request"))
      ])

      result =
        with_captured_log(fn ->
          OpenAICompat.complete([user_msg()], tool_defs(), base_config())
        end)

      assert {:error, error_msg} = result
      assert error_msg =~ "OpenAI API error 400"
      assert error_msg =~ "Bad request"
    end
  end

  # ── 429: retry → success ──

  describe "retry on 429 (rate limit)" do
    test "retries and succeeds after transient 429" do
      set_responses([
        mock_response(429, error_body("Rate limited")),
        mock_response(200, success_body())
      ])

      result =
        with_captured_log(fn ->
          OpenAICompat.complete([user_msg()], tool_defs(), base_config())
        end)

      assert {:ok, %{messages: [msg]}} = result
      assert msg.content == "Hello from OpenAI!"
      assert_responses_consumed()
    end

    test "respects configurable max_retries" do
      config = base_config() |> Map.put(:max_retries, 1)

      set_responses([
        mock_response(429, error_body("Rate limited")),
        mock_response(429, error_body("Rate limited")),
        mock_response(200, success_body())
      ])

      result =
        with_captured_log(fn ->
          OpenAICompat.complete([user_msg()], tool_defs(), config)
        end)

      assert {:error, error_msg} = result
      assert error_msg =~ "after retries"
    end
  end

  # ── 5xx: retry ──

  describe "retry on 5xx" do
    test "retries 503 and eventually gives up" do
      responses =
        for _ <- 1..4 do
          mock_response(503, error_body("Service unavailable"))
        end

      set_responses(responses)

      result =
        with_captured_log(fn ->
          OpenAICompat.complete([user_msg()], tool_defs(), base_config())
        end)

      assert {:error, error_msg} = result
      assert error_msg =~ "after retries"
    end

    test "retries 502 and succeeds" do
      set_responses([
        mock_response(502, error_body("Bad gateway")),
        mock_response(200, success_body())
      ])

      assert {:ok, response} =
               with_captured_log(fn ->
                 OpenAICompat.complete([user_msg()], tool_defs(), base_config())
               end)

      assert hd(response.messages).content == "Hello from OpenAI!"
    end

    test "retries 504 and succeeds" do
      set_responses([
        mock_response(504, error_body("Gateway timeout")),
        mock_response(200, success_body())
      ])

      assert {:ok, response} =
               with_captured_log(fn ->
                 OpenAICompat.complete([user_msg()], tool_defs(), base_config())
               end)

      assert hd(response.messages).content == "Hello from OpenAI!"
    end

    test "retries 500 and succeeds" do
      set_responses([
        mock_response(500, error_body("Internal server error")),
        mock_response(200, success_body())
      ])

      assert {:ok, response} =
               with_captured_log(fn ->
                 OpenAICompat.complete([user_msg()], tool_defs(), base_config())
               end)

      assert hd(response.messages).content == "Hello from OpenAI!"
    end

    test "summarizes html 500 body instead of returning full page" do
      html =
        "<!doctype html><html><head><title>ZenMux Server Error</title></head><body><script>analytics()</script></body></html>"

      set_responses([
        mock_response(500, html),
        mock_response(500, html),
        mock_response(500, html),
        mock_response(500, html)
      ])

      result =
        with_captured_log(fn ->
          OpenAICompat.complete([user_msg()], tool_defs(), base_config())
        end)

      assert {:error, error_msg} = result
      assert error_msg =~ "OpenAI API error 500"
      assert error_msg =~ "provider returned HTML error page: ZenMux Server Error"
      refute error_msg =~ "<script>"
    end
  end

  # ── Edge cases ──

  describe "edge cases" do
    test "returns error for non-json response body" do
      html = "<!doctype html><html><title>Sub2API</title></html>"
      set_responses([mock_response(200, html)])

      result = OpenAICompat.complete([user_msg()], tool_defs(), base_config())

      assert {:error, error_msg} = result
      assert error_msg =~ "Failed to decode OpenAI-compatible response JSON"
    end

    test "returns error for unexpected json response shape" do
      set_responses([mock_response(200, %{"ok" => true})])

      result =
        with_captured_log(fn ->
          OpenAICompat.complete([user_msg()], tool_defs(), base_config())
        end)

      assert {:error, error_msg} = result
      assert error_msg =~ "Unexpected OpenAI-compatible response shape"
    end

    test "handles empty content message" do
      body = %{
        "id" => "chatcmpl-empty",
        "choices" => [
          %{
            "index" => 0,
            "message" => %{"role" => "assistant", "content" => ""},
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 0}
      }

      set_responses([mock_response(200, body)])

      result = OpenAICompat.complete([user_msg()], tool_defs(), base_config())

      assert {:ok, %{stop_reason: :end_turn, messages: [msg]}} = result
      assert msg.content == ""
    end

    test "handles null content in response" do
      body = %{
        "id" => "chatcmpl-null",
        "choices" => [
          %{
            "index" => 0,
            "message" => %{"role" => "assistant", "content" => nil},
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 0}
      }

      set_responses([mock_response(200, body)])

      result = OpenAICompat.complete([user_msg()], tool_defs(), base_config())

      assert {:ok, %{stop_reason: :end_turn, messages: [msg]}} = result
      assert msg.content == ""
    end

    test "handles tool_call with empty arguments string" do
      body = %{
        "id" => "chatcmpl-empty-args",
        "choices" => [
          %{
            "index" => 0,
            "message" => %{
              "role" => "assistant",
              "content" => nil,
              "tool_calls" => [
                %{
                  "id" => "call_empty",
                  "type" => "function",
                  "function" => %{
                    "name" => "bash",
                    "arguments" => "{}"
                  }
                }
              ]
            },
            "finish_reason" => "tool_calls"
          }
        ],
        "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 5}
      }

      set_responses([mock_response(200, body)])

      result = OpenAICompat.complete([user_msg()], tool_defs(), base_config())

      assert {:ok, %{stop_reason: :tool_use, messages: [msg]}} = result
      tc = List.first(msg.content)
      assert tc[:name] == "bash"
      assert tc[:input] == %{}
    end
  end

  # ── Streaming fallback: tool_defs present → sync mode ──

  describe "streaming fallback to sync" do
    test "falls back to non-streaming when tool_defs present even with stream: true" do
      config =
        base_config()
        |> Map.put(:stream, true)
        |> Map.put(:on_chunk, fn _ -> :ok end)

      tool_def = [%{name: "read", description: "Read a file", input_schema: %{}}]

      set_responses([mock_response(200, success_body())])

      result = OpenAICompat.complete([user_msg()], tool_def, config)

      assert {:ok, %{stop_reason: :end_turn, messages: [msg]}} = result
      assert msg.content == "Hello from OpenAI!"

      # Verify stream: false in the body (non-streaming fallback)
      body = Process.get(:openai_last_body)
      assert body[:stream] == false
      assert body[:tools] != nil
    end
  end

  # ── Helpers ──

  defp set_responses(responses) do
    Process.put(:openai_mock_responses, responses)
  end

  defp assert_responses_consumed do
    remaining = Process.get(:openai_mock_responses, [])

    assert remaining == [],
           "Expected all mock responses to be consumed, but #{length(remaining)} remain"
  end
end
