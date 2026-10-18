defmodule Handbean.Agent.Provider.OllamaTest do
  use ExUnit.Case, async: false

  alias Handbean.Agent.Message
  alias Handbean.Agent.Provider.Ollama

  defmodule MockReq do
    def post(url, opts) do
      send(self(), {:ollama_request, url, opts[:headers], opts[:json]})

      {:ok,
       %{
         status: 200,
         body: %{
           "choices" => [
             %{
               "message" => %{"role" => "assistant", "content" => "ok"},
               "finish_reason" => "stop"
             }
           ]
         }
       }}
    end
  end

  setup do
    previous = System.get_env("OLLAMA_API_KEY")
    System.delete_env("OLLAMA_API_KEY")
    on_exit(fn -> restore_env("OLLAMA_API_KEY", previous) end)
    :ok
  end

  test "posts chat completions to the cloud endpoint with a Handbean user agent" do
    assert {:ok, %{messages: [%Message{content: "ok"}]}} =
             Ollama.complete(
               [Message.user("hi")],
               [],
               %{api_key: "test-key", model: "gemma4:31b", req_module: MockReq}
             )

    assert_received {:ollama_request, url, headers, body}
    assert url == "https://ollama.com/v1/chat/completions"
    assert {"authorization", "Bearer test-key"} in headers
    assert {"user-agent", "Handbean/0.2.1"} in headers
    assert body.model == "gemma4:31b"
  end

  test "reads OLLAMA_API_KEY when the config key is absent" do
    System.put_env("OLLAMA_API_KEY", "env-key")

    assert {:ok, _} = Ollama.complete([Message.user("hi")], [], %{req_module: MockReq})

    assert_received {:ollama_request, _url, headers, body}
    assert {"authorization", "Bearer env-key"} in headers
    assert body.model == "gemma4:31b"
  end

  test "names the missing Ollama key instead of the generic OpenAI error" do
    assert {:error, message} = Ollama.complete([Message.user("hi")], [], %{})
    assert message =~ "OLLAMA_API_KEY"
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
