defmodule Handbean.WorkspaceSettingsWriteTest do
  @moduledoc """
  TDD tests for WorkspaceSettings write/policy methods.

  Covers:
    - write_policy: write workspace model access policy and read it back
    - preserve existing settings (non-destructive update of models block)
    - preserve JSONC comments
  """

  use ExUnit.Case, async: true

  alias Handbean.WorkspaceSettings

  defp tmp_workspace do
    dir =
      Path.join(
        System.tmp_dir!(),
        "sigil_ws_policy_write_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)

    on_exit(fn -> File.rm_rf(dir) end)

    dir
  end

  defp write_settings_file(workspace, content) do
    path = WorkspaceSettings.path(workspace)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end

  # ══════════════════════════════════════════════════════════
  # write_policy
  # ══════════════════════════════════════════════════════════

  describe "append_tool_rule/3" do
    test "serializes concurrent read-modify-write updates" do
      ws = tmp_workspace()
      parent = self()
      gate = make_ref()
      patterns = Enum.map(1..40, &"bash(command-#{&1})")

      tasks =
        Enum.map(patterns, fn pattern ->
          Task.async(fn ->
            send(parent, {:ready, self()})
            receive do: ({:go, ^gate} -> WorkspaceSettings.append_tool_rule(ws, :allow, pattern))
          end)
        end)

      task_pids = Enum.map(tasks, & &1.pid)
      Enum.each(task_pids, fn pid -> assert_receive {:ready, ^pid} end)
      Enum.each(task_pids, &send(&1, {:go, gate}))
      results = Task.await_many(tasks, 15_000)
      assert Enum.all?(results, &match?(:ok, &1))

      assert {:ok, settings} = WorkspaceSettings.load(ws)
      assert MapSet.new(get_in(settings, ["tools", "allow"])) == MapSet.new(patterns)
    end

    test "appends an allow pattern without duplicating or dropping default_mode" do
      ws = tmp_workspace()

      write_settings_file(ws, """
      {
        "tools": {
          "default_mode": "prompt",
          "allow": [],
          "deny": []
        }
      }
      """)

      assert :ok = WorkspaceSettings.append_tool_rule(ws, :allow, "bash(git status*)")
      assert :ok = WorkspaceSettings.append_tool_rule(ws, :allow, "bash(git status*)")
      assert :ok = WorkspaceSettings.append_tool_rule(ws, :deny, "bash(rm:*)")

      {:ok, settings} = WorkspaceSettings.load(ws)
      assert get_in(settings, ["tools", "default_mode"]) == "prompt"
      assert get_in(settings, ["tools", "allow"]) == ["bash(git status*)"]
      assert get_in(settings, ["tools", "deny"]) == ["bash(rm:*)"]
    end
  end

  describe "write_policy/2" do
    test "writes model policy to settings file and reads it back" do
      ws = tmp_workspace()
      settings_path = WorkspaceSettings.path(ws)
      File.mkdir_p!(Path.dirname(settings_path))
      File.write!(settings_path, Jason.encode!(%{}))

      policy = %{
        "version" => 1,
        "default" => %{"provider" => "stepfun", "model" => "step-router-v1"},
        "allow" => %{
          "providers" => %{
            "stepfun" => %{"models" => ["step-router-v1"]},
            "local" => %{"models" => ["llama3", "qwen-coder"]}
          }
        }
      }

      assert :ok = WorkspaceSettings.write_policy(ws, policy)

      # Read back
      case WorkspaceSettings.models_policy(ws) do
        {:ok, read_policy} ->
          assert read_policy["version"] == 1
          assert read_policy["default"]["provider"] == "stepfun"
          assert read_policy["allow"]["providers"]["stepfun"]["models"] == ["step-router-v1"]
          assert read_policy["allow"]["providers"]["local"]["models"] == ["llama3", "qwen-coder"]

        :unrestricted ->
          flunk("Expected policy to be restricted, got :unrestricted")

        {:error, reason} ->
          flunk("Failed to read policy: #{reason}")
      end
    end

    test "preserves existing non-model settings when writing policy" do
      ws = tmp_workspace()

      # Write initial settings with tools config
      write_settings_file(ws, """
      {
        "models": {
          "allow": {
            "providers": {}
          }
        },
        "tools": {
          "default_mode": "auto",
          "beam": {
            "auto": true,
            "eval": true
          }
        }
      }
      """)

      new_policy = %{
        "allow" => %{
          "providers" => %{
            "cloud" => %{"models" => ["gpt-5"]}
          }
        }
      }

      assert :ok = WorkspaceSettings.write_policy(ws, new_policy)

      # Read back full settings
      {:ok, settings} = WorkspaceSettings.load(ws)

      # Models should be updated
      assert get_in(settings, ["models", "allow", "providers", "cloud", "models"]) == ["gpt-5"]

      # Tools should still exist unchanged
      assert get_in(settings, ["tools", "beam", "eval"]) == true
      assert get_in(settings, ["tools", "default_mode"]) == "auto"
    end

    test "creates settings file if it does not exist" do
      ws = tmp_workspace()

      refute File.exists?(WorkspaceSettings.path(ws))

      policy = %{
        "allow" => %{
          "providers" => %{
            "p" => %{"models" => ["m"]}
          }
        }
      }

      assert :ok = WorkspaceSettings.write_policy(ws, policy)

      assert File.exists?(WorkspaceSettings.path(ws))
      assert {:ok, _} = WorkspaceSettings.models_policy(ws)
      # Not :unrestricted because we wrote a policy
      assert WorkspaceSettings.models_policy(ws) != :unrestricted
    end

    test "rejects invalid policy (non-map)" do
      ws = tmp_workspace()

      assert {:error, reason} = WorkspaceSettings.write_policy(ws, "not a map")
      assert reason =~ "map" or reason =~ "invalid"
    end

    test "does not overwrite existing settings when current file is malformed" do
      ws = tmp_workspace()
      original = ~s({"tools":{"default_mode":"prompt")
      write_settings_file(ws, original)

      assert {:error, reason} =
               WorkspaceSettings.write_policy(ws, %{
                 "allow" => %{"providers" => %{}}
               })

      assert reason =~ "Failed to parse"
      assert File.read!(WorkspaceSettings.path(ws)) == original
    end

    test "does not overwrite existing settings when current file is not an object" do
      ws = tmp_workspace()
      original = ~s(["not", "an", "object"])
      write_settings_file(ws, original)

      assert {:error, reason} =
               WorkspaceSettings.write_policy(ws, %{
                 "allow" => %{"providers" => %{}}
               })

      assert reason =~ "expected a JSON object"
      assert File.read!(WorkspaceSettings.path(ws)) == original
    end

    test "writes empty allow.providers policy and reads it back" do
      ws = tmp_workspace()

      # Writing empty providers is valid — the policy exists but restricts everything.
      # (:unrestricted only when models key is absent entirely)
      assert :ok =
               WorkspaceSettings.write_policy(ws, %{
                 "allow" => %{"providers" => %{}}
               })

      # models_policy returns the policy as-is (empty allow)
      assert {:ok, policy} = WorkspaceSettings.models_policy(ws)
      assert policy["allow"]["providers"] == %{}
    end

    test "preserves non-model settings when writing policy" do
      ws = tmp_workspace()

      write_settings_file(ws, """
      {
        "models": {
          "allow": {
            "providers": {}
          }
        },
        "tools": {
          "beam": {
            "auto": true
          },
          "default_mode": "prompt"
        }
      }
      """)

      new_policy = %{
        "allow" => %{
          "providers" => %{
            "my-p" => %{"models" => ["my-m"]}
          }
        }
      }

      assert :ok = WorkspaceSettings.write_policy(ws, new_policy)

      content = File.read!(WorkspaceSettings.path(ws))
      {:ok, settings} = Jason.decode(content)

      # New policy data should be present
      assert get_in(settings, ["models", "allow", "providers", "my-p", "models"]) == ["my-m"]

      # Non-model settings should be preserved
      assert get_in(settings, ["tools", "beam", "auto"]) == true
      assert get_in(settings, ["tools", "default_mode"]) == "prompt"
    end

    test "roundtrip: write_policy → models_policy matches" do
      ws = tmp_workspace()

      policy = %{
        "default" => %{"provider" => "a", "model" => "x"},
        "allow" => %{
          "providers" => %{
            "a" => %{"models" => ["x", "y"]},
            "b" => %{"models" => ["z"]}
          }
        }
      }

      assert :ok = WorkspaceSettings.write_policy(ws, policy)

      {:ok, read} = WorkspaceSettings.models_policy(ws)

      assert read["default"]["provider"] == "a"
      assert read["default"]["model"] == "x"
      assert read["allow"]["providers"]["a"]["models"] == ["x", "y"]
      assert read["allow"]["providers"]["b"]["models"] == ["z"]
    end
  end
end
