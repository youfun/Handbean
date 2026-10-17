defmodule Handbean.Agent.Subagent.WorktreeTest do
  @moduledoc """
  Failure boundary for applying a child worktree:

    * if worktree cleanup fails after `git apply`, the parent workspace must
      be restored and the child worktree must remain available for retry.
  """

  use ExUnit.Case, async: false

  alias Handbean.Agent.Subagent.Worktree

  test "rolls back the parent patch when worktree cleanup fails" do
    root = Path.join(System.tmp_dir!(), "worktree-rollback-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "repo")
    fake_bin = Path.join(root, "bin")
    child_id = "child"
    real_git = System.find_executable("git")
    old_path = System.get_env("PATH") || ""

    File.mkdir_p!(workspace)
    File.mkdir_p!(fake_bin)

    on_exit(fn ->
      System.put_env("PATH", old_path)
      File.rm_rf!(root)
    end)

    git!(real_git, workspace, ["init", "-q"])
    File.write!(Path.join(workspace, "README.md"), "base\n")
    git!(real_git, workspace, ["add", "README.md"])

    git!(real_git, workspace, [
      "-c",
      "user.name=Test",
      "-c",
      "user.email=test@example.com",
      "commit",
      "-q",
      "-m",
      "base"
    ])

    assert {:ok, %{path: child}} = Worktree.create(workspace, child_id)
    File.write!(Path.join(child, "new.txt"), "child\n")

    fake_git = Path.join(fake_bin, "git")

    File.write!(fake_git, """
    #!/bin/sh
    if [ "$1" = "worktree" ] && [ "$2" = "remove" ]; then
      echo forced cleanup failure
      exit 1
    fi
    exec "#{real_git}" "$@"
    """)

    File.chmod!(fake_git, 0o755)
    System.put_env("PATH", fake_bin <> ":" <> old_path)

    assert {:error, reason} = Worktree.apply(workspace, child_id)
    assert reason =~ "forced cleanup failure"
    assert reason =~ "workspace patch was rolled back"
    refute File.exists?(Path.join(workspace, "new.txt"))
    assert File.read!(Path.join(child, "new.txt")) == "child\n"
  end

  defp git!(git, cwd, args) do
    assert {_, 0} = System.cmd(git, args, cd: cwd, stderr_to_stdout: true)
  end
end
