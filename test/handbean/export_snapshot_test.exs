defmodule Handbean.ExportSnapshotTest do
  use ExUnit.Case, async: true

  alias Handbean.ExportSnapshot

  setup do
    root = Path.join(System.tmp_dir!(), "export_snap_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "a"))
    File.write!(Path.join(root, "foo..bar.txt"), "dots")
    File.write!(Path.join(root, "a/b.txt"), "b")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "accepts a file name containing consecutive dots", %{root: root} do
    assert {:ok, %{relative_path: "foo..bar.txt", display_name: "foo..bar.txt", size_bytes: 4}} =
             ExportSnapshot.authorize(root, "foo..bar.txt")
  end

  test "accepts a nested regular file", %{root: root} do
    assert {:ok, %{path: path}} = ExportSnapshot.authorize(root, "a/b.txt")
    assert path == Path.join(root, "a/b.txt")
  end

  test "rejects a .. component even when it stays inside the workspace", %{root: root} do
    assert {:error, :invalid_path} = ExportSnapshot.authorize(root, "a/../foo..bar.txt")
    assert {:error, :invalid_path} = ExportSnapshot.authorize(root, "a/../b")
    assert {:error, :invalid_path} = ExportSnapshot.authorize(root, "a/b/..")
    assert {:error, :invalid_path} = ExportSnapshot.authorize(root, "../secret")
    assert {:error, :invalid_path} = ExportSnapshot.authorize(root, "..")
  end

  test "rejects absolute paths and NUL bytes", %{root: root} do
    assert {:error, :invalid_path} = ExportSnapshot.authorize(root, "/etc/passwd")
    assert {:error, :invalid_path} = ExportSnapshot.authorize(root, "a/b.txt" <> <<0>>)
  end
end
