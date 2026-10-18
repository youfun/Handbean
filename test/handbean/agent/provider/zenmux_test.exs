defmodule Handbean.Agent.Provider.ZenMuxTest do
  use ExUnit.Case, async: false

  alias Handbean.Agent.Message
  alias Handbean.Agent.Provider.ZenMux

  defmodule TestMockReq do
    def post(url, opts) do
      Process.put(:zenmux_last_url, url)
      Process.put(:zenmux_last_body, opts[:json])
      Process.put(:zenmux_last_headers, opts[:headers])

      {:ok,
       %{
         status: 200,
         body: %{
           "id" => "chatcmpl-zenmux-001",
           "model" => "openai/gpt-5",
           "choices" => [
             %{
               "message" => %{"role" => "assistant", "content" => "Hello from ZenMux"},
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
    old_zenmux_key = System.get_env("ZENMUX_API_KEY")
    System.delete_env("OPENAI_API_KEY")
    System.delete_env("ZENMUX_API_KEY")

    Process.put(:zenmux_last_url, nil)
    Process.put(:zenmux_last_body, nil)
    Process.put(:zenmux_last_headers, nil)

    on_exit(fn ->
      if old_openai_key,
        do: System.put_env("OPENAI_API_KEY", old_openai_key),
        else: System.delete_env("OPENAI_API_KEY")

      if old_zenmux_key,
        do: System.put_env("ZENMUX_API_KEY", old_zenmux_key),
        else: System.delete_env("ZENMUX_API_KEY")
    end)

    :ok
  end

  test "uses ZenMux endpoint and provider/model default" do
    assert {:ok, response} =
             ZenMux.complete([Message.user("hi")], [], %{
               api_key: "sk-test",
               req_module: TestMockReq
             })

    assert Process.get(:zenmux_last_url) == "https://zenmux.ai/api/v1/chat/completions"
    assert Process.get(:zenmux_last_body)[:model] == "openai/gpt-5"
    assert {"authorization", "Bearer sk-test"} in Process.get(:zenmux_last_headers)
    assert hd(response.messages).content == "Hello from ZenMux"
  end

  test "supports model override and ZenMux routing fields" do
    assert {:ok, _response} =
             ZenMux.complete([Message.user("hi")], [], %{
               api_key: "sk-test",
               model: "deepseek/deepseek-v4-pro",
               provider_options: %{order: ["deepseek"], allow_fallbacks: false},
               reasoning_effort: "high",
               req_module: TestMockReq
             })

    body = Process.get(:zenmux_last_body)
    assert body[:model] == "deepseek/deepseek-v4-pro"
    assert body[:provider_options] == %{order: ["deepseek"], allow_fallbacks: false}
    assert body[:reasoning_effort] == "high"
  end

  test "uses ZENMUX_API_KEY fallback without reading OPENAI_API_KEY" do
    System.put_env("OPENAI_API_KEY", "sk-openai")
    System.put_env("ZENMUX_API_KEY", "sk-zenmux")

    assert {:ok, _response} =
             ZenMux.complete([Message.user("hi")], [], %{req_module: TestMockReq})

    assert {"authorization", "Bearer sk-zenmux"} in Process.get(:zenmux_last_headers)
  end

  test "returns ZenMux-specific missing key error" do
    assert {:error, error} = ZenMux.complete([Message.user("hi")], [], %{})
    assert error =~ "ZENMUX_API_KEY not configured"
  end
end
