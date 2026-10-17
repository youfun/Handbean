defmodule HandbeanProbe.NativeWorkspaceOpenTest do
  use ExUnit.Case, async: false

  import Mob.Socket, only: [assign: 3]

  alias HandbeanProbe.HomeScreen.Requests
  alias HandbeanProbe.{NativeFileViewer, NativeWorkspaceOpen, PendingRequests}

  setup do
    previous_fake = Application.get_env(:handbean_probe, :platform_fake)

    on_exit(fn ->
      Application.delete_env(:handbean_probe, :workspace_io_start)

      if previous_fake,
        do: Application.put_env(:handbean_probe, :platform_fake, previous_fake),
        else: Application.delete_env(:handbean_probe, :platform_fake)
    end)

    :ok
  end

  test "timeline open requires the live conversation and workspace" do
    socket = socket_fixture()

    stale_conv =
      NativeWorkspaceOpen.request(
        socket,
        NativeWorkspaceOpen.spec(:timeline, "note.txt", "ws-1", "other")
      )

    refute NativeWorkspaceOpen.overlay?(stale_conv.assigns)
    assert stale_conv.assigns.notice
    refute_received {:workspace_open_ready, _, _}

    stale_ws =
      NativeWorkspaceOpen.request(
        socket,
        NativeWorkspaceOpen.spec(:timeline, "note.txt", "ws-other", "c1")
      )

    refute NativeWorkspaceOpen.overlay?(stale_ws.assigns)

    outside =
      NativeWorkspaceOpen.request(
        socket,
        NativeWorkspaceOpen.spec(:tree, "/etc/passwd", "ws-1")
      )

    refute NativeWorkspaceOpen.overlay?(outside.assigns)
    assert outside.assigns.notice
  end

  test "ready text stays metadata-only and close drops the old generation" do
    socket = socket_fixture()

    socket =
      NativeWorkspaceOpen.request(
        socket,
        NativeWorkspaceOpen.spec(:timeline, "note.txt", "ws-1", "c1")
      )

    assert_receive {:workspace_open_ready, gen, result}, 1_000
    opened = NativeWorkspaceOpen.handle_ready(socket, gen, result)
    assert opened.assigns.file_viewer.status == :ready
    node = NativeFileViewer.viewer_node(opened.assigns.file_viewer)
    refute Map.has_key?(node.props, :text)

    closed = NativeWorkspaceOpen.close(opened)
    assert closed.assigns.file_viewer.status == :closed
    assert NativeWorkspaceOpen.generation(closed) > gen

    stale = NativeWorkspaceOpen.handle_ready(closed, gen, result)
    refute NativeWorkspaceOpen.overlay?(stale.assigns)
  end

  test "share and system open reject a viewer from another workspace" do
    socket = socket_fixture()

    socket =
      NativeWorkspaceOpen.request(
        socket,
        NativeWorkspaceOpen.spec(:timeline, "note.txt", "ws-1", "c1")
      )

    assert_receive {:workspace_open_ready, gen, result}, 1_000
    opened = NativeWorkspaceOpen.handle_ready(socket, gen, result)

    swapped =
      assign(opened, :workspace, %{"id" => "ws-other", "path" => "/tmp/other", "name" => "O"})

    rejected = NativeWorkspaceOpen.share(swapped)
    assert rejected.assigns.notice
    refute_received {:platform_export, _}

    {_gen, stale} = Requests.bump(opened, :workspace_open)

    rejected = NativeWorkspaceOpen.system_open(stale)
    assert rejected.assigns.notice
    refute_received {:platform_export, _}
  end

  test "composer reset does not make the opened file stale" do
    test = self()

    Application.put_env(:handbean_probe, :platform_fake, fn req, _ ->
      send(test, {:platform_export, req})
      {:ok, :async}
    end)

    socket = socket_fixture()

    socket =
      NativeWorkspaceOpen.request(
        socket,
        NativeWorkspaceOpen.spec(:timeline, "note.txt", "ws-1", "c1")
      )

    assert_receive {:workspace_open_ready, gen, result}, 1_000
    opened = NativeWorkspaceOpen.handle_ready(socket, gen, result)
    assert opened.assigns.file_viewer.identity.generation == gen

    # Sending a message / switching conversation bumps the composer scope only.
    {_gen, bumped} = Requests.bump(opened, :composer)

    after_open = NativeWorkspaceOpen.system_open(bumped)
    refute after_open.assigns.notice
    assert_received {:platform_export, %{op: "platform_export", payload: payload}}
    assert payload["relative_path"] == "note.txt"
    assert PendingRequests.size(after_open.assigns.pending_requests) == 1

    after_share = NativeWorkspaceOpen.share(bumped)
    refute after_share.assigns.notice
    assert_received {:platform_export, %{op: "platform_export"}}
  end

  test "start_child failure is visible and not left loading" do
    Application.put_env(:handbean_probe, :workspace_io_start, fn _ -> {:error, :noproc} end)
    socket = socket_fixture()

    failed =
      NativeWorkspaceOpen.request(
        socket,
        NativeWorkspaceOpen.spec(:timeline, "note.txt", "ws-1", "c1")
      )

    refute NativeWorkspaceOpen.overlay?(failed.assigns)
    assert failed.assigns.notice
    refute_received {:workspace_open_ready, _, _}
  end

  defp socket_fixture do
    root = Path.join(System.tmp_dir!(), "open_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "note.txt"), "hello")
    File.write!(Path.join(root, "doc.pdf"), "%PDF")
    on_exit(fn -> File.rm_rf!(root) end)

    Mob.Socket.new(HandbeanProbe.HomeScreen)
    |> assign(:workspace, %{"id" => "ws-1", "path" => root, "name" => "W"})
    |> assign(:chat, %{conversation: %{"id" => "c1"}})
    |> assign(:file_viewer, NativeFileViewer.new())
    |> assign(:pending_requests, PendingRequests.new())
    |> assign(:error, nil)
  end
end
