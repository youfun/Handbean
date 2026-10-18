defmodule Handbean.Agent.Provider.Ollama.ModelsTest do
  use ExUnit.Case, async: false

  alias Handbean.Agent.ModelConfig
  alias Handbean.Agent.Provider.ModelCatalog
  alias Handbean.Agent.Provider.Ollama.Models

  defmodule ReqMock do
    def get(url, opts) do
      send(self(), {:tags_request, url, opts})
      Process.get(:ollama_tags_response)
    end
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "ollama_models_#{System.unique_integer([:positive])}")
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

  test "tags url is the cloud catalog, not the OpenAI models list" do
    assert Models.tags_url("https://ollama.com/v1") == "https://ollama.com/api/tags"
  end

  test "catalog keeps completion models and maps vision and thinking" do
    body = %{
      "models" => [
        %{
          "name" => "gemma4:31b",
          "capabilities" => ["completion", "vision", "thinking", "tools"]
        },
        %{"name" => "clef:27b", "capabilities" => ["decision", "vision"]},
        %{"name" => "gpt-oss:20b", "capabilities" => ["completion", "tools"]}
      ]
    }

    assert {:ok, models} = Models.catalog(body)
    assert Enum.map(models, & &1["id"]) == ["gemma4:31b", "gpt-oss:20b"]

    gemma = Enum.find(models, &(&1["id"] == "gemma4:31b"))
    assert gemma["input"] == ["text", "image"]
    assert gemma["reasoning"] == true

    oss = Enum.find(models, &(&1["id"] == "gpt-oss:20b"))
    assert oss["input"] == ["text"]
    assert oss["reasoning"] == false
  end

  test "discover writes the tags list and keeps an existing enabled flag" do
    :ok =
      ModelConfig.add_provider("ollama", %{
        "name" => "Ollama",
        "api" => "ollama-cloud",
        "provider" => "ollama",
        "baseUrl" => "https://ollama.com/v1",
        "apiKey" => "ollama-test-key",
        "models" => [
          %{
            "id" => "gemma4:31b",
            "name" => "Custom Gemma",
            "enabled" => false,
            "input" => ["text"]
          }
        ]
      })

    Process.put(
      :ollama_tags_response,
      {:ok,
       %{
         status: 200,
         body: %{
           "models" => [
             %{
               "name" => "gemma4:31b",
               "capabilities" => ["completion", "vision", "thinking"]
             },
             %{"name" => "kimi-k2.6", "capabilities" => ["completion", "thinking"]}
           ]
         }
       }}
    )

    assert ModelCatalog.fetchable?(%{
             "api" => "ollama-cloud",
             "baseUrl" => "https://ollama.com/v1"
           })

    assert {:ok, %{added: 1, total: 2}} =
             ModelCatalog.discover("ollama", req_module: ReqMock)

    assert_received {:tags_request, "https://ollama.com/api/tags", opts}

    assert {"authorization", "Bearer ollama-test-key"} =
             List.keyfind(opts[:headers], "authorization", 0)

    {:ok, config} = ModelConfig.read_config()
    models = get_in(config, ["providers", "ollama", "models"])
    gemma = Enum.find(models, &(&1["id"] == "gemma4:31b"))
    assert gemma["name"] == "Custom Gemma"
    assert gemma["enabled"] == false
    assert gemma["input"] == ["text", "image"]
    assert Enum.any?(models, &(&1["id"] == "kimi-k2.6"))
  end
end
