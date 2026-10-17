defmodule Handbean.Agent.Provider.OpenRouterTest do
  use ExUnit.Case, async: false

  alias Handbean.Agent.Message
  alias Handbean.Agent.Provider.OpenRouter

  defmodule TestMockReq do
    def post(url, opts) do
      Process.put(:openrouter_last_url, url)
      Process.put(:openrouter_last_body, opts[:json])
      Process.put(:openrouter_last_headers, opts[:headers])

      {:ok,
       %{
         status: 200,
         body: %{
           "id" => "chatcmpl-openrouter-001",
           "model" => "openai/gpt-4o",
           "choices" => [
             %{
               "message" => %{"role" => "assistant", "content" => "Hello from OpenRouter"},
               "finish_reason" => "stop"
             }
           ],
           "usage" => %{"prompt_tokens" => 9, "completion_tokens" => 5}
         }
       }}
    end
  end

  setup do
    old_openai_key = System.get_env("OPENAI_API_KEY")
    old_openrouter_key = System.get_env("OPENROUTER_API_KEY")
    System.delete_env("OPENAI_API_KEY")
    System.delete_env("OPENROUTER_API_KEY")

    Process.put(:openrouter_last_url, nil)
    Process.put(:openrouter_last_body, nil)
    Process.put(:openrouter_last_headers, nil)

    on_exit(fn ->
      if old_openai_key,
        do: System.put_env("OPENAI_API_KEY", old_openai_key),
        else: System.delete_env("OPENAI_API_KEY")

      if old_openrouter_key,
        do: System.put_env("OPENROUTER_API_KEY", old_openrouter_key),
        else: System.delete_env("OPENROUTER_API_KEY")
    end)

    :ok
  end

  test "uses OpenRouter endpoint and provider/model default" do
    assert {:ok, response} =
             OpenRouter.complete([Message.user("hi")], [], %{
               api_key: "sk-or-test",
               req_module: TestMockReq
             })

    assert Process.get(:openrouter_last_url) ==
             "https://openrouter.ai/api/v1/chat/completions"

    assert Process.get(:openrouter_last_body)[:model] == "openai/gpt-4o"
    assert {"authorization", "Bearer sk-or-test"} in Process.get(:openrouter_last_headers)
    assert hd(response.messages).content == "Hello from OpenRouter"
  end

  test "maps provider_options onto OpenRouter provider routing" do
    assert {:ok, _response} =
             OpenRouter.complete([Message.user("hi")], [], %{
               api_key: "sk-or-test",
               model: "anthropic/claude-sonnet-4",
               provider_options: %{order: ["anthropic"], allow_fallbacks: false},
               reasoning_effort: "high",
               req_module: TestMockReq
             })

    body = Process.get(:openrouter_last_body)
    assert body[:model] == "anthropic/claude-sonnet-4"
    assert body[:provider] == %{order: ["anthropic"], allow_fallbacks: false}
    refute Map.has_key?(body, :provider_options)
    assert body[:reasoning_effort] == "high"
  end

  test "sends optional ranking headers" do
    assert {:ok, _response} =
             OpenRouter.complete([Message.user("hi")], [], %{
               api_key: "sk-or-test",
               http_referer: "https://sigil.local",
               app_title: "Handbean",
               req_module: TestMockReq
             })

    headers = Process.get(:openrouter_last_headers)
    assert {"HTTP-Referer", "https://sigil.local"} in headers
    assert {"X-OpenRouter-Title", "Handbean"} in headers
  end

  test "uses OPENROUTER_API_KEY fallback without reading OPENAI_API_KEY" do
    System.put_env("OPENAI_API_KEY", "sk-openai")
    System.put_env("OPENROUTER_API_KEY", "sk-or-env")

    assert {:ok, _response} =
             OpenRouter.complete([Message.user("hi")], [], %{req_module: TestMockReq})

    assert {"authorization", "Bearer sk-or-env"} in Process.get(:openrouter_last_headers)
  end

  test "returns OpenRouter-specific missing key error" do
    assert {:error, error} = OpenRouter.complete([Message.user("hi")], [], %{})
    assert error =~ "OPENROUTER_API_KEY not configured"
  end
end
