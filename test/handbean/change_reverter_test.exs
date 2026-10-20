defmodule Handbean.ChangeReverterTest do
  use ExUnit.Case, async: true

  alias Handbean.ChangeReverter
  alias Handbean.ChangeSnapshot

  setup do
    dir = Path.join(System.tmp_dir!(), "sigil_reverter_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "reverts an edit when current file matches after hash", %{dir: dir} do
    path = Path.join(dir, "file.txt")
    File.write!(path, "after\n")

    change = ChangeSnapshot.build_edit_snapshot(path, "before\n", "after\n")

    assert {:ok, result} = ChangeReverter.revert(change, dir)
    assert result["revert_status"] == "reverted"
    assert File.read!(path) == "before\n"
  end

  test "reverts a created file by deleting it", %{dir: dir} do
    path = Path.join(dir, "new.txt")
    File.write!(path, "created\n")

    change = ChangeSnapshot.build_write_snapshot(path, nil, "created\n")

    assert {:ok, result} = ChangeReverter.revert(change, dir)
    assert result["revert_status"] == "reverted"
    refute File.exists?(path)
  end

  test "reverts a deleted file by restoring its recorded content", %{dir: dir} do
    path = Path.join(dir, "deleted.txt")
    change = ChangeSnapshot.build_delete_snapshot(path, "before\n")

    assert {:ok, result} = ChangeReverter.revert(change, dir)
    assert result["revert_status"] == "reverted"
    assert File.read!(path) == "before\n"
  end

  test "refuses to replace a symlink while reverting a deletion", %{dir: dir} do
    target = Path.join(dir, "target.txt")
    path = Path.join(dir, "deleted.txt")
    File.write!(target, "target\n")
    File.ln_s!(target, path)
    change = ChangeSnapshot.build_delete_snapshot(path, "before\n")

    assert {:conflict, result} = ChangeReverter.revert(change, dir)
    assert result["message"] =~ "symlink"
    assert File.read!(target) == "target\n"
  end

  test "blocks revert when file changed since diff", %{dir: dir} do
    path = Path.join(dir, "file.txt")
    File.write!(path, "after\n")
    change = ChangeSnapshot.build_edit_snapshot(path, "before\n", "after\n")
    File.write!(path, "user change\n")

    assert {:conflict, result} = ChangeReverter.revert(change, dir)
    assert result["revert_status"] == "conflict"
    assert result["message"] =~ "file changed"
    assert File.read!(path) == "user change\n"
  end

  test "rejects paths outside the workspace", %{dir: dir} do
    outside = Path.join(System.tmp_dir!(), "sigil_reverter_outside.txt")
    File.write!(outside, "after\n")
    on_exit(fn -> File.rm(outside) end)

    change = ChangeSnapshot.build_edit_snapshot(outside, "before\n", "after\n")

    assert {:error, result} = ChangeReverter.revert(change, dir)
    assert result["revert_status"] == "error"
  end
end
