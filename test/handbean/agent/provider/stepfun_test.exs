defmodule Handbean.Agent.Provider.StepFunTest do
  use ExUnit.Case, async: false

  alias Handbean.Agent.Message
  alias Handbean.Agent.Provider.StepFun

  # ── Mock Req modules for non-streaming (OpenAICompat uses post/2) ──

  defmodule MockReq do
    def post(url, opts) do
      Process.put(:stepfun_last_url, url)
      Process.put(:stepfun_last_headers, opts[:headers])
      Process.put(:stepfun_last_body, opts[:json])
      Process.put(:stepfun_last_receive_timeout, opts[:receive_timeout])
      Process.put(:stepfun_last_connect_timeout, opts[:connect_options][:timeout])

      {:ok,
       %{
         status: 200,
         body: %{
           "id" => "chatcmpl-001",
           "object" => "chat.completion",
           "model" => "step-router-v1",
           "choices" => [
             %{
               "index" => 0,
               "message" => %{"role" => "assistant", "content" => "ok"},
               "finish_reason" => "stop"
             }
           ],
           "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1}
         }
       }}
    end
  end

  defmodule NonStreamToolUseMockReq do
    def post(url, opts) do
      Process.put(:stepfun_last_url, url)
      Process.put(:stepfun_last_headers, opts[:headers])
      Process.put(:stepfun_last_body, opts[:json])

      {:ok,
       %{
         status: 200,
         body: %{
           "id" => "chatcmpl-002",
           "object" => "chat.completion",
           "model" => "step-router-v1",
           "choices" => [
             %{
               "index" => 0,
               "message" => %{
                 "role" => "assistant",
                 "content" => "Let me read that.",
                 "tool_calls" => [
                   %{
                     "id" => "call_001",
                     "type" => "function",
                     "function" => %{
                       "name" => "read",
                       "arguments" => ~s({"file_path":"mix.exs"})
                     }
                   }
                 ]
               },
               "finish_reason" => "tool_calls"
             }
           ],
           "usage" => %{"prompt_tokens" => 20, "completion_tokens" => 15}
         }
       }}
    end
  end

  # ── Mock Req modules for streaming (OpenAIStream uses request/1) ──

  defmodule StreamingTextMockReq do
    def request(opts) do
      Handbean.Agent.Provider.StepFunTest.record_stream_request(opts)

      Handbean.Agent.Provider.StepFunTest.feed_sse(opts[:into], [
        Handbean.Agent.Provider.StepFunTest.openai_delta(%{"content" => "Hello"}),
        Handbean.Agent.Provider.StepFunTest.openai_delta(%{"content" => " World"}, "stop"),
        Handbean.Agent.Provider.StepFunTest.openai_usage(10, 5),
        "data: [DONE]\n\n"
      ])
    end
  end

  defmodule StreamingToolUseMockReq do
    def request(opts) do
      Handbean.Agent.Provider.StepFunTest.record_stream_request(opts)

      Handbean.Agent.Provider.StepFunTest.feed_sse(opts[:into], [
        Handbean.Agent.Provider.StepFunTest.openai_delta(%{
          "tool_calls" => [
            %{
              "index" => 0,
              "id" => "call_1",
              "function" => %{"name" => "read", "arguments" => "{\"file_path\""}
            }
          ]
        }),
        Handbean.Agent.Provider.StepFunTest.openai_delta(%{
          "tool_calls" => [
            %{
              "index" => 0,
              "function" => %{"arguments" => ": \"README.md\"}"}
            }
          ]
        }),
        Handbean.Agent.Provider.StepFunTest.openai_delta(%{}, "tool_calls"),
        Handbean.Agent.Provider.StepFunTest.openai_usage(20, 15),
        "data: [DONE]\n\n"
      ])
    end
  end

  defmodule StreamingToolUseMalformedInputMockReq do
    def request(opts) do
      Handbean.Agent.Provider.StepFunTest.record_stream_request(opts)

      Handbean.Agent.Provider.StepFunTest.feed_sse(opts[:into], [
        Handbean.Agent.Provider.StepFunTest.openai_delta(%{
          "tool_calls" => [
            %{
              "index" => 0,
              "id" => "call_bad",
              "function" => %{
                "name" => "bash",
                "arguments" => "{\"command\": \"cat << 'EOF'\\nunterminated"
              }
            }
          ]
        }),
        Handbean.Agent.Provider.StepFunTest.openai_delta(%{}, "tool_calls"),
        "data: [DONE]\n\n"
      ])
    end
  end

  defmodule StreamingTextWithToolMockReq do
    def request(opts) do
      Handbean.Agent.Provider.StepFunTest.record_stream_request(opts)

      Handbean.Agent.Provider.StepFunTest.feed_sse(opts[:into], [
        Handbean.Agent.Provider.StepFunTest.openai_delta(%{"content" => "I will read the file"}),
        Handbean.Agent.Provider.StepFunTest.openai_delta(%{
          "tool_calls" => [
            %{
              "index" => 0,
              "id" => "call_abc",
              "function" => %{
                "name" => "read",
                "arguments" => "{\"file_path\": \"README.md\"}"
              }
            }
          ]
        }),
        Handbean.Agent.Provider.StepFunTest.openai_delta(%{}, "tool_calls"),
        Handbean.Agent.Provider.StepFunTest.openai_usage(25, 20),
        "data: [DONE]\n\n"
      ])
    end
  end

  defmodule StreamingThinkingMockReq do
    def request(opts) do
      Handbean.Agent.Provider.StepFunTest.record_stream_request(opts)

      Handbean.Agent.Provider.StepFunTest.feed_sse(opts[:into], [
        Handbean.Agent.Provider.StepFunTest.openai_delta(%{
          "reasoning_content" => "hidden reasoning"
        }),
        Handbean.Agent.Provider.StepFunTest.openai_delta(
          %{"content" => "Visible answer"},
          "stop"
        ),
        Handbean.Agent.Provider.StepFunTest.openai_usage(8, 8),
        "data: [DONE]\n\n"
      ])
    end
  end

  defmodule StreamingErrorMockReq do
    def request(opts) do
      Process.put(:stepfun_last_url, opts[:url])

      {:ok,
       %{
         status: 429,
         body:
           "{\"error\":{\"message\":\"Rate limit exceeded. Retry after 30 seconds.\",\"type\":\"rate_limit_error\"}}",
         headers: %{"retry-after" => "30"},
         private: %{}
       }}
    end
  end

  defmodule ConnectionErrorMockReq do
    def request(_opts) do
      {:error, %Mint.TransportError{reason: :closed}}
    end
  end

  defmodule TimeoutMockReq do
    def request(_opts) do
      {:error, %Mint.TransportError{reason: :timeout}}
    end
  end

  def record_stream_request(opts) do
    body =
      case opts[:body] do
        bin when is_binary(bin) -> Jason.decode!(bin)
        other -> other
      end

    Process.put(:stepfun_last_url, opts[:url])
    Process.put(:stepfun_last_headers, opts[:headers])
    Process.put(:stepfun_last_body, body)
    Process.put(:stepfun_last_receive_timeout, opts[:receive_timeout])
    Process.put(:stepfun_last_connect_timeout, get_in(opts, [:connect_options, :timeout]))
  end

  def openai_delta(delta, finish_reason \\ nil) do
    choice = %{"index" => 0, "delta" => delta}

    choice =
      if is_binary(finish_reason),
        do: Map.put(choice, "finish_reason", finish_reason),
        else: choice

    "data: #{Jason.encode!(%{"choices" => [choice]})}\n\n"
  end

  def openai_usage(prompt_tokens, completion_tokens) do
    "data: #{Jason.encode!(%{"choices" => [], "usage" => %{"prompt_tokens" => prompt_tokens, "completion_tokens" => completion_tokens}})}\n\n"
  end

  def feed_sse(stream, chunks) do
    resp = %Req.Response{status: 200, private: %{}}

    {_req, resp} =
      Enum.reduce(chunks, {%Req.Request{}, resp}, fn data, {req, resp} ->
        {:cont, {req, resp}} = stream.({:data, data}, {req, resp})
        {req, resp}
      end)

    {:ok, resp}
  end

  setup do
    Process.delete(:stepfun_last_url)
    Process.delete(:stepfun_last_headers)
    Process.delete(:stepfun_last_body)
    Process.delete(:stepfun_last_receive_timeout)
    Process.delete(:stepfun_last_connect_timeout)
    :ok
  end

  defp base_config(req_module) do
    %{
      api_key: "sk-test",
      base_url: "https://api.stepfun.com/step_plan/v1",
      model: "step-router-v1",
      req_module: req_module
    }
  end

  # ── Config ─────────────────────────────────────────────────────────

  test "uses api_key from provider config" do
    config = %{
      api_key: "sk-from-model-json",
      base_url: "https://api.stepfun.com/step_plan/v1",
      model: "step-router-v1",
      req_module: MockReq
    }

    assert {:ok, response} = StepFun.complete([Message.user("hi")], [], config)
    assert [%Message{role: :assistant}] = response.messages
    assert {"authorization", "Bearer sk-from-model-json"} in Process.get(:stepfun_last_headers)
  end

  test "posts to OpenAI Chat Completions URL, not Anthropic /messages" do
    assert {:ok, _response} = StepFun.complete([Message.user("hi")], [], base_config(MockReq))

    url = Process.get(:stepfun_last_url)
    assert String.ends_with?(url, "/chat/completions")
    refute String.ends_with?(url, "/messages")
    assert url == "https://api.stepfun.com/step_plan/v1/chat/completions"
  end

  test "uses resilient receive timeout by default" do
    assert {:ok, _response} = StepFun.complete([Message.user("hi")], [], base_config(MockReq))
    assert Process.get(:stepfun_last_receive_timeout) == 600_000
    assert Process.get(:stepfun_last_connect_timeout) == 30_000
  end

  test "allows overriding default receive and connect timeouts" do
    config =
      base_config(MockReq)
      |> Map.put(:receive_timeout, 120_000)
      |> Map.put(:connect_timeout, 45_000)

    assert {:ok, _response} = StepFun.complete([Message.user("hi")], [], config)
    assert Process.get(:stepfun_last_receive_timeout) == 120_000
    assert Process.get(:stepfun_last_connect_timeout) == 45_000
  end

  test "req_options override default timeouts" do
    config =
      Map.put(base_config(MockReq), :req_options,
        receive_timeout: 240_000,
        connect_options: [timeout: 60_000]
      )

    assert {:ok, _response} = StepFun.complete([Message.user("hi")], [], config)
    assert Process.get(:stepfun_last_receive_timeout) == 240_000
    assert Process.get(:stepfun_last_connect_timeout) == 60_000
  end

  test "does not implicitly read OPENAI_API_KEY when api_key is absent" do
    System.put_env("OPENAI_API_KEY", "sk-from-env")

    try do
      config = %{
        base_url: "https://api.stepfun.com/step_plan/v1",
        model: "step-router-v1",
        req_module: MockReq
      }

      assert {:error, error} = StepFun.complete([Message.user("hi")], [], config)
      assert error =~ "StepFun apiKey not configured"
      assert Process.get(:stepfun_last_headers) == nil
    after
      System.delete_env("OPENAI_API_KEY")
    end
  end

  # ── Request body (OpenAI Chat Completions) ─────────────────────────

  test "request body uses OpenAI messages with system role, not top-level system" do
    config = Map.put(base_config(MockReq), :system_prompt, "You are helpful.")

    assert {:ok, _response} = StepFun.complete([Message.user("hi")], [], config)

    body = Process.get(:stepfun_last_body)
    refute Map.has_key?(body, :system)
    refute Map.has_key?(body, "system")

    messages = body[:messages] || body["messages"]
    assert hd(messages)[:role] == "system" or hd(messages)["role"] == "system"

    assert Enum.any?(messages, fn msg ->
             (msg[:role] || msg["role"]) == "user" and
               (msg[:content] || msg["content"]) == "hi"
           end)
  end

  test "tools use OpenAI function schema, not Anthropic input_schema" do
    tools = [
      %{
        name: "read",
        description: "Read a file",
        input_schema: %{
          "type" => "object",
          "properties" => %{"file_path" => %{"type" => "string"}}
        }
      }
    ]

    assert {:ok, _response} = StepFun.complete([Message.user("hi")], tools, base_config(MockReq))

    body = Process.get(:stepfun_last_body)
    [tool | _] = body[:tools] || body["tools"]

    refute Map.has_key?(tool, :input_schema)
    refute Map.has_key?(tool, "input_schema")
    assert (tool[:type] || tool["type"]) == "function"

    function = tool[:function] || tool["function"]
    assert (function[:name] || function["name"]) == "read"
    assert (function[:parameters] || function["parameters"])["properties"]["file_path"]
  end

  test "user image blocks are converted to OpenAI image_url format" do
    message =
      Message.user([
        %{type: "text", text: "see image"},
        %{type: "image", mime_type: "image/png", data: "iVBORw0KGgo="}
      ])

    assert {:ok, _response} = StepFun.complete([message], [], base_config(MockReq))

    body = Process.get(:stepfun_last_body)

    [user_msg] =
      Enum.filter(body[:messages] || body["messages"], &((&1[:role] || &1["role"]) == "user"))

    content = user_msg[:content] || user_msg["content"]

    assert Enum.any?(content, fn part ->
             (part[:type] || part["type"]) == "text" and
               (part[:text] || part["text"]) == "see image"
           end)

    image = Enum.find(content, fn part -> (part[:type] || part["type"]) == "image_url" end)
    url = get_in(image, [:image_url, :url]) || get_in(image, ["image_url", "url"])
    assert url == "data:image/png;base64,iVBORw0KGgo="
    refute Enum.any?(content, fn part -> (part[:type] || part["type"]) == "image" end)
  end

  # ── Non-streaming response parsing ─────────────────────────────────

  test "non-streaming text response parses choices[0].message" do
    assert {:ok, response} = StepFun.complete([Message.user("hi")], [], base_config(MockReq))
    assert response.stop_reason == :end_turn
    assert Message.text(hd(response.messages)) == "ok"
    assert %{input_tokens: 1, output_tokens: 1} = response.usage
  end

  test "non-streaming tool_use response parses choices[0].message.tool_calls" do
    assert {:ok, response} =
             StepFun.complete(
               [Message.user("read mix.exs")],
               [],
               base_config(NonStreamToolUseMockReq)
             )

    assert response.stop_reason == :tool_use
    assert [%Message{role: :assistant, content: blocks}] = response.messages

    tool_block = Enum.find(List.wrap(blocks), &((&1[:type] || &1["type"]) == "tool_use"))
    assert tool_block[:id] == "call_001"
    assert tool_block[:name] == "read"
    assert tool_block[:input] == %{"file_path" => "mix.exs"}
  end

  # ── Streaming: text only ───────────────────────────────────────────

  test "streaming uses OpenAI chat completion SSE, not Anthropic content_block events" do
    ref = make_ref()

    on_chunk = fn chunk ->
      current = Process.get(ref, [])
      Process.put(ref, current ++ [chunk])
    end

    config =
      base_config(StreamingTextMockReq)
      |> Map.put(:stream, true)
      |> Map.put(:on_chunk, on_chunk)

    assert {:ok, response} = StepFun.complete([Message.user("hi")], [], config)
    assert String.ends_with?(Process.get(:stepfun_last_url), "/chat/completions")

    body = Process.get(:stepfun_last_body)
    assert body["stream"] == true or body[:stream] == true
    refute Map.has_key?(body, "system")
    refute Map.has_key?(body, :system)

    assert response.stop_reason == :end_turn

    assert [%Message{role: :assistant, content: [%{type: "text", text: "Hello World"}]}] =
             response.messages

    assert %{input_tokens: 10, output_tokens: 5} = response.usage
    assert Process.get(ref, []) |> Enum.join() == "Hello World"
  end

  # ── Streaming: tool_use ────────────────────────────────────────────

  test "streaming tool_calls deltas return a single Message with tool block" do
    config =
      base_config(StreamingToolUseMockReq)
      |> Map.put(:stream, true)
      |> Map.put(:on_chunk, fn _chunk -> :ok end)

    assert {:ok, response} = StepFun.complete([Message.user("read README")], [], config)
    assert response.stop_reason == :tool_use
    assert [%Message{role: :assistant, content: content}] = response.messages
    tool_block = Enum.find(content, &(&1[:type] == "tool_use"))
    assert tool_block[:id] == "call_1"
    assert tool_block[:name] == "read"
    assert tool_block[:input] == %{"file_path" => "README.md"}
  end

  test "streaming malformed tool arguments returns a provider error" do
    config =
      base_config(StreamingToolUseMalformedInputMockReq)
      |> Map.put(:stream, true)
      |> Map.put(:on_chunk, fn _chunk -> :ok end)

    assert {:error, error} = StepFun.complete([Message.user("write doc")], [], config)
    assert error =~ "Invalid tool call JSON"
  end

  test "streaming text + tool_calls produces a single Message with both blocks" do
    refs = %{chunks: make_ref()}

    on_chunk = fn chunk ->
      current = Process.get(refs.chunks, [])
      Process.put(refs.chunks, current ++ [chunk])
    end

    config =
      base_config(StreamingTextWithToolMockReq)
      |> Map.put(:stream, true)
      |> Map.put(:on_chunk, on_chunk)

    assert {:ok, response} = StepFun.complete([Message.user("read README")], [], config)
    assert response.stop_reason == :tool_use
    assert [%Message{role: :assistant, content: blocks}] = response.messages

    text_block = Enum.find(blocks, &(&1[:type] == "text"))
    assert text_block[:text] == "I will read the file"

    tool_block = Enum.find(blocks, &(&1[:type] == "tool_use"))
    assert tool_block[:id] == "call_abc"
    assert tool_block[:name] == "read"
    assert tool_block[:input] == %{"file_path" => "README.md"}

    assert Process.get(refs.chunks, []) |> Enum.join() == "I will read the file"
  end

  test "streaming reasoning_content is thinking, not visible assistant text" do
    refs = %{chunks: make_ref()}

    on_chunk = fn chunk ->
      current = Process.get(refs.chunks, [])
      Process.put(refs.chunks, current ++ [chunk])
    end

    config =
      base_config(StreamingThinkingMockReq)
      |> Map.put(:stream, true)
      |> Map.put(:on_chunk, on_chunk)

    assert {:ok, response} = StepFun.complete([Message.user("think")], [], config)
    assert response.stop_reason == :end_turn
    assert [%Message{role: :assistant, content: blocks}] = response.messages

    assert %{type: "thinking", thinking: "hidden reasoning"} =
             Enum.find(blocks, &(&1[:type] == "thinking"))

    assert %{type: "text", text: "Visible answer"} =
             Enum.find(blocks, &(&1[:type] == "text"))

    assert Process.get(refs.chunks, []) == ["Visible answer"]
    refute Enum.any?(Process.get(refs.chunks, []), &String.contains?(&1, "hidden"))
    refute Message.text(hd(response.messages)) =~ "hidden reasoning"
  end

  # ── Message.text/1 and Message.tool_calls/1 compatibility ──────────

  test "Handbean.Agent.Message.text/1 works with content blocks" do
    msg = %Message{role: :assistant, content: [%{type: "text", text: "Hello"}]}
    assert Message.text(msg) == "Hello"
  end

  test "Handbean.Agent.Message.tool_calls/1 extracts tool_use blocks" do
    msg = %Message{
      role: :assistant,
      content: [
        %{type: "text", text: "Let me read"},
        %{type: "tool_use", id: "t1", name: "read", input: %{"path" => "foo"}}
      ]
    }

    assert [%{id: "t1", name: "read", input: %{"path" => "foo"}}] = Message.tool_calls(msg)
  end

  # ── Streaming errors ───────────────────────────────────────────────

  test "streaming 429 error passes through to caller" do
    config =
      base_config(StreamingErrorMockReq)
      |> Map.put(:stream, true)
      |> Map.put(:on_chunk, fn _chunk -> :ok end)

    assert {:error, error} = StepFun.complete([Message.user("hi")], [], config)
    assert error =~ "rate_limit_error" or error =~ "429"
    assert error =~ "Rate limit"
  end

  test "connection error passes through to caller" do
    config =
      base_config(ConnectionErrorMockReq)
      |> Map.put(:stream, true)
      |> Map.put(:on_chunk, fn _chunk -> :ok end)

    assert {:error, error} = StepFun.complete([Message.user("hi")], [], config)
    assert error =~ "HTTP request failed"
  end

  test "timeout error is normalized for turn-level retry" do
    config =
      base_config(TimeoutMockReq)
      |> Map.put(:stream, true)
      |> Map.put(:on_chunk, fn _chunk -> :ok end)

    assert {:error, error} = StepFun.complete([Message.user("hi")], [], config)
    assert error =~ "HTTP request failed"
    assert error =~ "timeout"
  end
end
