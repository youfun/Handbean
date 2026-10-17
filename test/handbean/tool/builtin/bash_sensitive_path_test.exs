defmodule Handbean.Tool.Builtin.BashSensitivePathTest do
  @moduledoc """
  Bash credential-path precheck. These tests must not start the OS sandbox.
  """

  use ExUnit.Case, async: false

  alias Handbean.Tool.Builtin.Bash

  test "cat ~/.ssh/id_rsa is rejected before a process starts, even unsandboxed" do
    workspace =
      Path.join(System.tmp_dir!(), "bash_sensitive_#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    assert Bash.preflight_sensitive("cat ~/.ssh/id_rsa", workspace) ==
             {:error, "sensitive path blocked"}

    for input <- [
          %{"command" => "echo leaked && cat ~/.ssh/id_rsa"},
          %{"command" => "echo leaked && cat ~/.ssh/id_rsa", "unsandboxed" => true}
        ] do
      result = Bash.execute(input, %{working_directory: workspace})
      assert {:error, "sensitive path blocked"} = result
      refute inspect(result) =~ "leaked"
    end
  end

  test "ls of a normal workspace subdirectory is not rejected" do
    workspace =
      Path.join(System.tmp_dir!(), "bash_sensitive_ok_#{System.unique_integer([:positive])}")

    sub = Path.join(workspace, "subdir")
    File.mkdir_p!(sub)
    on_exit(fn -> File.rm_rf(workspace) end)

    assert Bash.preflight_sensitive("ls subdir", workspace) == :ok
    assert Bash.preflight_sensitive("ls #{sub}", workspace) == :ok
  end
end
