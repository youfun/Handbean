defmodule HandbeanProbe.NativeFileViewerIOSTest do
  use ExUnit.Case, async: false

  alias HandbeanProbe.NativeFileViewer
  alias HandbeanProbe.NativePlatform

  setup do
    previous = Application.get_env(:handbean_probe, :native_platform)
    root = Path.join(System.tmp_dir!(), "viewer_ios_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "hello.txt"), "你好\nline2")
    File.write!(Path.join(root, "page.html"), "<html>src</html>")
    File.write!(Path.join(root, "doc.pdf"), "%PDF-1.4\n")

    File.write!(
      Path.join(root, "tiny.png"),
      <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8,
        6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 248, 207, 192, 0,
        0, 0, 2, 0, 1, 226, 33, 188, 51, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>
    )

    on_exit(fn ->
      File.rm_rf!(root)

      if previous,
        do: Application.put_env(:handbean_probe, :native_platform, previous),
        else: Application.delete_env(:handbean_probe, :native_platform)
    end)

    %{root: root}
  end

  test "iOS viewer uses stock column nodes and shows text content", %{root: root} do
    NativePlatform.put!(:ios)

    assert {:ok, state} =
             NativeFileViewer.prepare(%{
               workspace_id: "ws-1",
               workspace_root: root,
               relative_path: "hello.txt",
               request_id: "req-1",
               generation: 1
             })

    node = NativeFileViewer.viewer_node(state)
    assert node.type == :column
    refute node.type == :file_viewer
    assert flatten_text(node) =~ "你好"
    assert flatten_text(node) =~ "hello.txt"

    preview = NativeFileViewer.ios_preview(state.identity, state.status)
    assert preview.kind == :text
    assert preview.text =~ "你好"
  end

  test "iOS HTML is in-app source, not a web preview", %{root: root} do
    NativePlatform.put!(:ios)

    assert {:ok, state} =
             NativeFileViewer.prepare(%{
               workspace_id: "ws-1",
               workspace_root: root,
               relative_path: "page.html",
               request_id: "req-html",
               generation: 1
             })

    assert state.identity.kind == :text
    preview = NativeFileViewer.ios_preview(state.identity, state.status)
    assert preview.kind == :text
    assert preview.text =~ "<html>src</html>"
  end

  test "iOS image preview uses a local image node", %{root: root} do
    NativePlatform.put!(:ios)

    assert {:ok, state} =
             NativeFileViewer.prepare(%{
               workspace_id: "ws-1",
               workspace_root: root,
               relative_path: "tiny.png",
               request_id: "req-img",
               generation: 2
             })

    node = NativeFileViewer.viewer_node(state)
    assert Enum.any?(flatten_nodes(node), &(&1.type == :image))
    preview = NativeFileViewer.ios_preview(state.identity, state.status)
    assert preview.kind == :image
    assert preview.path == Path.join(root, "tiny.png")
  end

  test "iOS PDF stays external and does not dump bytes", %{root: root} do
    NativePlatform.put!(:ios)

    assert {:ok, state} =
             NativeFileViewer.prepare(%{
               workspace_id: "ws-1",
               workspace_root: root,
               relative_path: "doc.pdf",
               request_id: "req-pdf",
               generation: 1
             })

    assert state.status == :external
    preview = NativeFileViewer.ios_preview(state.identity, state.status)
    assert preview.kind == :external
    node = NativeFileViewer.viewer_node(state)
    refute flatten_text(node) =~ "%PDF"
  end

  test "iOS text preview truncates at 1 MiB", %{root: root} do
    NativePlatform.put!(:ios)
    oversized = Path.join(root, "big.txt")
    File.write!(oversized, :binary.copy("a", NativeFileViewer.max_text_bytes() + 32))

    assert {:ok, state} =
             NativeFileViewer.prepare(%{
               workspace_id: "ws-1",
               workspace_root: root,
               relative_path: "big.txt",
               request_id: "req-big",
               generation: 1
             })

    preview = NativeFileViewer.ios_preview(state.identity, state.status)
    assert preview.kind == :text
    assert preview.truncated
    assert byte_size(preview.text) == NativeFileViewer.max_text_bytes()
  end

  defp flatten_text(node),
    do: node |> flatten_nodes() |> Enum.map(& &1.props[:text]) |> Enum.join("\n")

  defp flatten_nodes(nil), do: []
  defp flatten_nodes(node), do: [node | Enum.flat_map(node.children || [], &flatten_nodes/1)]
end
