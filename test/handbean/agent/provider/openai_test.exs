defmodule Handbean.Agent.Provider.OpenAICompleteTest do
  use ExUnit.Case, async: false

  alias Handbean.Agent.Message
  alias Handbean.Agent.Provider.OpenAI
  import Handbean.Agent.Provider.OpenAITestSupport

  setup do
    Req.Test.stub(__MODULE__, nil)
    :ok
  end

  describe "complete/3 with text response" do
    test "returns normalized end_turn response" do
      config =
        config_with_response(__MODULE__, %{
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
        config_with_response(__MODULE__, %{
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
        config_with_response(__MODULE__, %{
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
        config_with_response(__MODULE__, %{
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
      config = config_that_captures_request(__MODULE__)

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
      config = config_that_captures_request(__MODULE__) |> Map.put(:system_prompt, "Helpful")
      OpenAI.complete([Message.user("Hi")], [], config)
      assert_received {:request_body, body}
      decoded = Jason.decode!(body)
      assert hd(decoded["input"])["role"] == "system"
    end

    test "formats tool flow as function_call + function_call_output" do
      config = config_that_captures_request(__MODULE__)

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
        config_that_captures_request(__MODULE__)
        |> Map.put(:provider_state, %{response_id: "resp_prev"})

      OpenAI.complete([Message.user("Hi")], [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)
      refute Map.has_key?(decoded, "previous_response_id")
    end

    test "can opt into previous_response_id from matching provider state" do
      config =
        config_that_captures_request(__MODULE__)
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
          config_that_captures_request(__MODULE__)
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
        config_that_captures_request(__MODULE__)
        |> Map.put(:provider_state, %{response_id: "resp_prev"})
        |> Map.put(:previous_response_id, "resp_explicit")

      OpenAI.complete([Message.user("Hi")], [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)
      assert decoded["previous_response_id"] == "resp_explicit"
    end

    test "drops previous_response_id after the model context is forked" do
      config =
        config_that_captures_request(__MODULE__)
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
        config_that_captures_request(__MODULE__)
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
          config_with_response(__MODULE__, %{
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

        config =
          config_with_response(__MODULE__, %{status: 200, body: Handbean.JSON.encode!(body)})

        assert {:error, _reason} = OpenAI.complete([Message.user("Hi")], [], config)
      end
    end

    test "returns error on API error" do
      config =
        config_with_response(__MODULE__, %{
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
end
