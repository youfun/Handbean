defmodule Handbean.Agent.Provider.ModelCatalogTest do
  use ExUnit.Case, async: false

  alias Handbean.Agent.Auth.Storage
  alias Handbean.Agent.ModelConfig
  alias Handbean.Agent.Provider.ModelCatalog
  alias Handbean.Agent.Provider.ModelCatalogTest.XaiReq

  defmodule ReqMock do
    def get(url, opts) do
      send(self(), {:models_request, url, opts})
      Process.get(:model_catalog_response)
    end
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "model_catalog_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    previous = System.get_env("HANDBEAN_MODELS_FILE")
    System.put_env("HANDBEAN_MODELS_FILE", Path.join(dir, "models.json"))

    on_exit(fn ->
      if previous,
        do: System.put_env("HANDBEAN_MODELS_FILE", previous),
        else: System.delete_env("HANDBEAN_MODELS_FILE")

      File.rm_rf!(dir)
    end)

    :ok
  end

  test "responses base without /v1 requests /v1/models" do
    assert ModelCatalog.models_url("http://127.0.0.1:3425", "openai-responses") ==
             "http://127.0.0.1:3425/v1/models"

    assert ModelCatalog.models_url("http://127.0.0.1:3425/v1", "openai-responses") ==
             "http://127.0.0.1:3425/v1/models"
  end

  test "chat completions base keeps its /v1 and appends /models" do
    assert ModelCatalog.models_url("http://127.0.0.1:3425/v1", "openai-chat-completions") ==
             "http://127.0.0.1:3425/v1/models"
  end

  test "discover merges remote ids and keeps a disappeared model unavailable" do
    :ok =
      ModelConfig.add_provider("magpie", %{
        "name" => "Magpie",
        "api" => "openai-responses",
        "baseUrl" => "http://127.0.0.1:3425",
        "apiKey" => "magpie",
        "models" => [
          %{
            "id" => "openai/gpt-4o-mini",
            "name" => "Custom mini",
            "input" => ["text"],
            "enabled" => false
          },
          %{"id" => "gone", "name" => "Gone", "input" => ["text"]}
        ]
      })

    Process.put(
      :model_catalog_response,
      {:ok,
       %{
         status: 200,
         body: %{
           "object" => "list",
           "data" => [
             %{"id" => "openai/gpt-4o-mini", "object" => "model"},
             %{"id" => "deepseek/deepseek-chat", "object" => "model"}
           ]
         }
       }}
    )

    assert {:ok, %{added: 1, total: 3}} =
             ModelCatalog.discover("magpie", req_module: ReqMock)

    assert_received {:models_request, "http://127.0.0.1:3425/v1/models", opts}
    assert {"authorization", "Bearer magpie"} in opts[:headers]

    {:ok, config} = ModelConfig.read_config()
    models = config["providers"]["magpie"]["models"]
    mini = Enum.find(models, &(&1["id"] == "openai/gpt-4o-mini"))
    deepseek = Enum.find(models, &(&1["id"] == "deepseek/deepseek-chat"))
    gone = Enum.find(models, &(&1["id"] == "gone"))

    assert mini["name"] == "Custom mini"
    assert mini["enabled"] == false
    assert mini["contextWindow"] == 128_000
    assert mini["maxTokens"] == 16_384
    assert deepseek["name"] == "DeepSeek-V3.2 (Non-thinking Mode)"
    assert is_integer(deepseek["contextWindow"])
    assert gone["unavailable"] == true
  end

  test "fresh discovery keeps explicit modalities and exact built-in capabilities" do
    :ok =
      ModelConfig.add_provider("magpie", %{
        "name" => "Magpie",
        "api" => "openai-responses",
        "baseUrl" => "http://127.0.0.1:3425",
        "apiKey" => "magpie",
        "models" => []
      })

    Process.put(
      :model_catalog_response,
      {:ok,
       %{
         status: 200,
         body: %{
           "data" => [
             %{"id" => "gpt-5.6-luna"},
             %{"id" => "direct-vision", "input_modalities" => ["image", "text"]},
             %{
               "id" => "openrouter-vision",
               "architecture" => %{"input_modalities" => ["text", "image", "audio"]}
             },
             %{"id" => "unknown-model"}
           ]
         }
       }}
    )

    assert {:ok, %{added: 4, total: 4}} =
             ModelCatalog.discover("magpie", req_module: ReqMock)

    {:ok, config} = ModelConfig.read_config()
    models = config["providers"]["magpie"]["models"]

    assert Enum.find(models, &(&1["id"] == "gpt-5.6-luna"))["input"] == ["text", "image"]
    assert Enum.find(models, &(&1["id"] == "direct-vision"))["input"] == ["text", "image"]
    assert Enum.find(models, &(&1["id"] == "openrouter-vision"))["input"] == ["text", "image"]
    assert Enum.find(models, &(&1["id"] == "unknown-model"))["input"] == ["text"]
  end

  test "llm_db input modalities are mapped into model input capabilities" do
    assert Handbean.LlmDbDefaults.enrich_model("openai/gpt-4o-mini")["input"] == [
             "text",
             "image"
           ]
  end

  test "catalog enrichment survives an llm_db app dir failure" do
    assert Handbean.LlmDbDefaults.enrich_model("provider/unknown-model", nil, fn ->
             raise ArgumentError, "unknown application: :llm_db"
           end) == %{
             "id" => "provider/unknown-model",
             "name" => "provider/unknown-model",
             "input" => ["text"]
           }

    assert Handbean.LlmDbDefaults.enrich_model("gateway/gpt-5.6-luna", nil, fn ->
             raise ArgumentError, "unknown application: :llm_db"
           end)["input"] == ["text", "image"]
  end

  test "a failed list does not replace saved models" do
    :ok =
      ModelConfig.add_provider("magpie", %{
        "name" => "Magpie",
        "api" => "openai-chat-completions",
        "baseUrl" => "http://127.0.0.1:3425/v1",
        "apiKey" => "magpie",
        "models" => [%{"id" => "kept", "name" => "Kept", "input" => ["text"]}]
      })

    Process.put(:model_catalog_response, {:ok, %{status: 503, body: %{}}})

    assert {:error, message} = ModelCatalog.discover("magpie", req_module: ReqMock)
    assert message =~ "HTTP 503"

    {:ok, config} = ModelConfig.read_config()
    assert [%{"id" => "kept"}] = config["providers"]["magpie"]["models"]
  end

  test "anthropic and non-xAI oauth providers are not fetched from /v1/models" do
    refute ModelCatalog.fetchable?(%{
             "api" => "anthropic-messages",
             "baseUrl" => "http://127.0.0.1:3425"
           })

    refute ModelCatalog.fetchable?(%{
             "api" => "openai-responses",
             "baseUrl" => "http://127.0.0.1:3425",
             "authType" => "oauth"
           })

    assert ModelCatalog.fetchable?(%{
             "api" => "openai-responses",
             "baseUrl" => "https://api.x.ai/v1",
             "authType" => "oauth"
           })
  end

  test "xAI subscription discover pulls /v1/models and refreshes vendor fields" do
    :ok =
      ModelConfig.add_provider("xai", %{
        "name" => "xAI",
        "api" => "openai-responses",
        "baseUrl" => "https://api.x.ai/v1",
        "authType" => "oauth",
        "models" => [
          %{
            "id" => "grok-4.7",
            "name" => "Custom Grok",
            "enabled" => false,
            "input" => ["text"],
            "contextWindow" => 1,
            "cost" => %{"input" => 9, "output" => 9, "cacheRead" => 9}
          },
          %{"id" => "retired", "name" => "Retired", "input" => ["text"]}
        ]
      })

    auth_path =
      Path.join(System.tmp_dir!(), "xai_models_auth_#{System.unique_integer([:positive])}.json")

    previous_auth = System.get_env("HANDBEAN_AUTH_FILE")
    System.put_env("HANDBEAN_AUTH_FILE", auth_path)

    :ok =
      Storage.put("xai", %{
        "type" => "oauth",
        "access" => "oauth-token",
        "refresh" => "refresh",
        "expires" => System.system_time(:millisecond) + 3_600_000
      })

    on_exit(fn ->
      if previous_auth,
        do: System.put_env("HANDBEAN_AUTH_FILE", previous_auth),
        else: System.delete_env("HANDBEAN_AUTH_FILE")

      File.rm(auth_path)
    end)

    assert {:ok, %{added: 1, total: 3}} = ModelCatalog.discover("xai", req_module: XaiReq)

    assert_received {:models_request, "https://api.x.ai/v1/models", opts}
    assert {"authorization", "Bearer oauth-token"} in opts[:headers]
    assert_received {:models_request, "https://api.x.ai/v1/language-models", _language_opts}

    {:ok, config} = ModelConfig.read_config()
    models = config["providers"]["xai"]["models"]
    grok = Enum.find(models, &(&1["id"] == "grok-4.7"))
    older = Enum.find(models, &(&1["id"] == "grok-4.6"))
    retired = Enum.find(models, &(&1["id"] == "retired"))

    assert grok["name"] == "Custom Grok"
    assert grok["enabled"] == false
    assert grok["contextWindow"] == 500_000
    assert grok["cost"]["input"] == 2.0
    assert grok["cost"]["cacheRead"] == 0.5
    assert grok["cost"]["output"] == 6.0
    assert grok["input"] == ["text", "image"]
    assert grok["reasoning"] == true
    assert grok["defaultReasoning"] == "high"
    assert older["contextWindow"] == 500_000
    assert older["cost"]["input"] == 2.0
    refute Enum.any?(models, &(&1["id"] == "grok-imagine-image"))
    assert retired["unavailable"] == true
  end
