defmodule Handbean.WorkspaceSettingsTest do
  use ExUnit.Case, async: true

  alias Handbean.Security.PathValidator
  alias Handbean.WorkspaceSettings

  defp tmp_workspace do
    dir =
      Path.join(
        System.tmp_dir!(),
        "sigil_workspace_settings_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)

    on_exit(fn -> File.rm_rf(dir) end)

    dir
  end

  defp write_settings(workspace, content) do
    path = WorkspaceSettings.path(workspace)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end

  describe "built-in memory" do
    test "defaults to enabled when the workspace has no setting" do
      workspace = tmp_workspace()

      assert WorkspaceSettings.builtin_memory_enabled(workspace)
      assert WorkspaceSettings.builtin_memory_enabled_from_settings(%{})
    end

    test "writes an explicit workspace value and preserves JSONC comments" do
      workspace = tmp_workspace()

      write_settings(workspace, """
      {
        // keep this project note
        "tools": {"default_mode": "auto"}
      }
      """)

      assert :ok = WorkspaceSettings.update_builtin_memory_enabled(workspace, false)
      refute WorkspaceSettings.builtin_memory_enabled(workspace)
      assert File.read!(WorkspaceSettings.path(workspace)) =~ "// keep this project note"

      assert :ok = WorkspaceSettings.update_builtin_memory_enabled(workspace, true)
      assert WorkspaceSettings.builtin_memory_enabled(workspace)

      assert get_in(elem(WorkspaceSettings.load(workspace), 1), ["tools", "default_mode"]) ==
               "auto"
    end

    test "fails closed when workspace settings cannot be read" do
      workspace = tmp_workspace()
      write_settings(workspace, ~s({"memory": ))

      refute WorkspaceSettings.builtin_memory_enabled(workspace)
    end
  end

  test "settings read-modify-write updates fail closed on malformed or non-object JSONC" do
    workspace = tmp_workspace()

    for original <- [~s({"tools": ), ~s([{"default_mode":"prompt"}])],
        update <- [
          fn -> WorkspaceSettings.update_builtin_memory_enabled(workspace, false) end,
          fn -> WorkspaceSettings.update_permission_mode(workspace, :auto_review) end
        ] do
      write_settings(workspace, original)
      assert {:error, reason} = update.()
      assert reason =~ "Failed to parse"
      assert File.read!(WorkspaceSettings.path(workspace)) == original
    end
  end

  test "maps an aborted global transaction into the settings error contract" do
    assert WorkspaceSettings.normalize_transaction_result(:aborted) ==
             {:error, "Failed to acquire workspace settings lock"}

    assert WorkspaceSettings.normalize_transaction_result(:ok) == :ok
  end

  test "permission modes replace both execution policy and reviewer on every switch" do
    workspace = tmp_workspace()

    for {mode, default_mode, reviewer} <- [
          {:yolo, "yolo", "user"},
          {:auto_review, "auto", "auto_review"},
          {:prompt, "prompt", "user"},
          {:auto_review, "auto", "auto_review"}
        ] do
      assert :ok = WorkspaceSettings.update_permission_mode(workspace, mode)
      assert WorkspaceSettings.permission_mode(workspace) == mode
      assert {:ok, settings} = WorkspaceSettings.load(workspace)
      assert get_in(settings, ["tools", "default_mode"]) == default_mode
      assert get_in(settings, ["tools", "approvals_reviewer"]) == reviewer
    end
  end

  test "permission mode update preserves comments and specific tool rules" do
    workspace = tmp_workspace()

    write_settings(workspace, """
    {
      // keep workspace rules
      "tools": {
        "default_mode": "yolo",
        "per_tool": {"bash": "prompt"},
        "deny": ["secret"]
      }
    }
    """)

    assert :ok = WorkspaceSettings.update_permission_mode(workspace, :auto_review)
    assert File.read!(WorkspaceSettings.path(workspace)) =~ "// keep workspace rules"
    assert {:ok, settings} = WorkspaceSettings.load(workspace)
    assert get_in(settings, ["tools", "per_tool"]) == %{"bash" => "prompt"}
    assert get_in(settings, ["tools", "deny"]) == ["secret"]
  end

  test "new workspace settings use smart approval" do
    workspace = tmp_workspace()
    assert :ok = WorkspaceSettings.ensure_file(workspace)
    assert WorkspaceSettings.permission_mode(workspace) == :auto_review
    assert WorkspaceSettings.approvals_reviewer(workspace) == :auto_review
  end

  test "path points at workspace .handbean/settings.jsonc" do
    workspace = tmp_workspace()

    expected =
      workspace
      |> Path.join(".handbean/settings.jsonc")
      |> PathValidator.resolve_symlink()

    assert WorkspaceSettings.path(workspace) == expected
  end

  test "missing settings file loads as empty unrestricted settings" do
    workspace = tmp_workspace()
    assert WorkspaceSettings.load(workspace) == {:ok, %{}}
    assert WorkspaceSettings.models_policy(workspace) == :unrestricted

    assert WorkspaceSettings.beam_tools_config(workspace) == %{
             auto: true,
             eval: false,
             explicit: []
           }
  end

  test "parses JSONC comments and trailing commas" do
    workspace = tmp_workspace()

    write_settings(workspace, """
    {
      // models are workspace-local restrictions
      "models": {
        "default": {
          "provider": "local",
          "model": "qwen",
        },
        "allow": {
          "providers": {
            "local": {
              "models": ["qwen",],
            },
          },
        },
      },
      /*
       * BEAM tools are controlled separately from models.
       */
      "tools": {
        "beam": {
          "auto": false,
          "eval": true,
        },
        "explicit": ["ext__beam__eval",],
      },
    }
    """)

    assert {:ok, settings} = WorkspaceSettings.load(workspace)
    assert get_in(settings, ["models", "default", "model"]) == "qwen"
    assert get_in(settings, ["models", "allow", "providers", "local", "models"]) == ["qwen"]

    assert WorkspaceSettings.models_policy(workspace) ==
             {:ok,
              %{
                "default" => %{"provider" => "local", "model" => "qwen"},
                "allow" => %{"providers" => %{"local" => %{"models" => ["qwen"]}}}
              }}

    assert WorkspaceSettings.beam_tools_config(workspace) == %{
             auto: false,
             eval: true,
             explicit: ["ext__beam__eval"]
           }
  end

  test "invalid JSONC returns an error" do
    workspace = tmp_workspace()
    write_settings(workspace, ~s({"models": ))

    assert {:error, reason} = WorkspaceSettings.load(workspace)
    assert reason =~ "Failed to parse"
  end

  test "ensure_file writes commented defaults without overwriting existing settings" do
    workspace = tmp_workspace()

    assert :ok = WorkspaceSettings.ensure_file(workspace)
    content = File.read!(WorkspaceSettings.path(workspace))

    assert content =~ "settings.jsonc"
    assert content =~ "\"builtin_enabled\": true"
    assert content =~ "\"eval\": false"
    assert content =~ "\"providers\": {}"

    File.write!(WorkspaceSettings.path(workspace), ~s({"custom": true}))
    assert :ok = WorkspaceSettings.ensure_file(workspace)
    assert File.read!(WorkspaceSettings.path(workspace)) == ~s({"custom": true})
  end

  test "owner relocation copies exact settings and rejects policy conflicts" do
    old_root = tmp_workspace()
    new_root = tmp_workspace()
    old_path = WorkspaceSettings.owner_path(old_root)
    new_path = WorkspaceSettings.owner_path(new_root)
    File.mkdir_p!(Path.dirname(old_path))
    original = "{\n  // keep owner policy\n  \"tools\": {\"default_mode\": \"prompt\"}\n}"
    File.write!(old_path, original)

    assert :ok = WorkspaceSettings.prepare_owner_change(old_root, new_root)
    assert File.read!(new_path) == original

    File.write!(new_path, ~s({"tools":{"default_mode":"yolo"}}))

    assert {:error, :settings_policy_conflict} =
             WorkspaceSettings.prepare_owner_change(old_root, new_root)

    assert File.read!(old_path) == original
    assert File.read!(new_path) == ~s({"tools":{"default_mode":"yolo"}})
  end

  test "invalid owner paths fail without creating fallback settings" do
    missing =
      Path.join(System.tmp_dir!(), "missing-settings-#{System.unique_integer([:positive])}")

    refute File.exists?(missing)
    assert {:error, _reason} = WorkspaceSettings.ensure_file(missing)
    assert {:error, _reason} = WorkspaceSettings.load(missing)
    assert {:error, _reason} = WorkspaceSettings.update_permission_mode(missing, :yolo)
    refute File.exists?(missing)
  end

  test "update_permission_mode/2 updates tool mode and preserves JSONC comments" do
    workspace = tmp_workspace()

    write_settings(workspace, """
    {
      // Some comment here
      "tools": {
        // Mode settings
        "default_mode": "auto",
        "beam": {
          "auto": true
        }
      }
    }
    """)

    assert :ok = WorkspaceSettings.update_permission_mode(workspace, :prompt)

    content = File.read!(WorkspaceSettings.path(workspace))
    assert content =~ "// Some comment here"
    assert content =~ "// Mode settings"
    assert content =~ "\"default_mode\": \"prompt\""

    assert {:ok, settings} = WorkspaceSettings.load(workspace)
    assert get_in(settings, ["tools", "default_mode"]) == "prompt"
  end

  test "update_permission_mode/2 creates default file and updates it if missing" do
    workspace = tmp_workspace()

    assert :ok = WorkspaceSettings.update_permission_mode(workspace, :yolo)

    assert {:ok, settings} = WorkspaceSettings.load(workspace)
    assert get_in(settings, ["tools", "default_mode"]) == "yolo"
  end

  test "approvals_reviewer defaults to user and rejects unknown values" do
    assert WorkspaceSettings.approvals_reviewer_from_settings(%{}) == :user
    assert WorkspaceSettings.approvals_reviewer_from_settings(%{"tools" => %{}}) == :user

    assert WorkspaceSettings.approvals_reviewer_from_settings(%{
             "tools" => %{"approvals_reviewer" => "yolo"}
           }) == :user

    assert WorkspaceSettings.approvals_reviewer_from_settings(%{
             "tools" => %{"approvals_reviewer" => "auto_review"}
           }) == :auto_review

    assert WorkspaceSettings.auto_review_config(%{}) == %{model: nil, timeout_ms: 30_000}

    assert WorkspaceSettings.auto_review_config(%{
             "tools" => %{"auto_review" => %{"model" => "  ", "timeout_ms" => 1500}}
           }) == %{model: nil, timeout_ms: 1500}
  end

  test "update_permission_mode preserves comments and updates reviewer with default_mode" do
    workspace = tmp_workspace()

    write_settings(workspace, """
    {
      // keep this comment
      "tools": {
        "default_mode": "prompt",
        "allow": ["read"]
      }
    }
    """)

    assert :ok = WorkspaceSettings.update_permission_mode(workspace, :auto_review)

    content = File.read!(WorkspaceSettings.path(workspace))
    assert content =~ "// keep this comment"
    assert content =~ "\"default_mode\": \"auto\""
    assert content =~ "\"allow\": [\"read\"]"
    assert content =~ "\"approvals_reviewer\": \"auto_review\""

    assert {:ok, settings} = WorkspaceSettings.load(workspace)
    assert get_in(settings, ["tools", "default_mode"]) == "auto"
    assert get_in(settings, ["tools", "allow"]) == ["read"]
    assert get_in(settings, ["tools", "approvals_reviewer"]) == "auto_review"

    assert :ok = WorkspaceSettings.update_permission_mode(workspace, :prompt)
    assert {:ok, settings} = WorkspaceSettings.load(workspace)
    assert get_in(settings, ["tools", "approvals_reviewer"]) == "user"
    assert get_in(settings, ["tools", "default_mode"]) == "prompt"
    assert File.read!(WorkspaceSettings.path(workspace)) =~ "// keep this comment"
  end
end
