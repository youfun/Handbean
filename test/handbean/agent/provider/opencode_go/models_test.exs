defmodule Handbean.Agent.Provider.OpenCodeGo.ModelsTest do
  use ExUnit.Case, async: false

  alias Handbean.Agent.ModelConfig
  alias Handbean.Agent.Provider.ModelCatalog
  alias Handbean.Agent.Provider.OpenCodeGo.Models
  alias Handbean.Agent.Provider.RequestIdentity

  defmodule ReqMock do
    def get(url, opts) do
      send(self(), {:models_request, url, opts})
      Process.get(:opencode_go_models_response)
    end
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "opencode_go_models_#{System.unique_integer([:positive])}")
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

  test "models url is the Go subscription list" do
    assert Models.models_url("https://opencode.ai/zen/go/v1") ==
             "https://opencode.ai/zen/go/v1/models"
  end

  test "catalog keeps returned ids and skips blanks" do
    body = %{
      "data" => [
        %{"id" => "glm-5.3-flash"},
        %{"id" => ""},
        %{"id" => "gpt-6-luna"},
        %{"id" => "glm-5.3-flash"}
      ]
    }

    assert {:ok, models} = Models.catalog(body)
    assert Enum.map(models, & &1["id"]) == ["glm-5.3-flash", "gpt-6-luna"]
  end

  test "discover writes the live list and keeps a custom name and enabled flag" do
    :ok =
      ModelConfig.add_provider("opencode-go", %{
        "name" => "OpenCode Go",
        "api" => "opencode-go",
        "provider" => "opencode-go",
        "baseUrl" => "https://opencode.ai/zen/go/v1",
        "apiKey" => "go-test-key",
        "models" => [
          %{
            "id" => "glm-5.3-flash",
            "name" => "Custom GLM",
            "enabled" => false,
            "contextWindow" => 200_000
          },
          %{"id" => "retired-model", "name" => "Retired"}
        ]
      })

    Process.put(
      :opencode_go_models_response,
      {:ok,
       %{
         status: 200,
         body: %{"data" => [%{"id" => "glm-5.3-flash"}, %{"id" => "gpt-6-luna"}]}
       }}
    )

    assert ModelCatalog.fetchable?(%{
             "api" => "opencode-go",
             "baseUrl" => "https://opencode.ai/zen/go/v1"
           })

    assert {:ok, %{added: 1, total: 3}} =
             ModelCatalog.discover("opencode-go", req_module: ReqMock)

    assert_received {:models_request, "https://opencode.ai/zen/go/v1/models", opts}

    assert {"authorization", "Bearer go-test-key"} =
             List.keyfind(opts[:headers], "authorization", 0)

    assert {"user-agent", user_agent} = List.keyfind(opts[:headers], "user-agent", 0)
    assert user_agent == RequestIdentity.user_agent()

    {:ok, config} = ModelConfig.read_config()
    models = get_in(config, ["providers", "opencode-go", "models"])
    glm = Enum.find(models, &(&1["id"] == "glm-5.3-flash"))
    assert glm["name"] == "Custom GLM"
    assert glm["enabled"] == false
    assert glm["contextWindow"] == 200_000
    assert Enum.any?(models, &(&1["id"] == "gpt-6-luna"))

    retired = Enum.find(models, &(&1["id"] == "retired-model"))
    assert retired["unavailable"] == true
  end

  test "a failed list does not replace the saved rows" do
    :ok =
      ModelConfig.add_provider("opencode-go", %{
        "name" => "OpenCode Go",
        "api" => "opencode-go",
        "provider" => "opencode-go",
        "baseUrl" => "https://opencode.ai/zen/go/v1",
        "apiKey" => "go-test-key",
        "models" => [%{"id" => "glm-5.3-flash", "name" => "GLM"}]
      })

    Process.put(:opencode_go_models_response, {:ok, %{status: 401, body: %{}}})

    assert {:error, message} = ModelCatalog.discover("opencode-go", req_module: ReqMock)
    assert message =~ "existing list was kept"

    {:ok, config} = ModelConfig.read_config()
    assert [%{"id" => "glm-5.3-flash", "name" => "GLM"}] =
             get_in(config, ["providers", "opencode-go", "models"])
  end
end
