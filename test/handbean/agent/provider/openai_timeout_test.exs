defmodule Handbean.Agent.Provider.OpenAITimeoutTest do
  use ExUnit.Case, async: false

  alias Handbean.Agent.Message
  alias Handbean.Agent.Provider.OpenAI

  setup do
    Req.Test.stub(__MODULE__, nil)
    :ok
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
end
