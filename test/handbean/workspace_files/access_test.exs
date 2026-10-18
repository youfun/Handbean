defmodule Handbean.WorkspaceFiles.AccessTest do
  use ExUnit.Case, async: true

  alias Handbean.Security.PathValidator
  alias Handbean.WorkspaceFiles

  setup do
    root =
      Path.join(System.tmp_dir!(), "ws_access_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "sub"))
    File.write!(Path.join(root, "note.txt"), "你好")
    File.write!(Path.join(root, "sub/inner.txt"), "inner")

    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "resolves a regular file under the workspace root", %{root: root} do
    assert {:ok, path} = WorkspaceFiles.resolve(root, "note.txt")
    assert path == Path.join(root, "note.txt")
  end

  test "rejects absolute relative paths and .. components", %{root: root} do
    assert {:error, :invalid_path} = WorkspaceFiles.resolve(root, "/etc/passwd")
    assert {:error, :invalid_path} = WorkspaceFiles.resolve(root, "../secret")
    assert {:error, :invalid_path} = WorkspaceFiles.resolve(root, "sub/../../secret")
  end

  test "rejects a symlink root", %{root: root} do
    linked =
      Path.join(System.tmp_dir!(), "ws_rootlink_#{System.unique_integer([:positive])}")

    File.ln_s!(root, linked)
    on_exit(fn -> File.rm_rf!(linked) end)
    assert {:error, :symlink} = WorkspaceFiles.resolve(linked, "note.txt")
  end

  test "rejects an ancestor symlink that PathValidator would allow", %{root: root} do
    outside =
      Path.join(System.tmp_dir!(), "ws_outside_#{System.unique_integer([:positive])}")

    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secret.txt"), "nope")
    File.ln_s!(outside, Path.join(root, "escape"))
    on_exit(fn -> File.rm_rf!(outside) end)

    escaped = Path.join(root, "escape/secret.txt")
    assert {:error, reason} = PathValidator.validate_within_workspace(escaped, root)
    assert reason =~ "outside workspace"
    assert {:error, :symlink} = WorkspaceFiles.resolve(root, "escape/secret.txt")
  end

  test "rejects an in-workspace link that skips ancestor components", %{root: root} do
    outside =
      Path.join(System.tmp_dir!(), "ws_skip_#{System.unique_integer([:positive])}")

    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secret.txt"), "nope")
    File.ln_s!(outside, Path.join(root, "escape"))
    File.ln_s!(Path.join(root, "escape/secret.txt"), Path.join(root, "link"))
    on_exit(fn -> File.rm_rf!(outside) end)

    assert {:error, :symlink} = WorkspaceFiles.resolve(root, "link")
  end

  test "rejects an in-workspace alias symlink", %{root: root} do
    File.ln_s!(Path.join(root, "note.txt"), Path.join(root, "alias.txt"))
    assert {:error, :symlink} = WorkspaceFiles.resolve(root, "alias.txt")
  end

  test "rejects a symlink cycle as a symlink", %{root: root} do
    a = Path.join(root, "loop_a")
    b = Path.join(root, "loop_b")
    File.ln_s!(b, a)
    File.ln_s!(a, b)
    assert {:error, :symlink} = WorkspaceFiles.resolve(root, "loop_a")
  end

  test "resolve_entry allows a symlink leaf but still rejects symlink ancestors", %{root: root} do
    outside =
      Path.join(System.tmp_dir!(), "ws_reveal_#{System.unique_integer([:positive])}")

    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secret.txt"), "nope")
    leaf = Path.join(root, "leaf-link")
    ancestor = Path.join(root, "ancestor-link")
    File.ln_s!(Path.join(outside, "missing.txt"), leaf)
    File.ln_s!(outside, ancestor)
    on_exit(fn -> File.rm_rf!(outside) end)

    assert {:ok, ^leaf} = WorkspaceFiles.resolve_entry(root, "leaf-link")
    assert {:error, :symlink} = WorkspaceFiles.resolve_entry(root, "ancestor-link/secret.txt")
  end

  test "resolve_entry accepts files and directories but rejects invalid or missing entries", %{
    root: root
  } do
    assert {:ok, path} = WorkspaceFiles.resolve_entry(root, "note.txt")
    assert path == Path.join(root, "note.txt")
    assert {:ok, path} = WorkspaceFiles.resolve_entry(root, "sub")
    assert path == Path.join(root, "sub")
    assert {:error, :invalid_path} = WorkspaceFiles.resolve_entry(root, "")
    assert {:error, :invalid_path} = WorkspaceFiles.resolve_entry(root, "../outside")
    assert {:error, :enoent} = WorkspaceFiles.resolve_entry(root, "missing")
  end

  test "rejects a directory when a file is required", %{root: root} do
    assert {:error, {:unexpected_type, :directory}} = WorkspaceFiles.resolve(root, "sub", :file)
    assert {:ok, _} = WorkspaceFiles.resolve(root, "sub", :directory)
  end

  test "contained? accepts the root and real descendants", %{root: root} do
    assert WorkspaceFiles.contained?(root, root)
    assert WorkspaceFiles.contained?(Path.join(root, "sub"), root)
    assert WorkspaceFiles.contained?(Path.join(root, "sub/inner.txt"), root)
    assert {:ok, _} = WorkspaceFiles.resolve(root, "sub/inner.txt")
  end

  test "contained? rejects a sibling sharing the root prefix", %{root: root} do
    sibling = root <> "2"
    File.mkdir_p!(sibling)
    File.write!(Path.join(sibling, "x"), "x")
    on_exit(fn -> File.rm_rf!(sibling) end)

    refute WorkspaceFiles.contained?(sibling, root)
    refute WorkspaceFiles.contained?(Path.join(sibling, "x"), root)
    refute WorkspaceFiles.contained?(Path.join(root, "sub/../.."), root)
    refute WorkspaceFiles.contained?(Path.join(root, ".."), root)
  end

  test "rejects a missing workspace root" do
    assert {:error, :enoent} =
             WorkspaceFiles.resolve(
               "/tmp/missing_ws_#{System.unique_integer([:positive])}",
               "a.txt"
             )
  end
end
