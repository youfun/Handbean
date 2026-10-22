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

    %{dir: dir}
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

  test "refresh replaces upstream facts, preserves enabled, and marks missing rows" do
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
             %{
               "id" => "openai/gpt-4o-mini",
               "object" => "model",
               "display_name" => "Remote mini",
               "context_length" => 256_000,
               "max_tokens" => 32_000,
               "input_modalities" => ["text", "image"],
               "capabilities" => %{
                 "reasoning" => true,
                 "reasoning_effort" => ["low", "high"],
                 "default_reasoning_effort" => "high"
               }
             },
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

    assert mini["name"] == "Remote mini"
    assert mini["enabled"] == false
    assert mini["contextWindow"] == 256_000
    assert mini["maxTokens"] == 32_000
    assert mini["input"] == ["text", "image"]
    assert mini["reasoning"] == true
    assert mini["reasoningLevels"] == ["low", "high"]
    assert mini["defaultReasoning"] == "high"
    assert mini["upstream"]["display_name"] == "Remote mini"
    assert deepseek["name"] == "DeepSeek Chat"
    refute Map.has_key?(deepseek, "contextWindow")
    assert gone["unavailable"] == true
  end

  test "ZenMux 1017 uses provider-specific llm_db reasoning options missing upstream" do
    :ok =
      ModelConfig.add_provider("deepseek-z", %{
        "name" => "deepseek-z",
        "provider" => "deepseek-z",
        "api" => "openai-responses",
        "baseUrl" => "https://zenmux.ai/api/v1/responses",
        "apiKey" => "zenmux-key",
        "models" => []
      })

    Process.put(
      :model_catalog_response,
      {:ok,
       %{
         status: 200,
         body: %{
           "data" => [
             %{
               "id" => "deepseek/deepseek-v4.1-flash",
               "object" => "model",
               "display_name" => "DeepSeek: DeepSeek V4.1 Flash 1017",
               "owned_by" => "deepseek",
               "publish_time" => "2026-10-17",
               "context_length" => 1_000_000,
               "max_tokens" => 384_000,
               "input_modalities" => ["image", "text"],
               "output_modalities" => ["text"],
               "capabilities" => %{"reasoning" => true}
             },
             %{
               "id" => "future/video-model",
               "input_modalities" => ["text", "video"]
             }
           ]
         }
       }}
    )

    assert {:ok, %{added: 2, total: 2}} =
             ModelCatalog.discover("deepseek-z", req_module: ReqMock)

    {:ok, config} = ModelConfig.read_config()
    models = config["providers"]["deepseek-z"]["models"]
    model = Enum.find(models, &(&1["id"] == "deepseek/deepseek-v4.1-flash"))
    video_model = Enum.find(models, &(&1["id"] == "future/video-model"))

    assert model["id"] == "deepseek/deepseek-v4.1-flash"
    assert model["name"] == "DeepSeek: DeepSeek V4.1 Flash 1017"
    assert model["reasoning"] == true
    assert model["reasoningLevels"] == ["none", "low", "high", "max"]
    assert model["contextWindow"] == 1_000_000
    assert model["maxTokens"] == 384_000
    assert model["upstream"]["publish_time"] == "2026-10-17"
    assert video_model["input"] == ["text"]
    assert video_model["upstream"]["input_modalities"] == ["text", "video"]

    assert Handbean.Agent.Reasoning.supported_levels(model) == [
             "off",
             "none",
             "low",
             "high",
             "max"
           ]
  end

  test "remote API base URLs resolve to their llm_db provider without using the local id" do
    assert Handbean.LlmDbDefaults.resolve_provider_id(
             "custom-router",
             "Custom Router",
             "https://openrouter.ai/api/v1/chat/completions"
           ) == "openrouter"

    assert Handbean.LlmDbDefaults.resolve_provider_id(
             "custom-zenmux",
             "Custom ZenMux",
             "https://zenmux.ai/api/v1/responses"
           ) == "zenmux"
  end

  test "normalizes provider-declared facts without inventing reasoning levels" do
    assert ModelCatalog.normalize_entry(%{
             "id" => "future/model",
             "display_name" => "Future Model",
             "input_modalities" => ["text", "audio", "video"],
             "output_modalities" => ["text"],
             "context_length" => 1_000_000,
             "max_tokens" => 128_000,
             "pricings" => %{
               "prompt" => [
                 %{"value" => 0.1, "unit" => "perMTokens"},
                 %{"value" => 0.2, "unit" => "perMTokens"}
               ],
               "completion" => [%{"value" => 0.8, "unit" => "perMTokens"}]
             },
             "capabilities" => %{"reasoning" => true}
           }) == %{
             "id" => "future/model",
             "name" => "Future Model",
             "input" => ["text", "audio"],
             "output" => ["text"],
             "contextWindow" => 1_000_000,
             "maxTokens" => 128_000,
             "cost" => %{"input" => 0.2, "output" => 0.8},
             "reasoning" => true,
             "upstream" => %{
               "id" => "future/model",
               "display_name" => "Future Model",
               "input_modalities" => ["text", "audio", "video"],
               "output_modalities" => ["text"],
               "context_length" => 1_000_000,
               "max_tokens" => 128_000,
               "pricings" => %{
                 "prompt" => [
                   %{"value" => 0.1, "unit" => "perMTokens"},
                   %{"value" => 0.2, "unit" => "perMTokens"}
                 ],
                 "completion" => [%{"value" => 0.8, "unit" => "perMTokens"}]
               },
               "capabilities" => %{"reasoning" => true}
             }
           }
  end

  test "upstream reasoning levels replace fallback mappings and reject an invalid fallback default" do
    model =
      ModelCatalog.normalize_entry(
        %{
          "id" => "future/reasoner",
          "capabilities" => %{"reasoning" => true, "reasoning_effort" => ["low", "high"]}
        },
        %{
          "id" => "future/reasoner",
          "reasoning" => true,
          "reasoningLevels" => ["minimal", "medium"],
          "defaultReasoning" => "medium",
          "thinkingLevelMap" => %{"minimal" => "low"}
        }
      )

    assert model["reasoning"] == true
    assert model["reasoningLevels"] == ["low", "high"]
    refute Map.has_key?(model, "defaultReasoning")
    refute Map.has_key?(model, "thinkingLevelMap")
  end

  test "prefers nested provider limits over llm_db fallback" do
    model =
      ModelCatalog.normalize_entry(
        %{
          "id" => "gateway/model",
          "top_provider" => %{
            "context_length" => 300_000,
            "max_completion_tokens" => 64_000
          }
        },
        %{"id" => "gateway/model", "contextWindow" => 128_000, "maxTokens" => 8_192}
      )

    assert model["contextWindow"] == 300_000
    assert model["maxTokens"] == 64_000
  end

  test "does not invent text input for an upstream audio-only model" do
    model =
      ModelCatalog.normalize_entry(
        %{"id" => "audio-only", "input_modalities" => ["audio"]},
        %{"id" => "audio-only", "input" => ["text"]}
      )

    assert model["input"] == ["audio"]
    assert model["upstream"]["input_modalities"] == ["audio"]
  end

  test "keeps unsupported-only input in upstream without an invalid projection" do
    model =
      ModelCatalog.normalize_entry(
        %{"id" => "video-only", "input_modalities" => ["video"]},
        %{"id" => "video-only", "input" => ["text"]}
      )

    refute Map.has_key?(model, "input")
    assert model["upstream"]["input_modalities"] == ["video"]
  end

  test "account-scoped refresh drops missing rows and preserves only enabled" do
    existing = [
      %{"id" => "kept", "name" => "Old", "contextWindow" => 1, "enabled" => false},
      %{"id" => "gone", "enabled" => true}
    ]

    remote = [
      %{
        "id" => "kept",
        "name" => "Current",
        "contextWindow" => 200_000,
        "upstream" => %{"id" => "kept"}
      }
    ]

    assert ModelCatalog.refresh_merge(existing, remote, missing: :drop) == [
             %{
               "id" => "kept",
               "name" => "Current",
               "contextWindow" => 200_000,
               "enabled" => false,
               "upstream" => %{"id" => "kept"}
             }
           ]
  end

  test "unknown remote APIs reuse intrinsic model capabilities but not supplier facts" do
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

    luna = Enum.find(models, &(&1["id"] == "gpt-5.6-luna"))
    assert luna["input"] == ["text", "image"]
    refute Map.has_key?(luna, "contextWindow")
    refute Map.has_key?(luna, "maxTokens")
    refute Map.has_key?(luna, "cost")

    assert Enum.find(models, &(&1["id"] == "direct-vision"))["input"] == ["text", "image"]

    assert Enum.find(models, &(&1["id"] == "openrouter-vision"))["input"] == [
             "text",
             "image",
             "audio"
           ]

    refute Map.has_key?(Enum.find(models, &(&1["id"] == "unknown-model")), "input")
  end

  test "provider-scoped discovery keeps remote rows when llm_db cannot load" do
    :ok =
      ModelConfig.add_provider("remote-only", %{
        "name" => "Remote only",
        "api" => "openai-responses",
        "baseUrl" => "https://unknown.example/v1/responses",
        "apiKey" => "remote-key",
        "models" => []
      })

    Process.put(
      :model_catalog_response,
      {:ok,
       %{
         status: 200,
         body: %{
           "data" => [
             %{
               "id" => "future/model",
               "display_name" => "Future Remote Model",
               "capabilities" => %{"reasoning" => true}
             }
           ]
         }
       }}
    )

    assert {:ok, %{added: 1, total: 1}} =
             ModelCatalog.discover("remote-only",
               req_module: ReqMock,
               llm_db_load: fn -> raise ArgumentError, "unknown application: :llm_db" end
             )

    {:ok, config} = ModelConfig.read_config()
    [model] = config["providers"]["remote-only"]["models"]

    assert model["name"] == "Future Remote Model"
    assert model["reasoning"] == true
    refute Map.has_key?(model, "reasoningLevels")
    assert model["upstream"]["id"] == "future/model"
  end

  test "Chat Completions does not turn an llm_db toggle into the Responses none effort" do
    model =
      Handbean.LlmDbDefaults.enrich_models(
        [{"deepseek/deepseek-v4.1-flash", nil}],
        provider_id: "zenmux",
        api: "openai-chat-completions",
        provider_scoped: true
      )["deepseek/deepseek-v4.1-flash"]

    assert model["reasoningLevels"] == ["low", "high", "max"]
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

  test "a malformed provider Base URL is rejected before the request and keeps saved models" do
    :ok =
      ModelConfig.add_provider("magpie", %{
        "name" => "Magpie",
        "api" => "openai-chat-completions",
        "baseUrl" => "https://example.com/v1\n，https://other.example/v1",
        "apiKey" => "magpie",
        "models" => [%{"id" => "kept", "name" => "Kept", "input" => ["text"]}]
      })

    assert {:error, message} = ModelCatalog.discover("magpie", req_module: ReqMock)
    assert message =~ "Base URL is invalid"
    refute_received {:models_request, _, _}

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

  test "xAI subscription discover pulls /v1/models and refreshes vendor fields", %{dir: dir} do
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

    auth_path = Path.join(dir, "auth.json")

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

    assert grok["name"] == "Grok 4.7"
    assert grok["enabled"] == false
    assert grok["contextWindow"] == 500_000
    assert grok["cost"]["input"] == 2.0
    assert grok["cost"]["cacheRead"] == 0.5
    assert grok["cost"]["output"] == 6.0
    assert grok["input"] == ["text", "image"]
    assert grok["reasoning"] == true
    assert grok["defaultReasoning"] == "high"
    assert grok["upstream"]["models"]["context_length"] == 500_000

    assert grok["upstream"]["languageModels"]["capabilities"]["reasoning_effort"] ==
             ["low", "medium", "high", "xhigh"]

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
