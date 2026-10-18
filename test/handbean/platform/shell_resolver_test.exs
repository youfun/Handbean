defmodule Handbean.Platform.ShellResolverTest do
  use ExUnit.Case, async: false

  alias Handbean.Platform.ShellResolver

  describe "resolve/1 on unix" do
    test "finds bash from PATH" do
      assert {:ok, config} = ShellResolver.resolve([])
      assert is_binary(config.path)
      assert config.args == ["-c"]
      assert File.exists?(config.path)
    end

    test "respects explicit shell_path option" do
      bash = System.find_executable("bash") || "/bin/bash"
      assert {:ok, config} = ShellResolver.resolve(shell_path: bash)
      assert config.path == bash
      assert config.source == :explicit
    end

    test "explicit invalid path returns error" do
      assert {:error, reason} = ShellResolver.resolve(shell_path: "/nonexistent/bash_xyz")
      assert reason =~ "not found" or reason =~ "does not exist"
    end
  end

  describe "app_env config" do
    test "reads shell_path from Application env" do
      bash = System.find_executable("bash") || "/bin/bash"
      Application.put_env(:handbean, :shell_path, bash)

      assert {:ok, config} = ShellResolver.resolve([])
      assert config.path == bash

      Application.delete_env(:handbean, :shell_path)
    end
  end

  describe "workspace settings shellPath" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "sigil_shell_test_#{System.unique_integer()}")
      File.mkdir_p!(Path.join(tmp_dir, ".handbean"))

      on_exit(fn -> File.rm_rf(tmp_dir) end)

      {:ok, tmp_dir: tmp_dir}
    end

    test "reads tools.bash.shellPath from workspace settings (.handbean/settings.jsonc)", %{
      tmp_dir: tmp_dir
    } do
      bash = System.find_executable("bash") || "/bin/bash"

      settings = %{
        "tools" => %{
          "bash" => %{
            "shellPath" => bash
          }
        }
      }

      File.write!(
        Path.join(tmp_dir, ".handbean/settings.jsonc"),
        Jason.encode!(settings)
      )

      assert {:ok, config} = ShellResolver.resolve(workspace_path: tmp_dir)
      assert config.path == bash
      assert config.source == :workspace
    end

    test "workspace without tools.bash.shellPath falls through to auto-detect", %{
      tmp_dir: tmp_dir
    } do
      File.write!(
        Path.join(tmp_dir, ".handbean/settings.jsonc"),
        Jason.encode!(%{})
      )

      assert match?({:ok, _}, ShellResolver.resolve(workspace_path: tmp_dir))
    end
  end
end
