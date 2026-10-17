defmodule HandbeanProbe.NativeWorkspaceTreeTest do
  use ExUnit.Case, async: false
  use Gettext, backend: HandbeanProbe.Gettext

  import Mob.Socket, only: [assign: 3]

  alias Handbean.WorkspaceFiles
  alias HandbeanProbe.NativeWorkspaceTree

  setup do
    Application.put_env(:handbean_probe, :file_tree_max_entries, 2)

    on_exit(fn ->
      Application.delete_env(:handbean_probe, :file_tree_max_entries)
      Application.delete_env(:handbean_probe, :workspace_files_list)
      Application.delete_env(:handbean_probe, :workspace_io_start)
    end)

    :ok
  end

  test "out-of-order directory results keep both listings" do
    root = tree_root()
    parent = self()

    Application.put_env(:handbean_probe, :workspace_files_list, fn ws, dir, opts ->
      send(parent, {:awaiting, dir, self()})

      receive do
        :go -> WorkspaceFiles.list(ws, dir, opts)
      end
    end)

    socket = ensure_tree(root)
    assert_receive {:awaiting, "", pid_root}, 1_000
    send(pid_root, :go)
    socket = flush_listed(socket, 1)
    refute socket.assigns.workspace_tree.dirs[""].loading

    epoch = socket.assigns.workspace_tree.epoch

    socket =
      NativeWorkspaceTree.handle(socket, bound(socket, %{op: :toggle, relative_dir: "a_dir"}))

    socket =
      NativeWorkspaceTree.handle(socket, bound(socket, %{op: :toggle, relative_dir: "b_dir"}))

    assert socket.assigns.workspace_tree.epoch == epoch
    assert socket.assigns.workspace_tree.dirs["a_dir"].loading
    assert socket.assigns.workspace_tree.dirs["b_dir"].loading

    assert_receive {:awaiting, "a_dir", pid_a}, 1_000
    assert_receive {:awaiting, "b_dir", pid_b}, 1_000
    send(pid_b, :go)
    socket = flush_listed(socket, 1)
    refute socket.assigns.workspace_tree.dirs["b_dir"].loading
    assert socket.assigns.workspace_tree.dirs["a_dir"].loading

    assert Enum.any?(
             socket.assigns.workspace_tree.dirs["b_dir"].entries,
             &(&1.name == "nested-b.txt")
           )

    send(pid_a, :go)
    socket = flush_listed(socket, 1)
    refute socket.assigns.workspace_tree.dirs["a_dir"].loading

    assert Enum.any?(
             socket.assigns.workspace_tree.dirs["a_dir"].entries,
             &(&1.name == "nested.txt")
           )
  end

  test "refresh and workspace A-B-A drop stale epoch results" do
    root = tree_root()
    socket = ensure_tree(root)
    socket = flush_listed(socket, 1)
    first = listed_payload(socket, "")

    socket = NativeWorkspaceTree.handle(socket, bound(socket, %{op: :refresh}))
    ignored = NativeWorkspaceTree.handle_listed(socket, first)
    refute ignored.assigns.workspace_tree.dirs[""].listed?
    refute Enum.any?(ignored.assigns.workspace_tree.dirs[""].entries, &(&1.name == "ghost"))
    socket = flush_listed(socket, 1)

    replay = listed_payload(socket, "")
    same = NativeWorkspaceTree.handle_listed(socket, replay)
    names = Enum.map(same.assigns.workspace_tree.dirs[""].entries, & &1.name)
    assert names == Enum.map(socket.assigns.workspace_tree.dirs[""].entries, & &1.name)

    other = %{"id" => "ws-b", "path" => root, "name" => "B"}
    socket = assign(socket, :workspace, other)
    socket = NativeWorkspaceTree.ensure(socket)
    assert socket.assigns.workspace_tree.workspace_id == "ws-b"
    socket = flush_listed(socket, 1)

    back = %{"id" => "ws-1", "path" => root, "name" => "W"}
    socket = assign(socket, :workspace, back)
    socket = NativeWorkspaceTree.ensure(socket)
    assert socket.assigns.workspace_tree.workspace_id == "ws-1"
    ignored = NativeWorkspaceTree.handle_listed(socket, replay)
    refute ignored.assigns.workspace_tree.dirs[""].listed?
    socket = flush_listed(socket, 1)
    assert socket.assigns.workspace_tree.dirs[""].listed?
  end

  test "start_child failure clears loading and retry reloads a missing folder" do
    root = tree_root()
    Application.put_env(:handbean_probe, :workspace_io_start, fn _fun -> {:error, :noproc} end)

    socket = ensure_tree(root)
    dir = socket.assigns.workspace_tree.dirs[""]
    refute dir.loading
    assert dir.error

    encoded = inspect(NativeWorkspaceTree.render(socket.assigns.workspace_tree), limit: :infinity)
    assert encoded =~ gettext("Retry")

    Application.delete_env(:handbean_probe, :workspace_io_start)
    socket = NativeWorkspaceTree.handle(socket, bound(socket, %{op: :retry, relative_dir: ""}))
    socket = flush_listed(socket, 1)
    refute socket.assigns.workspace_tree.dirs[""].error
    assert socket.assigns.workspace_tree.dirs[""].listed?

    File.rm_rf!(Path.join(root, "gone"))
    File.mkdir_p!(Path.join(root, "gone"))
    Application.put_env(:handbean_probe, :file_tree_max_entries, 256)
    socket = NativeWorkspaceTree.handle(socket, bound(socket, %{op: :refresh}))
    socket = flush_listed(socket, 1)

    socket =
      NativeWorkspaceTree.handle(socket, bound(socket, %{op: :toggle, relative_dir: "gone"}))

    socket = flush_listed(socket, 1)
    assert socket.assigns.workspace_tree.dirs["gone"].listed?
    assert socket.assigns.workspace_tree.dirs["gone"].entries == []
    encoded = inspect(NativeWorkspaceTree.render(socket.assigns.workspace_tree), limit: :infinity)
    assert encoded =~ gettext("This folder is empty.")

    File.rm_rf!(Path.join(root, "gone"))
    socket = NativeWorkspaceTree.handle(socket, bound(socket, %{op: :refresh}))
    socket = flush_listed(socket, 2)
    assert socket.assigns.workspace_tree.dirs["gone"].error
    refute socket.assigns.workspace_tree.dirs["gone"].loading

    socket =
      NativeWorkspaceTree.handle(socket, bound(socket, %{op: :toggle, relative_dir: "gone"}))

    socket =
      NativeWorkspaceTree.handle(socket, bound(socket, %{op: :toggle, relative_dir: "gone"}))

    socket = flush_listed(socket, 1)
    assert socket.assigns.workspace_tree.dirs["gone"].error
    refute socket.assigns.workspace_tree.dirs["gone"].loading
  end

  test "lists hide dots, load-more, and rejects unbound taps" do
    root = tree_root()
    socket = ensure_tree(root)
    socket = flush_listed(socket, 1)
    names = Enum.map(socket.assigns.workspace_tree.dirs[""].entries, & &1.name)
    refute ".hidden" in names
    assert "a_dir" in names

    socket =
      NativeWorkspaceTree.handle(socket, bound(socket, %{op: :load_more, relative_dir: ""}))

    socket = flush_listed(socket, 1)
    names = Enum.map(socket.assigns.workspace_tree.dirs[""].entries, & &1.name)
    assert length(names) >= 3

    socket = NativeWorkspaceTree.handle(socket, bound(socket, %{op: :toggle_hidden}))
    socket = flush_listed(socket, 1)
    assert socket.assigns.workspace_tree.show_hidden

    socket =
      NativeWorkspaceTree.handle(socket, bound(socket, %{op: :load_more, relative_dir: ""}))

    socket = flush_listed(socket, 1)
    hidden_names = Enum.map(socket.assigns.workspace_tree.dirs[""].entries, & &1.name)
    assert ".hidden" in hidden_names

    stale =
      NativeWorkspaceTree.handle(socket, %{
        op: :open,
        relative_path: "a.txt",
        workspace_id: "ws-other",
        epoch: 1
      })

    refute stale.assigns.file_viewer.status == :ready

    encoded = inspect(NativeWorkspaceTree.render(socket.assigns.workspace_tree), limit: :infinity)
    assert encoded =~ "▸ " or encoded =~ "▾ "
  end

  defp tree_root do
    root = Path.join(System.tmp_dir!(), "tree_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "a_dir"))
    File.mkdir_p!(Path.join(root, "b_dir"))
    File.write!(Path.join(root, "a_dir/nested.txt"), "n")
    File.write!(Path.join(root, "b_dir/nested-b.txt"), "n")
    File.write!(Path.join(root, "a.txt"), "a")
    File.write!(Path.join(root, "b.txt"), "b")
    File.write!(Path.join(root, "c.txt"), "c")
    File.write!(Path.join(root, ".hidden"), "h")
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp ensure_tree(root) do
    Mob.Socket.new(HandbeanProbe.HomeScreen)
    |> assign(:workspace, %{"id" => "ws-1", "path" => root, "name" => "W"})
    |> assign(:workspace_tree, NativeWorkspaceTree.idle())
    |> assign(:file_viewer, HandbeanProbe.NativeFileViewer.new())
    |> assign(:pending_requests, HandbeanProbe.PendingRequests.new())
    |> NativeWorkspaceTree.ensure()
  end

  defp bound(socket, op) do
    tree = socket.assigns.workspace_tree
    Map.merge(%{workspace_id: tree.workspace_id, epoch: tree.epoch}, op)
  end

  defp flush_listed(socket, n) do
    Enum.reduce(1..n, socket, fn _, acc ->
      assert_receive {:file_tree_listed, payload}, 1_000
      NativeWorkspaceTree.handle_listed(acc, payload)
    end)
  end

  defp listed_payload(socket, relative_dir) do
    dir = socket.assigns.workspace_tree.dirs[relative_dir]
    tree = socket.assigns.workspace_tree

    %{
      epoch: tree.epoch,
      workspace_id: tree.workspace_id,
      relative_dir: relative_dir,
      offset: dir.offset,
      request: dir.request,
      result:
        {:ok,
         %{
           entries: [%{name: "ghost", kind: :file, relative_path: "ghost"}],
           next_offset: 1,
           offset: 0,
           truncated: false
         }}
    }
  end
end
