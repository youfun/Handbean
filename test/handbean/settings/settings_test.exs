defmodule Handbean.SettingsTest do
  use ExUnit.Case, async: true

  alias Handbean.Settings
  alias Handbean.Settings.ModelAISettings

  @tmp_base Path.join(System.tmp_dir!(), "handbean_settings_test_#{System.unique_integer()}")

  setup do
    global_dir = Path.join(@tmp_base, "global")
    ws_dir = Path.join(@tmp_base, "workspace")
    File.mkdir_p!(global_dir)

    on_exit(fn ->
      File.rm_rf!(@tmp_base)
    end)

    {:ok, global_dir: global_dir, ws_dir: ws_dir}
  end

  describe "global settings" do
    test "load_global returns empty map when file does not exist", %{global_dir: global_dir} do
      assert {:ok, %{}} = Settings.load_global(global_dir: global_dir)
    end

    test "load_global returns parsed JSON when file exists", %{global_dir: global_dir} do
      file = Path.join(global_dir, "settings.json")
      File.write!(file, Jason.encode!(%{"model_ai" => %{"default_model" => "claude-sonnet-4"}}))

      assert {:ok, %{"model_ai" => %{"default_model" => "claude-sonnet-4"}}} =
               Settings.load_global(global_dir: global_dir)
    end

    test "load_global handles malformed JSON gracefully", %{global_dir: global_dir} do
      file = Path.join(global_dir, "settings.json")
      File.write!(file, "{not json}")

      assert {:ok, %{}} = Settings.load_global(global_dir: global_dir)
    end

    test "save_global creates file with model_ai section", %{global_dir: global_dir} do
      model_ai = %{"default_model" => "claude-sonnet-4", "reasoning" => "medium"}
      assert :ok = Settings.save_global(model_ai, global_dir: global_dir)

      file = Path.join(global_dir, "settings.json")
      assert File.exists?(file)

      {:ok, content} = File.read(file)
      parsed = Jason.decode!(content)
      assert parsed["model_ai"]["default_model"] == "claude-sonnet-4"
      assert parsed["model_ai"]["reasoning"] == "medium"
    end

    test "save_global preserves existing non-model_ai keys", %{global_dir: global_dir} do
      file = Path.join(global_dir, "settings.json")
      File.write!(file, Jason.encode!(%{"ui" => %{"theme" => "dark"}}))

      assert :ok =
               Settings.save_global(%{"default_model" => "claude-sonnet-4"},
                 global_dir: global_dir
               )

      {:ok, content} = File.read(file)
      parsed = Jason.decode!(content)
      assert parsed["ui"]["theme"] == "dark"
      assert parsed["model_ai"]["default_model"] == "claude-sonnet-4"
    end
  end

  describe "workspace model_ai settings" do
    test "load_workspace_model_ai returns empty map when settings file does not exist" do
      ws_root = Path.join(@tmp_base, "workspace_without_settings")
      File.mkdir_p!(ws_root)

      assert {:ok, %{}} = Settings.load_workspace_model_ai(ws_root)
    end

    test "load_workspace_model_ai returns model_ai section from settings.jsonc", %{ws_dir: ws_dir} do
      sigil_dir = Path.join(ws_dir, ".handbean")
      File.mkdir_p!(sigil_dir)

      content = ~s|{"model_ai": {"default_model": "claude-opus", "om_enabled": true}}|
      File.write!(Path.join(sigil_dir, "settings.jsonc"), content)

      assert {:ok, %{"default_model" => "claude-opus", "om_enabled" => true}} =
               Settings.load_workspace_model_ai(ws_dir)
    end

    test "load_workspace_model_ai handles JSONC with comments", %{ws_dir: ws_dir} do
      sigil_dir = Path.join(ws_dir, ".handbean")
      File.mkdir_p!(sigil_dir)

      content = """
      {
        // workspace model settings
        "model_ai": {
          "default_model": "local-llama"
        }
      }
      """

      File.write!(Path.join(sigil_dir, "settings.jsonc"), content)

      assert {:ok, %{"default_model" => "local-llama"}} =
               Settings.load_workspace_model_ai(ws_dir)
    end

    test "save_workspace_model_ai creates .handbean directory for an existing workspace" do
      ws_root = Path.join(@tmp_base, "fresh_ws")
      File.mkdir_p!(ws_root)

      assert :ok =
               Settings.save_workspace_model_ai(ws_root, %{"default_model" => "claude-sonnet-4"})

      sigil_dir = Path.join(ws_root, ".handbean")
      assert File.dir?(sigil_dir)
      assert File.exists?(Path.join(sigil_dir, "settings.jsonc"))
    end

    test "save_workspace_model_ai preserves existing non-model_ai sections", %{ws_dir: ws_dir} do
      sigil_dir = Path.join(ws_dir, ".handbean")
      File.mkdir_p!(sigil_dir)

      original_content = """
      {
        "tools": {
          "default_mode": "prompt"
        }
      }
      """

      File.write!(Path.join(sigil_dir, "settings.jsonc"), original_content)

      assert :ok =
               Settings.save_workspace_model_ai(ws_dir, %{"default_model" => "claude-sonnet-4"})

      {:ok, reloaded} = Settings.load_workspace(ws_dir)
      assert reloaded["tools"]["default_mode"] == "prompt"
      assert reloaded["model_ai"]["default_model"] == "claude-sonnet-4"
    end
  end

  describe "effective_model_ai/1" do
    test "workspace diff does not reset global settings", %{global_dir: global_dir} do
      Settings.save_global(
        %{
          "reasoning" => "medium",
          "observational_memory" => %{"memory_scope" => "both"}
        },
        global_dir: global_dir
      )

      ws_root = Path.join(@tmp_base, "ws_diff")
      File.mkdir_p!(ws_root)
      Settings.save_workspace_model_ai(ws_root, %{"default_model" => "local-llama"})

      effective = Settings.effective_model_ai(ws_root, global_dir: global_dir)
      assert effective.default_model == "local-llama"
      assert effective.reasoning == "medium"
      assert effective.om_memory_scope == "both"
    end

    test "returns defaults when no global or workspace settings exist" do
      ws_root = Path.join(@tmp_base, "empty_ws")
      File.mkdir_p!(ws_root)

      effective = Settings.effective_model_ai(ws_root, global_dir: @tmp_base)
      assert effective == ModelAISettings.defaults()
    end

    test "legacy global enablement is ignored", %{global_dir: global_dir} do
      Settings.save_global(
        %{"default_model" => "claude-sonnet-4", "om_enabled" => true},
        global_dir: global_dir
      )

      ws_root = Path.join(@tmp_base, "empty_ws")
      File.mkdir_p!(ws_root)

      effective = Settings.effective_model_ai(ws_root, global_dir: global_dir)
      assert effective.default_model == "claude-sonnet-4"
      refute Map.has_key?(Map.from_struct(effective), :om_enabled)
      assert effective.reasoning == "medium"
    end

    test "workspace settings override global", %{global_dir: global_dir} do
      Settings.save_global(
        %{"default_model" => "claude-sonnet-4", "reasoning" => "medium"},
        global_dir: global_dir
      )

      ws_root = Path.join(@tmp_base, "ws")
      File.mkdir_p!(ws_root)
      Settings.save_workspace_model_ai(ws_root, %{"default_model" => "local-llama"})

      effective = Settings.effective_model_ai(ws_root, global_dir: global_dir)
      # workspace override wins for default_model
      assert effective.default_model == "local-llama"
      # reasoning is only in global, so it comes through
      assert effective.reasoning == "medium"
    end

    test "workspace with no model_ai section falls through to global", %{global_dir: global_dir} do
      Settings.save_global(
        %{"default_model" => "claude-sonnet-4"},
        global_dir: global_dir
      )

      ws_root = Path.join(@tmp_base, "ws")
      File.mkdir_p!(ws_root)

      # Create settings.jsonc without model_ai section
      sigil_dir = Path.join(ws_root, ".handbean")
      File.mkdir_p!(sigil_dir)

      File.write!(
        Path.join(sigil_dir, "settings.jsonc"),
        ~s|{"tools": {"default_mode": "prompt"}}|
      )

      effective = Settings.effective_model_ai(ws_root, global_dir: global_dir)
      assert effective.default_model == "claude-sonnet-4"
    end
  end
end
