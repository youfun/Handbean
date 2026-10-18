defmodule HandbeanProbe.NativeArtifactDeliveryTest do
  use ExUnit.Case, async: false

  alias Handbean.ExportSnapshot.Binding
  alias HandbeanProbe.{NativeArtifactDelivery, PendingRequests}

  setup do
    unless Process.whereis(Binding) do
      {:ok, _} = Binding.start_link([])
    end

    previous = Application.get_env(:handbean_probe, :platform_fake)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:handbean_probe, :platform_fake, previous),
        else: Application.delete_env(:handbean_probe, :platform_fake)
    end)

    :ok
  end

  test "repeat approval export for the same seq is deduped" do
    test = self()
    dir = tmp_ws()
    File.write!(Path.join(dir, "a.txt"), "a")

    Application.put_env(:handbean_probe, :platform_fake, fn req, _ ->
      send(test, {:export, req.request_id})
      {:ok, :async}
    end)

    chat =
      chat(dir, "c1", 1, [
        %{
          "tool_call_id" => "t1",
          "tool_name" => "open_file",
          "arguments" => %{"path" => "a.txt"}
        }
      ])

    socket = socket(dir, chat)

    socket = NativeArtifactDelivery.reconcile_approval_exports(socket, chat)
    socket = NativeArtifactDelivery.reconcile_approval_exports(socket, chat)

    assert_received {:export, _}
    refute_received {:export, _}
    assert MapSet.size(socket.assigns.approval_export_inflight) == 1
  end

  test "matching approval binding is restored without exporting again" do
    dir = tmp_ws()
    chat = chat(dir, "c-restore", 4, [file_request("t-restore", "a.txt")])

    Binding.put("c-restore", "t-restore", %{
      snapshot_id: "snap-restore",
      owner_request_id: "owner-restore",
      approval_seq: 4,
      relative_path: "a.txt",
      workspace_path: dir,
      action: :open_file
    })

    Application.put_env(:handbean_probe, :platform_fake, fn req, _ ->
      flunk("must not call the platform for matching binding: #{inspect(req)}")
    end)

    socket = NativeArtifactDelivery.reconcile_approval_exports(socket(dir, chat), chat)

    assert socket.assigns.approval_snapshots["t-restore"].snapshot_id == "snap-restore"
    assert MapSet.size(socket.assigns.approval_export_inflight) == 0
    :ok = Binding.clear_conversation("c-restore")
  end

  test "stale approval binding is cleaned and missing export is started once" do
    test = self()
    dir = tmp_ws()
    File.write!(Path.join(dir, "a.txt"), "current")
    chat = chat(dir, "c-reconcile", 8, [file_request("t-reconcile", "a.txt")])

    Binding.put("c-reconcile", "t-reconcile", %{
      snapshot_id: "snap-stale",
      owner_request_id: "owner-stale",
      approval_seq: 7,
      relative_path: "a.txt",
      workspace_path: dir,
      action: :open_file
    })

    Application.put_env(:handbean_probe, :platform_fake, fn req, _ ->
      send(test, {:platform, req})
      {:ok, :async}
    end)

    socket = NativeArtifactDelivery.reconcile_approval_exports(socket(dir, chat), chat)
    socket = NativeArtifactDelivery.reconcile_approval_exports(socket, chat)

    assert_received {:platform,
                     %{op: "platform_cleanup", payload: %{"snapshot_id" => "snap-stale"}}}

    assert_received {:platform, %{op: "platform_export", request_id: export_request_id}}
    refute_received {:platform, %{op: "platform_export"}}
    assert :error = Binding.fetch("c-reconcile", "t-reconcile")

    ctx = PendingRequests.ctx(socket.assigns.pending_requests, export_request_id)
    assert ctx.approval_seq == 8
    assert ctx.tool_call_id == "t-reconcile"
  end

  test "completed approval export records the batch identity" do
    test = self()
    dir = tmp_ws()
    File.write!(Path.join(dir, "a.txt"), "a")
    chat = chat(dir, "c-bind", 12, [file_request("t-bind", "a.txt")])

    Application.put_env(:handbean_probe, :platform_fake, fn req, _ ->
      send(test, {:export_request, req.request_id})
      {:ok, :async}
    end)

    socket = NativeArtifactDelivery.reconcile_approval_exports(socket(dir, chat), chat)
    assert_received {:export_request, request_id}
    ctx = PendingRequests.ctx(socket.assigns.pending_requests, request_id)

    socket =
      NativeArtifactDelivery.handle_result(
        socket,
        ctx,
        {:ok,
         %{
           "snapshot_id" => "snap-bind",
           "owner_request_id" => "owner-bind",
           "relative_path" => "a.txt"
         }}
      )

    assert socket.assigns.approval_snapshots["t-bind"].approval_seq == 12
    assert {:ok, %{approval_seq: 12}} = Binding.fetch("c-bind", "t-bind")
    :ok = Binding.clear_conversation("c-bind")
  end

  test "stale export results clean the returned host snapshot without overwriting current state" do
    test = self()
    dir = tmp_ws()
    chat = chat(dir, "c-now", 9, [])

    Application.put_env(:handbean_probe, :platform_fake, fn req, _ ->
      send(test, {:platform, req})
      {:ok, :async}
    end)

    socket =
      socket(dir, chat)
      |> Map.update!(
        :assigns,
        &Map.put(&1, :approval_snapshots, %{"t1" => %{snapshot_id: "keep"}})
      )

    stale = %{
      conversation_id: "c-old",
      approval_seq: 1,
      tool_call_id: "t1",
      workspace_path: dir,
      request_id: "old"
    }

    refute NativeArtifactDelivery.current_export_target?(socket, stale)

    socket =
      NativeArtifactDelivery.handle_result(
        socket,
        Map.put(stale, :kind, :approval_export),
        {:ok, %{"snapshot_id" => "stale"}}
      )

    assert socket.assigns.approval_snapshots["t1"].snapshot_id == "keep"
    assert :error = Binding.fetch("c-old", "t1")

    assert_received {:platform,
                     %{
                       op: "platform_cleanup",
                       payload: %{
                         "snapshot_id" => "stale",
                         "owner_request_id" => "old"
                       }
                     }}
  end

  test "duplicate current export result cleans the newly returned host snapshot" do
    test = self()
    dir = tmp_ws()
    chat = chat(dir, "c-current", 3, [file_request("t-current", "a.txt")])

    Application.put_env(:handbean_probe, :platform_fake, fn req, _ ->
      send(test, {:platform, req})
      {:ok, :async}
    end)

    socket =
      socket(dir, chat)
      |> Map.update!(:assigns, fn assigns ->
        Map.put(assigns, :approval_snapshots, %{
          "t-current" => %{snapshot_id: "snap-keep", owner_request_id: "owner-keep"}
        })
      end)

    ctx = %{
      kind: :approval_export,
      conversation_id: "c-current",
      approval_seq: 3,
      tool_call_id: "t-current",
      workspace_path: dir,
      relative_path: "a.txt",
      action: :open_file,
      request_id: "request-new"
    }

    socket =
      NativeArtifactDelivery.handle_result(
        socket,
        ctx,
        {:ok, %{"snapshot_id" => "snap-new", "owner_request_id" => "owner-new"}}
      )

    assert socket.assigns.approval_snapshots["t-current"].snapshot_id == "snap-keep"

    assert_received {:platform,
                     %{
                       op: "platform_cleanup",
                       payload: %{
                         "snapshot_id" => "snap-new",
                         "owner_request_id" => "owner-new"
                       }
                     }}
  end

  test "superseded batch cleans old snapshots and late replies self-clean" do
    test = self()
    dir = tmp_ws()
    File.write!(Path.join(dir, "a.txt"), "a")
    old_chat = chat(dir, "c-batch", 4, [file_request("t-old", "a.txt")])
    new_chat = chat(dir, "c-batch", 5, [file_request("t-new", "a.txt")])
    old_key = NativeArtifactDelivery.export_key("c-batch", 4, "t-old")

    Binding.put("c-batch", "t-old", %{
      snapshot_id: "snap-old",
      owner_request_id: "owner-old",
      approval_seq: 4,
      relative_path: "a.txt",
      workspace_path: dir,
      action: :open_file
    })

    Application.put_env(:handbean_probe, :platform_fake, fn req, _ ->
      send(test, {:platform, req})
      {:ok, :async}
    end)

    socket =
      socket(dir, old_chat)
      |> HandbeanProbe.HomeScreen.Requests.track("request-old", :approval_export, %{
        conversation_id: "c-batch",
        approval_seq: 4,
        tool_call_id: "t-old",
        workspace_path: dir,
        relative_path: "a.txt",
        action: :open_file
      })
      |> Map.update!(:assigns, fn assigns ->
        assigns
        |> Map.put(:approval_snapshots, %{
          "t-old" => %{
            snapshot_id: "snap-old",
            owner_request_id: "owner-old",
            approval_seq: 4
          }
        })
        |> Map.put(:approval_export_inflight, MapSet.new([old_key]))
      end)

    socket = NativeArtifactDelivery.supersede_approval_batch(socket)

    assert_received {:platform,
                     %{op: "platform_cancel", payload: %{"target_request_id" => "request-old"}}}

    assert_received {:platform,
                     %{op: "platform_cleanup", payload: %{"snapshot_id" => "snap-old"}}}

    assert :error = Binding.fetch("c-batch", "t-old")
    assert socket.assigns.approval_snapshots == %{}
    assert socket.assigns.approval_export_inflight == MapSet.new()

    socket = %{socket | assigns: Map.put(socket.assigns, :chat, new_chat)}
    socket = NativeArtifactDelivery.reconcile_approval_exports(socket, new_chat)
    assert_received {:platform, %{op: "platform_export"}}

    old_ctx = PendingRequests.ctx(socket.assigns.pending_requests, "request-old")

    socket =
      NativeArtifactDelivery.handle_result(
        socket,
        old_ctx,
        {:ok, %{"snapshot_id" => "snap-late", "owner_request_id" => "owner-late"}}
      )

    assert_received {:platform,
                     %{op: "platform_cleanup", payload: %{"snapshot_id" => "snap-late"}}}

    refute Map.has_key?(socket.assigns.approval_snapshots, "t-old")
  end

  test "skipped file bindings are cleaned while selected binding remains consumable" do
    test = self()
    dir = tmp_ws()
    chat = chat(dir, "c-multi", 6, [])

    selected = %{
      snapshot_id: "snap-selected",
      owner_request_id: "owner-selected",
      approval_seq: 6,
      relative_path: "a.txt",
      workspace_path: dir,
      action: :open_file
    }

    skipped = %{
      snapshot_id: "snap-skipped",
      owner_request_id: "owner-skipped",
      approval_seq: 6,
      relative_path: "b.txt",
      workspace_path: dir,
      action: :share_file
    }

    :ok = Binding.put("c-multi", "t-selected", selected)
    :ok = Binding.put("c-multi", "t-skipped", skipped)

    Application.put_env(:handbean_probe, :platform_fake, fn req, _ ->
      send(test, {:platform, req})
      {:ok, :async}
    end)

    socket =
      socket(dir, chat)
      |> Map.update!(:assigns, fn assigns ->
        Map.put(assigns, :approval_snapshots, %{
          "t-selected" => selected,
          "t-skipped" => skipped
        })
      end)
      |> NativeArtifactDelivery.cleanup_skipped_approval_bindings("c-multi", [
        %{"tool_call_id" => "t-skipped", "tool_name" => "share_file"}
      ])

    assert {:ok, ^selected} = Binding.fetch("c-multi", "t-selected")
    assert :error = Binding.fetch("c-multi", "t-skipped")
    assert socket.assigns.approval_snapshots == %{"t-selected" => selected}

    assert_received {:platform,
                     %{op: "platform_cleanup", payload: %{"snapshot_id" => "snap-skipped"}}}

    refute_received {:platform,
                     %{op: "platform_cleanup", payload: %{"snapshot_id" => "snap-selected"}}}

    :ok = Binding.clear_conversation("c-multi")
  end

  test "cleanup keeps approved snapshots until consume" do
    dir = tmp_ws()

    Binding.put("c-keep", "t-keep", %{
      snapshot_id: "snap",
      relative_path: "a.txt",
      workspace_path: dir,
      action: :open_file
    })

    chat = %{conversation: %{"id" => "c-keep"}, pending_approval: nil, approval_seq: nil}
    socket = socket(dir, chat)

    socket = %{
      socket
      | assigns:
          Map.put(socket.assigns, :approval_snapshots, %{
            "t-keep" => %{snapshot_id: "snap", owner_request_id: "o"}
          })
    }

    Application.put_env(:handbean_probe, :platform_fake, fn req, _ ->
      flunk("must not cleanup #{inspect(req)}")
    end)

    socket = NativeArtifactDelivery.cleanup_bindings(socket)
    assert {:ok, _} = Binding.fetch("c-keep", "t-keep")
    assert socket.assigns.approval_snapshots["t-keep"].snapshot_id == "snap"
  end

  test "file action authorizes once through Platform and tracks the trimmed path" do
    test = self()
    dir = tmp_ws()
    File.write!(Path.join(dir, "report.pdf"), "%PDF")

    Application.put_env(:handbean_probe, :platform_fake, fn req, _ ->
      send(test, {:platform_export, req})
      {:ok, :async}
    end)

    socket = socket(dir, chat(dir, "c1", 1, []))
    socket = NativeArtifactDelivery.start_file_action(socket, :open_file, "  report.pdf  ")

    assert socket.assigns.notice == nil
    assert_received {:platform_export, %{op: "platform_export", payload: payload} = req}
    refute_received {:platform_export, _}
    assert payload["relative_path"] == "report.pdf"
    assert payload["path"] == Path.join(dir, "report.pdf")
    assert payload["workspace_path"] == dir

    assert %{kind: :delivery_export, next: :open_file, relative_path: "report.pdf"} =
             PendingRequests.ctx(socket.assigns.pending_requests, req.request_id)
  end

  test "file action rejects an unauthorized path without a platform request" do
    dir = tmp_ws()

    Application.put_env(:handbean_probe, :platform_fake, fn req, _ ->
      flunk("must not export #{inspect(req)}")
    end)

    socket = socket(dir, chat(dir, "c1", 1, []))

    missing = NativeArtifactDelivery.start_file_action(socket, :share_file, "missing.txt")
    assert is_binary(missing.assigns.notice.text)
    assert PendingRequests.empty?(missing.assigns.pending_requests)

    traversal = NativeArtifactDelivery.start_file_action(socket, :open_file, "../etc/passwd")
    assert is_binary(traversal.assigns.notice.text)
    assert PendingRequests.empty?(traversal.assigns.pending_requests)
  end

  test "human_error never raises on tuple or unexpected reasons" do
    for reason <- [{:not_regular, :directory}, {:error, :enoent}, %{code: 1}, :unknown_reason] do
      assert is_binary(NativeArtifactDelivery.human_error(reason))
    end

    assert NativeArtifactDelivery.human_error(:invalid_url) =~ "http"
  end

  test "timeline_target converts an absolute path with the current workspace" do
    ws = "/tmp/native-delivery-ws"
    abs = Path.join(ws, "out/report.pdf")

    assert {:file, "out/report.pdf"} =
             NativeArtifactDelivery.timeline_target(
               %{"tool_name" => "write", "input" => %{"file_path" => abs}},
               ws
             )

    assert NativeArtifactDelivery.timeline_target(
             %{"tool_name" => "write", "input" => %{"file_path" => "/etc/passwd"}},
             ws
           ) == nil
  end

  defp file_request(id, path) do
    %{
      "tool_call_id" => id,
      "tool_name" => "open_file",
      "arguments" => %{"path" => path}
    }
  end

  defp tmp_ws do
    dir = Path.join(System.tmp_dir!(), "ndel_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  defp chat(dir, id, seq, requests) do
    %{
      conversation: %{"id" => id},
      approval_seq: seq,
      pending_approval: %{"action_requests" => requests},
      workspace_path: dir
    }
  end

  defp socket(dir, chat) do
    %{
      assigns: %{
        chat: chat,
        workspace: %{"id" => "ws", "path" => dir},
        pending_requests: PendingRequests.new(),
        approval_snapshots: %{},
        approval_export_inflight: MapSet.new()
      }
    }
  end
end
