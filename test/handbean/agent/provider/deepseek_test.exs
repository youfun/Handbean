defmodule Handbean.Agent.Provider.DeepSeekTest do
  use ExUnit.Case, async: false

  alias Handbean.Agent.Message
  alias Handbean.Agent.Provider.DeepSeek

  defmodule TestMockReq do
    def post(url, opts) do
      Process.put(:deepseek_last_url, url)
      Process.put(:deepseek_last_body, opts[:json])
      Process.put(:deepseek_last_headers, opts[:headers])

      {:ok,
       %{
         status: 200,
         body: %{
           "id" => "chatcmpl-deepseek-001",
           "model" => "deepseek-v4-flash",
           "choices" => [
             %{
               "message" => %{"role" => "assistant", "content" => "Hello from DeepSeek"},
               "finish_reason" => "stop"
             }
           ],
           "usage" => %{"prompt_tokens" => 8, "completion_tokens" => 4}
         }
       }}
    end
  end

  setup do
    old_openai_key = System.get_env("OPENAI_API_KEY")
    old_deepseek_key = System.get_env("DEEPSEEK_API_KEY")
    System.delete_env("OPENAI_API_KEY")
    System.delete_env("DEEPSEEK_API_KEY")

    Process.put(:deepseek_last_url, nil)
    Process.put(:deepseek_last_body, nil)
    Process.put(:deepseek_last_headers, nil)

    on_exit(fn ->
      if old_openai_key,
        do: System.put_env("OPENAI_API_KEY", old_openai_key),
        else: System.delete_env("OPENAI_API_KEY")

      if old_deepseek_key,
        do: System.put_env("DEEPSEEK_API_KEY", old_deepseek_key),
        else: System.delete_env("DEEPSEEK_API_KEY")
    end)

    :ok
  end

  test "uses DeepSeek OpenAI-compatible endpoint and default v4 flash model" do
    assert {:ok, response} =
             DeepSeek.complete([Message.user("hi")], [], %{
               api_key: "sk-test",
               req_module: TestMockReq
             })

    assert Process.get(:deepseek_last_url) == "https://api.deepseek.com/chat/completions"
    assert Process.get(:deepseek_last_body)[:model] == "deepseek-v4-flash"
    assert {"authorization", "Bearer sk-test"} in Process.get(:deepseek_last_headers)
    assert hd(response.messages).content == "Hello from DeepSeek"
  end

  test "supports deepseek-v4-pro with thinking and reasoning_effort fields" do
    assert {:ok, _response} =
             DeepSeek.complete([Message.user("hi")], [], %{
               api_key: "sk-test",
               model: "deepseek-v4-pro",
               thinking: %{type: "enabled"},
               reasoning_effort: "high",
               req_module: TestMockReq
             })

    body = Process.get(:deepseek_last_body)
    assert body[:model] == "deepseek-v4-pro"
    assert body[:thinking] == %{type: "enabled"}
    assert body[:reasoning_effort] == "high"
  end

  test "uses DEEPSEEK_API_KEY fallback without reading OPENAI_API_KEY" do
    System.put_env("OPENAI_API_KEY", "sk-openai")
    System.put_env("DEEPSEEK_API_KEY", "sk-deepseek")

    assert {:ok, _response} =
             DeepSeek.complete([Message.user("hi")], [], %{req_module: TestMockReq})

    assert {"authorization", "Bearer sk-deepseek"} in Process.get(:deepseek_last_headers)
  end

  test "returns DeepSeek-specific missing key error" do
    assert {:error, error} = DeepSeek.complete([Message.user("hi")], [], %{})
    assert error =~ "DEEPSEEK_API_KEY not configured"
  end
end
