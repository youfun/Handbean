defmodule Handbeam.RepoIdentityTest do
  use ExUnit.Case, async: false

  alias Handbeam.RepoIdentity

  setup do
    root =
      Path.join(System.tmp_dir!(), "handbeam_repo_identity_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  test "plain directory uses one canonical identity", %{root: root} do
    assert {:ok, identity} = RepoIdentity.resolve(root)
    assert identity.kind == :directory
    assert identity.repo_key == root
    assert identity.workspace_path == root
    assert identity.checkout_path == root
  end

  test "nested Git paths resolve to the checkout root", %{root: root} do
    init_repo!(root)
    nested = Path.join(root, "lib/nested")
    File.mkdir_p!(nested)

    assert {:ok, identity} = RepoIdentity.resolve(nested)
    assert identity.kind == :git
    assert identity.workspace_path == root
    assert identity.checkout_path == root
    assert identity.repo_key == Path.join(root, ".git")
  end

  test "main checkout and linked worktree share repo identity", %{root: root} do
    init_repo!(root)
    commit_file!(root, "README.md", "main")
    linked = root <> "-linked"
    on_exit(fn -> File.rm_rf(linked) end)

    git!(root, ["worktree", "add", "-b", "feature", linked])

    assert {:ok, main} = RepoIdentity.resolve(root)
    assert {:ok, worktree} = RepoIdentity.resolve(linked)
    assert main.repo_key == worktree.repo_key
    assert main.workspace_path == worktree.workspace_path
    refute main.checkout_path == worktree.checkout_path

    assert {:ok, checkouts} = RepoIdentity.list_checkouts(root)
    assert Enum.map(checkouts, & &1.path) == [main.checkout_path, worktree.checkout_path]
    assert hd(checkouts).main?
    refute List.last(checkouts).main?
    assert List.last(checkouts).branch == "feature"
  end

  test "plain directory lists a single checkout", %{root: root} do
    assert {:ok, [checkout]} = RepoIdentity.list_checkouts(root)
    assert checkout.path == Handbeam.Security.PathValidator.resolve_symlink(root)
    assert checkout.main?
  end

  test "independent clones remain distinct", %{root: root} do
    source = Path.join(root, "source")
    first = Path.join(root, "first")
    second = Path.join(root, "second")
    init_repo!(source)
    commit_file!(source, "README.md", "source")
    git!(root, ["clone", source, first])
    git!(root, ["clone", source, second])

    assert {:ok, first_identity} = RepoIdentity.resolve(first)
    assert {:ok, second_identity} = RepoIdentity.resolve(second)
    refute first_identity.repo_key == second_identity.repo_key
  end

  test "symlink and real path resolve identically", %{root: root} do
    real = Path.join(root, "real")
    alias_path = Path.join(root, "alias")
    File.mkdir_p!(real)
    File.ln_s!(real, alias_path)

    assert RepoIdentity.resolve(real) == RepoIdentity.resolve(alias_path)
  end

  test "managed subagent worktrees are rejected", %{root: root} do
    managed = Path.join(root, ".handbeam/worktrees/child")
    File.mkdir_p!(managed)
    assert {:error, :managed_worktree} = RepoIdentity.resolve(managed)
  end

  defp init_repo!(path) do
    File.mkdir_p!(path)
    git!(path, ["init"])
    git!(path, ["config", "user.email", "test@example.com"])
    git!(path, ["config", "user.name", "Handbeam Test"])
  end

  defp commit_file!(repo, relative, content) do
    File.write!(Path.join(repo, relative), content)
    git!(repo, ["add", relative])
    git!(repo, ["commit", "-m", "fixture"])
  end

  defp git!(cwd, args) do
    {output, status} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    assert status == 0, output
    output
  end
end