end

defmodule Handbean.Agent.Provider.ModelCatalogTest.XaiReq do
  def get(url, opts) do
    send(self(), {:models_request, url, opts})

    cond do
      String.ends_with?(url, "/language-models") ->
        {:ok,
         %{
           status: 200,
           body: %{
             "models" => [
               %{
                 "id" => "grok-4.7",
                 "input_modalities" => ["text", "image"],
                 "prompt_text_token_price" => 20_000,
                 "cached_prompt_text_token_price" => 5_000,
                 "completion_text_token_price" => 60_000,
                 "capabilities" => %{
                   "reasoning_effort" => ["low", "medium", "high", "xhigh"],
                   "default_reasoning_effort" => "high"
                 }
               },
               %{
                 "id" => "grok-4.6",
                 "input_modalities" => ["text", "image"],
                 "prompt_text_token_price" => 20_000,
                 "cached_prompt_text_token_price" => 5_000,
                 "completion_text_token_price" => 60_000
               }
             ]
           }
         }}

      true ->
        {:ok,
         %{
           status: 200,
           body: %{
             "object" => "list",
             "data" => [
               %{
                 "id" => "grok-4.7",
                 "object" => "model",
                 "context_length" => 500_000,
                 "prompt_text_token_price" => 20_000,
                 "completion_text_token_price" => 60_000,
                 "cached_prompt_text_token_price" => 5_000
               },
               %{
                 "id" => "grok-4.6",
                 "object" => "model",
                 "context_length" => 500_000,
                 "prompt_text_token_price" => 20_000
               },
               %{
                 "id" => "grok-imagine-image",
                 "object" => "model",
                 "image_price" => 5,
                 "prompt_text_token_price" => nil
               }
             ]
           }
         }}
    end
  end
end
