defmodule Handbean.Tool.Builtin.ListModelsTest do
  use ExUnit.Case, async: false

  alias Handbean.Tool.Builtin.ListModels

  setup do
    home = Path.join(System.tmp_dir!(), "list-models-#{Ecto.UUID.generate()}")
    models_path = Path.join(home, "models.json")
    File.mkdir_p!(home)

    File.write!(
      models_path,
      Handbean.JSON.encode!(%{
        "providers" => %{
          "alpha" => %{
            "api" => "openai-chat-completions",
            "baseUrl" => "http://localhost",
            "models" => [
              %{"id" => "small", "name" => "Alpha Small"},
              %{"id" => "large", "name" => "Alpha Large"}
            ]
          },
          "beta" => %{
            "api" => "openai-chat-completions",
            "baseUrl" => "http://localhost",
            "models" => [%{"id" => "coder", "name" => "Beta Coder"}]
          }
        }
      })
    )

    previous = System.get_env("HANDBEAN_MODELS_FILE")
    System.put_env("HANDBEAN_MODELS_FILE", models_path)

    on_exit(fn ->
      if previous,
        do: System.put_env("HANDBEAN_MODELS_FILE", previous),
        else: System.delete_env("HANDBEAN_MODELS_FILE")

      File.rm_rf!(home)
    end)

    context = %{
      workspace_path: home,
      working_directory: home,
      conversation_run_opts: [
        workspace_path: home,
        model: "coder",
        provider_config: %{provider_key: "beta"}
      ]
    }

    %{context: context}
  end

  test "searches allowed models without injecting the whole catalog", %{context: context} do
    assert {:ok, json} = ListModels.execute(%{"query" => "alpha", "limit" => 1}, context)
    result = Handbean.JSON.decode!(json)

    assert result["current"] == "beta/coder"
    assert result["models"] == [%{"id" => "alpha/small", "name" => "Alpha Small"}]
    assert result["next_offset"] == 1

    assert {:ok, json} =
             ListModels.execute(%{"query" => "alpha", "limit" => 1, "offset" => 1}, context)

    result = Handbean.JSON.decode!(json)
    assert result["models"] == [%{"id" => "alpha/large", "name" => "Alpha Large"}]
    assert is_nil(result["next_offset"])
  end

  test "rejects invalid and unknown inputs", %{context: context} do
    assert {:error, "invalid_input"} = ListModels.execute(%{"limit" => 21}, context)
    assert {:error, "invalid_input"} = ListModels.execute(%{"provider" => "alpha"}, context)
  end
end
