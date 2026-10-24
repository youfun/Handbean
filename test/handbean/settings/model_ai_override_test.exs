defmodule Handbean.Settings.ModelAIOverrideTest do
  use ExUnit.Case, async: false

  alias Handbean.Settings
  alias Handbean.Settings.{ModelAIOverride, ModelAISettings}

  @env ~w(HANDBEAN_GLOBAL_SETTINGS_FILE)

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "sigil_model_ai_override_#{System.unique_integer([:positive])}"
      )

    ws = Path.join(dir, "ws")
    File.mkdir_p!(ws)
    previous = Map.new(@env, &{&1, System.get_env(&1)})
    System.put_env("HANDBEAN_GLOBAL_SETTINGS_FILE", Path.join(dir, "settings.json"))

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)

      File.rm_rf!(dir)
    end)

    %{ws: ws}
  end

  test "save :global writes the full form; workspace save stores only the diff", %{ws: ws} do
    global = %{ModelAISettings.defaults() | default_model: "a/one", reasoning: "high"}
    assert :ok = ModelAIOverride.save(:global, global)
    assert Settings.global_model_ai().default_model == "a/one"

    assert :ok = ModelAIOverride.save({:workspace, ws}, %{global | reasoning: "low"})
    {:ok, raw} = Settings.load_workspace_model_ai(ws)
    assert raw == %{"reasoning" => "low"}

    assert ModelAIOverride.sources(ws) |> Map.take([:default_model, :reasoning]) ==
             %{default_model: :global, reasoning: :workspace}
  end

  test "inherit clears named fields; inherit_all clears everything", %{ws: ws} do
    global = %{ModelAISettings.defaults() | default_model: "a/one", reasoning: "high"}
    :ok = ModelAIOverride.save(:global, global)

    :ok =
      ModelAIOverride.save({:workspace, ws}, %{global | default_model: "b/two", reasoning: "low"})

    assert :ok = ModelAIOverride.inherit(ws, [:default_model])
    {:ok, raw} = Settings.load_workspace_model_ai(ws)
    assert raw == %{"reasoning" => "low"}
    assert Settings.effective_model_ai(ws).default_model == "a/one"

    assert :ok = ModelAIOverride.inherit_all(ws)
    assert {:ok, %{}} = Settings.load_workspace_model_ai(ws)
    assert Settings.effective_model_ai(ws).reasoning == "high"
  end

  test "advisor model and reasoning inherit and override together", %{ws: ws} do
    global = %{
      ModelAISettings.defaults()
      | advisor_mode: :custom,
        advisor_model: "provider/global-advisor",
        advisor_reasoning: "high"
    }

    assert :ok = ModelAIOverride.save(:global, global)

    assert {:ok, %{model: "provider/global-advisor", reasoning: "high", source: :global}} =
             Settings.advisor_resolution(ws)

    workspace = %{
      global
      | advisor_mode: :custom,
        advisor_model: "provider/workspace-advisor",
        advisor_reasoning: "low"
    }

    assert :ok = ModelAIOverride.save({:workspace, ws}, workspace)

    assert {:ok, %{model: "provider/workspace-advisor", reasoning: "low", source: :workspace}} =
             Settings.advisor_resolution(ws)
  end

  test "subagent model inherits, overrides, and can follow the parent run", %{ws: ws} do
    global = %{
      ModelAISettings.defaults()
      | subagent_mode: :custom,
        subagent_model: "provider/global-subagent",
        subagent_reasoning: "high"
    }

    assert :ok = ModelAIOverride.save(:global, global)

    assert {:ok, %{model: "provider/global-subagent", reasoning: "high", source: :global}} =
             Settings.subagent_resolution(ws)

    workspace = %{
      global
      | subagent_mode: :custom,
        subagent_model: "provider/workspace-subagent",
        subagent_reasoning: "low"
    }

    assert :ok = ModelAIOverride.save({:workspace, ws}, workspace)

    assert {:ok, %{model: "provider/workspace-subagent", reasoning: "low", source: :workspace}} =
             Settings.subagent_resolution(ws)

    assert :ok = ModelAIOverride.save({:workspace, ws}, %{workspace | subagent_mode: :parent})
    assert Settings.subagent_resolution(ws) == :inherit
  end

  test "workspace can reset the global memory model and think level to their defaults", %{ws: ws} do
    global = %{
      ModelAISettings.defaults()
      | om_model: "provider/memory-model",
        om_reasoning: "high"
    }

    assert :ok = ModelAIOverride.save(:global, global)

    assert :ok =
             ModelAIOverride.save({:workspace, ws}, %{global | om_model: nil, om_reasoning: nil})

    assert {:ok,
            %{
              "observational_memory" => %{
                "model" => nil,
                "reasoning" => nil
              }
            }} = Settings.load_workspace_model_ai(ws)

    effective = Settings.effective_model_ai(ws)
    assert effective.om_model == nil
    assert effective.om_reasoning == nil
  end

  test "sources treats an unreadable workspace file as no overrides", %{ws: ws} do
    path = Handbean.WorkspaceSettings.path(ws)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "{ broken")

    sources = ModelAIOverride.sources(ws)

    assert sources
           |> Map.drop([:advisor, :subagent])
           |> Enum.all?(fn {_field, source} -> source == :global end)

    assert sources.advisor == :none
    assert sources.subagent == :inherit

    assert Map.keys(sources) |> Enum.sort() ==
             Enum.sort([:advisor, :subagent | ModelAISettings.fields()])
  end
end
