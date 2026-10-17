defmodule HandbeanProbe.NativeFileViewerTest do
  use ExUnit.Case, async: true

  alias HandbeanProbe.NativeFileViewer
  alias HandbeanProbe.NativeFileViewer.Identity

  setup do
    root =
      Path.join(System.tmp_dir!(), "viewer_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    File.write!(Path.join(root, "hello.txt"), "你好\nline2")
    File.write!(Path.join(root, "page.html"), "<html>src</html>")
    File.write!(Path.join(root, "doc.pdf"), "%PDF-1.4\n")

    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp attrs(root, rel, extra \\ %{}) do
    Map.merge(
      %{
        workspace_id: "ws-1",
        workspace_root: root,
        relative_path: rel,
        request_id: "req-1",
        generation: 3
      },
      extra
    )
  end

  test "prepare keeps metadata only and does not open for classification", %{root: root} do
    assert {:ok, state} = NativeFileViewer.prepare(attrs(root, "hello.txt"))
    assert state.status == :ready
    assert state.identity.kind == :text
    node = NativeFileViewer.viewer_node(state)
    assert node.type == :file_viewer
    refute Map.has_key?(node.props, :text)
  end

  test "HTML is in-app source, PDF is external", %{root: root} do
    assert {:ok, html} = NativeFileViewer.prepare(attrs(root, "page.html"))
    assert html.identity.kind == :text
    assert {:ok, pdf} = NativeFileViewer.prepare(attrs(root, "doc.pdf"))
    assert pdf.status == :external
  end

  test "prepare rejects a symlink instead of following it", %{root: root} do
    File.ln_s!(Path.join(root, "hello.txt"), Path.join(root, "alias.txt"))
    assert {:error, :symlink} = NativeFileViewer.prepare(attrs(root, "alias.txt"))
  end

  test "identity equality is workspace + relative + request + generation" do
    {:ok, a} =
      Identity.new(%{
        workspace_id: "w",
        workspace_root: "/tmp/w",
        relative_path: "a.txt",
        request_id: "r",
        generation: 1
      })

    {:ok, b} = Identity.new(Map.from_struct(a) |> Map.put(:generation, 2))
    refute Identity.same_file?(a, b)
    assert Identity.same_file?(a, a)
  end

  test "export calls export_file arity only" do
    {:ok, identity} =
      Identity.new(%{
        workspace_id: "w",
        workspace_root: "/tmp/w",
        relative_path: "doc.pdf",
        request_id: "req-export",
        generation: 9
      })

    fake = fn caller, request_id, generation, root, rel ->
      send(self(), {:export, caller, request_id, generation, root, rel})
      {:ok, :async}
    end

    assert {:ok, :async} = NativeFileViewer.export(identity, export: fake, caller: self())
    assert_received {:export, pid, "req-export", 9, "/tmp/w", "doc.pdf"}
    assert pid == self()

    assert NativeFileViewer.snapshot_keys() == [
             "snapshot_id",
             "path",
             "display_name",
             "size_bytes",
             "mime",
             "state",
             "owner_request_id"
           ]
  end

  test "default export uses Platform's file validation", %{root: root} do
    {:ok, identity} =
      Identity.new(%{
        workspace_id: "w",
        workspace_root: root,
        relative_path: "missing.pdf",
        request_id: "r",
        generation: 1
      })

    assert {:error, :enoent} = NativeFileViewer.export(identity)
  end
end
