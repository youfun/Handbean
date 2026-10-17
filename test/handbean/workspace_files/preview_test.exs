defmodule Handbean.WorkspaceFiles.PreviewTest do
  use ExUnit.Case, async: true

  alias Handbean.WorkspaceFiles

  @limit 128 * 1024

  setup do
    root = Path.join(System.tmp_dir!(), "preview_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "returns original code characters without HTML escaping", %{root: root} do
    source = "value |> Enum.map(&(&1 < 2))\n"
    File.write!(Path.join(root, "mix.exs"), source)
    assert {:ok, preview} = WorkspaceFiles.preview(root, "mix.exs")
    assert preview.kind == :code
    assert preview.language == "elixir"
    assert preview.content == source
    refute preview.truncated?
  end

  test "classifies markdown, images, unsupported binary and empty files", %{root: root} do
    for {name, bytes, kind} <- [
          {"README.md", "# Title", :markdown},
          {"photo.png", <<137, 80, 78, 71>>, :image},
          {"document.pdf", "%PDF-1.7", :external},
          {"data.bin", <<0, 1, 2>>, :external},
          {"empty.txt", "", :code}
        ] do
      File.write!(Path.join(root, name), bytes)
      assert {:ok, preview} = WorkspaceFiles.preview(root, name)
      assert preview.kind == kind
    end
  end

  test "truncates large text at a complete UTF-8 boundary", %{root: root} do
    for suffix <- ["你", "😀"] do
      source = String.duplicate("a", @limit - 1) <> suffix <> "trailing"
      File.write!(Path.join(root, "large.txt"), source)
      assert {:ok, preview} = WorkspaceFiles.preview(root, "large.txt")
      assert preview.content == String.duplicate("a", @limit - 1)
      assert String.valid?(preview.content)
      assert preview.truncated?
      assert preview.size == byte_size(source)
    end
  end

  test "rejects invalid UTF-8 without discarding an invalid suffix into text", %{root: root} do
    for source <- ["valid" <> <<255>>, <<255>> <> String.duplicate("a", @limit), <<240, 159>>] do
      File.write!(Path.join(root, "invalid.txt"), source)
      assert {:ok, %{kind: :external, content: nil}} = WorkspaceFiles.preview(root, "invalid.txt")
    end
  end

  test "refuses traversal, symlinks and sensitive files", %{root: root} do
    File.write!(Path.join(root, "note.txt"), "text")
    File.ln_s!(Path.join(root, "note.txt"), Path.join(root, "link.txt"))
    File.write!(Path.join(root, ".env"), "test fixture")
    assert {:error, :invalid_path} = WorkspaceFiles.preview(root, "../note.txt")
    assert {:error, :symlink} = WorkspaceFiles.preview(root, "link.txt")
    assert {:error, "sensitive path blocked"} = WorkspaceFiles.preview(root, ".env")
    assert {:error, :enoent} = WorkspaceFiles.preview(root, "missing.txt")
    assert {:ok, listing} = WorkspaceFiles.list(root, "", show_hidden: true)
    refute Enum.any?(listing.entries, &(&1.name == ".env"))
  end
end
