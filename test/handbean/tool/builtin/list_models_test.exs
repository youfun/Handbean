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

    previous =
      Map.new(~w(HANDBEAN_MODELS_FILE HANDBEAN_WORKSPACES_FILE), &{&1, System.get_env(&1)})

    System.put_env("HANDBEAN_MODELS_FILE", models_path)
    System.put_env("HANDBEAN_WORKSPACES_FILE", Path.join(home, "workspaces.json"))

    on_exit(fn ->
      for {key, value} <- previous,
          do: if(value, do: System.put_env(key, value), else: System.delete_env(key))

      File.rm_rf!(home)
    end)

    context = %{
      workspace_id: "source-workspace",
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

    assert result["models"] == [
             %{
               "id" => "alpha/small",
               "name" => "Alpha Small",
               "reasoning_levels" => [],
               "default_reasoning_level" => "off"
             }
           ]

    assert result["next_offset"] == 1

    assert {:ok, json} =
             ListModels.execute(%{"query" => "alpha", "limit" => 1, "offset" => 1}, context)

    result = Handbean.JSON.decode!(json)

    assert result["models"] == [
             %{
               "id" => "alpha/large",
               "name" => "Alpha Large",
               "reasoning_levels" => [],
               "default_reasoning_level" => "off"
             }
           ]

    assert is_nil(result["next_offset"])
  end

  test "lists an exact authorized target workspace without exposing credentials", %{
    context: context
  } do
    target_path = Path.join(context.workspace_path, "target")
    File.mkdir_p!(target_path)
    {:ok, target} = Handbean.WorkspaceStore.add(target_path, name: "Target")

    settings_path = Handbean.WorkspaceSettings.path(target_path)
    File.mkdir_p!(Path.dirname(settings_path))

    File.write!(
      settings_path,
      Handbean.JSON.encode!(%{
        "models" => %{
          "version" => 1,
          "default" => %{"provider" => "beta", "model" => "coder"},
          "allow" => %{"providers" => %{"beta" => %{"models" => ["coder"]}}}
        }
      })
    )

    assert {:error, "not_accessible"} =
             ListModels.execute(%{"workspace" => target["id"]}, context)

    assert {:ok, json} =
             ListModels.execute(
               %{"workspace" => target["id"]},
               Map.put(context, :approval_mode, :yolo)
             )

    result = Handbean.JSON.decode!(json)
    assert result["workspace"] == target["id"]
    assert result["default"] == "beta/coder"
    assert is_nil(result["current"])
    assert [%{"id" => "beta/coder"} = model] = result["models"]
    refute Map.has_key?(model, "apiKey")
    refute Map.has_key?(model, "baseUrl")
  end

  test "rejects invalid and unknown inputs", %{context: context} do
    assert {:error, "invalid_input"} = ListModels.execute(%{"limit" => 21}, context)
    assert {:error, "invalid_input"} = ListModels.execute(%{"provider" => "alpha"}, context)
  end
end
