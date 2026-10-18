defmodule Handbean.Agent.Provider.OpenCodeGoTest do
  use ExUnit.Case, async: false

  alias Handbean.Agent.Message
  alias Handbean.Agent.Provider.OpenCodeGo

  defmodule ChatMock do
    def post(url, opts) do
      send(self(), {:go_chat, url, opts[:headers], opts[:json]})

      {:ok,
       %{
         status: 200,
         body: %{
           "choices" => [
             %{
               "message" => %{"role" => "assistant", "content" => "chat"},
               "finish_reason" => "stop"
             }
           ]
         }
       }}
    end
  end

  defmodule MessagesMock do
    def request(opts) do
      send(self(), {:go_messages, opts[:url], opts[:headers], opts[:body]})

      {:ok,
       %{
         status: 200,
         body: %{
           "id" => "msg_1",
           "type" => "message",
           "role" => "assistant",
           "content" => [%{"type" => "text", "text" => "ok"}],
           "stop_reason" => "end_turn",
           "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
         }
       }}
    end
  end

  defmodule ResponsesMock do
    def request(opts) do
      send(self(), {:go_responses, opts[:url], opts[:headers], opts[:body]})

      {:ok,
       %{
         status: 200,
         body: %{
           "id" => "resp_1",
           "output" => [
             %{
               "type" => "message",
               "role" => "assistant",
               "content" => [%{"type" => "output_text", "text" => "ok"}]
             }
           ],
           "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
         }
       }}
    end
  end

  setup do
    previous = System.get_env("OPENCODE_GO_API_KEY")
    System.delete_env("OPENCODE_GO_API_KEY")
    on_exit(fn -> restore_env("OPENCODE_GO_API_KEY", previous) end)
    :ok
  end

  test "routes GLM to chat completions and sends the session header" do
    assert :openai = OpenCodeGo.api_for("glm-5.3-flash")

    assert {:ok, _} =
             OpenCodeGo.complete([Message.user("hi")], [], %{
               api_key: "go-key",
               model: "glm-5.3-flash",
               conversation_id: "conv-1",
               req_module: ChatMock
             })

    assert_received {:go_chat, url, headers, body}
    assert url == "https://opencode.ai/zen/go/v1/chat/completions"
    assert {"authorization", "Bearer go-key"} in headers
    assert {"user-agent", "Handbean/0.2.1"} in headers
    assert {"x-opencode-session", "conv-1"} in headers
    assert body.model == "glm-5.3-flash"
  end

  test "routes MiniMax to Anthropic messages with bearer auth" do
    assert :anthropic = OpenCodeGo.api_for("minimax-m3")

    assert {:ok, _} =
             OpenCodeGo.complete([Message.user("hi")], [], %{
               api_key: "go-key",
               model: "minimax-m3",
               conversation_id: "conv-2",
               req_module: MessagesMock
             })

    assert_received {:go_messages, url, headers, body}
    assert url == "https://opencode.ai/zen/go/v1/messages"
    assert {"authorization", "Bearer go-key"} in headers
    refute Enum.any?(headers, &match?({"x-api-key", _}, &1))
    assert {"x-opencode-session", "conv-2"} in headers
    assert Handbean.JSON.decode!(body)["model"] == "minimax-m3"
  end

  test "routes GPT Luna to Responses without doubling /v1" do
    assert :openai_responses = OpenCodeGo.api_for("gpt-5.6-luna")

    assert {:ok, _} =
             OpenCodeGo.complete([Message.user("hi")], [], %{
               api_key: "go-key",
               model: "gpt-5.6-luna",
               req_module: ResponsesMock
             })

    assert_received {:go_responses, url, headers, body}
    assert url == "https://opencode.ai/zen/go/v1/responses"
    assert {"authorization", "Bearer go-key"} in headers
    assert {"user-agent", "Handbean/0.2.1"} in headers
    refute Enum.any?(headers, &match?({"x-opencode-session", _}, &1))
    assert Handbean.JSON.decode!(body)["model"] == "gpt-5.6-luna"
  end

  test "unknown models stay on chat completions" do
    assert :openai = OpenCodeGo.api_for("hy3")
    assert :openai = OpenCodeGo.api_for(nil)
  end

  test "names the missing Go key" do
    assert {:error, message} = OpenCodeGo.complete([Message.user("hi")], [], %{})
    assert message =~ "OPENCODE_GO_API_KEY"
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
