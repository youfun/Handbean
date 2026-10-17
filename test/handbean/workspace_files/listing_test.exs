defmodule Handbean.WorkspaceFiles.ListingTest do
  use ExUnit.Case, async: true

  alias Handbean.WorkspaceFiles

  setup do
    root =
      Path.join(System.tmp_dir!(), "ws_list_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "b_dir"))
    File.mkdir_p!(Path.join(root, "a_dir"))
    File.write!(Path.join(root, "z.txt"), "z")
    File.write!(Path.join(root, "a.txt"), "a")
    File.write!(Path.join(root, ".hidden"), "h")
    File.mkdir_p!(Path.join(root, ".git"))

    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "lists one directory, hides dot names, and sorts dirs first", %{root: root} do
    assert {:ok, result} = WorkspaceFiles.list(root, "")
    names = Enum.map(result.entries, & &1.name)
    refute ".hidden" in names
    refute ".git" in names
    assert names == ["a_dir", "b_dir", "a.txt", "z.txt"]
    assert Enum.map(result.entries, & &1.kind) == [:directory, :directory, :file, :file]
    refute result.truncated
  end

  test "enforces an output cap after File.ls materializes every name", %{root: root} do
    for i <- 1..8, do: File.write!(Path.join(root, "f#{i}.txt"), "x")

    assert {:ok, result} = WorkspaceFiles.list(root, "", max_entries: 3)
    assert length(result.entries) == 3
    assert result.truncated
    assert result.scanned >= 8
    assert result.max_entries == 3
    assert result.offset == 0
    assert result.next_offset == 3

    assert {:ok, more} = WorkspaceFiles.list(root, "", max_entries: 3, offset: 3)
    assert length(more.entries) == 3
    assert more.offset == 3
    names = Enum.map(result.entries ++ more.entries, & &1.name)
    assert names == Enum.uniq(names)
  end

  test "can show hidden names when asked", %{root: root} do
    assert {:ok, result} = WorkspaceFiles.list(root, "", show_hidden: true)
    names = Enum.map(result.entries, & &1.name)
    assert ".git" in names
    assert ".hidden" in names
  end

  test "does not walk into a child directory", %{root: root} do
    File.write!(Path.join(root, "a_dir/nested.txt"), "n")
    assert {:ok, result} = WorkspaceFiles.list(root, "")
    refute Enum.any?(result.entries, &(&1.name == "nested.txt"))

    assert {:ok, nested} = WorkspaceFiles.list(root, "a_dir")
    assert Enum.map(nested.entries, & &1.relative_path) == ["a_dir/nested.txt"]
  end
end
