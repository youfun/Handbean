defmodule HandbeanProbe.HomeScreenShareDeliveryTest do
  use HandbeanProbe.HomeScreenCase

  alias Handbean.ArtifactDelivery
  alias HandbeanProbe.{HomeScreen, NativeChat, PendingRequests}

  test "Android share is reviewed before it is added to the unsent draft", %{view: view} do
    root = share_root!("share_ui")

    id = Ecto.UUID.generate()

    write_share_fixture!(id, %{
      "state" => "pending_review",
      "subject" => "页面标题",
      "text" => "https://example.com/共享🙂",
      "attachments" => [],
      "consumption" => "structured_attachments"
    })

    view = info(view, {:share_intake_ready, id, "pending_review"})
    assert assigns(view).chat == nil
    assert assigns(view).draft == ""
    assert text(view) =~ "https://example.com/共享🙂"
    assert text(view) =~ gettext("Add to current draft")
    workspace_name = assigns(view).workspace["name"] || gettext("Workspace")

    assert text(view) =~
             gettext("Current target: %{workspace} · %{conversation}",
               workspace: workspace_name,
               conversation: gettext("New conversation")
             )

    assert text(view) =~ gettext("System share")

    view = info(view, {:tap, {:share_confirm, id}})
    assert assigns(view).chat == nil
    assert assigns(view).draft =~ "https://example.com/共享🙂"
    assert assigns(view).composer_mode == :chat
    assert MapSet.member?(assigns(view).merged_intake_ids, id)
    refute text(view) =~ gettext("Write review")
    refute text(view) =~ gettext("Generate review")
  end

  test "mount scan lists durable share when ready event was dropped", %{view: view} do
    root = share_root!("share_pre")

    id = Ecto.UUID.generate()

    write_share_fixture!(id, %{
      "state" => "pending_review",
      "text" => "prestart share",
      "attachments" => []
    })

    {:ok, socket} = HomeScreen.mount(%{}, %{}, view.socket)
    view = settle(%{view | socket: socket})
    assert text(view) =~ "prestart share"
    assert Enum.any?(assigns(view).share_intakes, &(&1["intake_id"] == id))
  end

  test "storage_error notify is visible", %{view: view} do
    view = info(view, {:share_intake_ready, Ecto.UUID.generate(), "storage_error"})

    assert notice_text(view) =~
             gettext("The share could not be written to local storage. Retry or free up space.")
  end

  test "share confirm merges draft without sending; ack is explicit", %{view: view} do
    root = share_root!("share_hs")

    id = Ecto.UUID.generate()

    write_share_fixture!(id, %{
      "state" => "pending_review",
      "text" => "from share",
      "attachments" => []
    })

    view = info(view, {:share_intake_ready, id, "pending_review"})
    assert text(view) =~ "from share"
    assert text(view) =~ gettext("Add to current draft")

    view = info(view, {:tap, {:share_confirm, id}})
    assert assigns(view).draft == "from share"
    assert MapSet.member?(assigns(view).merged_intake_ids, id)
    assert assigns(view).chat == nil
    assert {:ok, %{"state" => "merged_current_process"}} = HandbeanProbe.ShareIntake.get(id)

    view = info(view, {:tap, {:share_confirm, id}})
    assert assigns(view).draft == "from share"

    view = info(view, {:tap, :send})
    assert assigns(view).draft == "from share"
    assert notice_text(view) =~ send_failed()
    assert {:ok, %{"state" => "merged_current_process"}} = HandbeanProbe.ShareIntake.get(id)
    refute assigns(view).last_send_ack
  end

  test "share confirm from settings is not dispatched to ModelSettings", %{view: view} do
    root = share_root!("share_set")

    id = Ecto.UUID.generate()

    write_share_fixture!(id, %{
      "state" => "pending_review",
      "text" => "from settings page",
      "attachments" => []
    })

    view =
      view
      |> info({:share_intake_ready, id, "pending_review"})
      |> info({:tap, {:page, :settings}})
      |> info({:tap, {:share_confirm, id}})

    assert assigns(view).draft == "from settings page"
    assert assigns(view).page == :chat
    assert {:ok, %{"state" => "merged_current_process"}} = HandbeanProbe.ShareIntake.get(id)
  end

  test "failed merge persistence leaves draft untouched", %{view: view} do
    root = share_root!("share_failm")

    id = Ecto.UUID.generate()

    write_share_fixture!(id, %{
      "state" => "pending_review",
      "text" => "must not merge",
      "attachments" => []
    })

    dir = Path.join(root, id)
    File.chmod!(dir, 0o500)
    on_exit(fn -> File.chmod!(dir, 0o700) end)

    view =
      view
      |> info({:change, :draft, "original draft"})
      |> info({:share_intake_ready, id, "pending_review"})
      |> info({:tap, {:share_confirm, id}})

    assert assigns(view).draft == "original draft"
    refute MapSet.member?(assigns(view).merged_intake_ids, id)

    assert notice_text(view) =~
             gettext("The share confirmation could not be saved: %{reason}", reason: "")

    assert {:ok, %{"state" => "pending_review"}} = HandbeanProbe.ShareIntake.get(id)
  end

  test "importing intake cannot confirm into draft", %{view: view} do
    root = share_root!("share_imp")

    id = Ecto.UUID.generate()

    write_share_fixture!(id, %{"state" => "importing", "text" => "in flight", "attachments" => []})

    view =
      view
      |> info({:change, :draft, "keep"})
      |> info({:tap, {:share_confirm, id}})

    assert assigns(view).draft == "keep"
    refute MapSet.member?(assigns(view).merged_intake_ids, id)
    assert {:ok, %{"state" => "importing"}} = HandbeanProbe.ShareIntake.get(id)
  end

  test "failed mark_send_pending aborts send without coordinator", %{view: view} do
    missing = Ecto.UUID.generate()
    view = info(view, {:change, :draft, "should not send"})

    socket = %{
      view.socket
      | assigns: Map.put(view.socket.assigns, :merged_intake_ids, MapSet.new([missing]))
    }

    {:noreply, socket} = HomeScreen.handle_info({:tap, :send}, socket)
    view = settle(%{view | socket: socket})

    assert assigns(view).draft == "should not send"

    assert notice_text(view) =~
             gettext("The share send state could not be saved: %{reason}", reason: "")

    refute assigns(view).last_send_ack
    assert assigns(view).chat
    assert NativeChat.transcript(assigns(view).chat.conversation["id"]) == []
  end

  test "overflow share notify is visible and does not add review", %{view: view} do
    view = info(view, {:share_intake_ready, Ecto.UUID.generate(), "too_many_pending"})

    assert notice_text(view) =~
             gettext("Pending shares are full (max %{max}). Confirm or discard one first.",
               max: HandbeanProbe.ShareIntake.max_pending()
             )

    assert assigns(view).share_intakes == []
  end

  test "workspace copy confirm is queued and late discard rolls back", %{view: view} do
    root = share_root!("share_ws_hs")

    workspace = assigns(view).workspace
    a = Ecto.UUID.generate()
    b = Ecto.UUID.generate()
    source_dir = Path.join(root, a)
    File.mkdir_p!(source_dir)
    source = Path.join(source_dir, "notes.md")
    File.write!(source, "shared notes")

    write_share_fixture!(a, %{
      "state" => "pending_review",
      "consumption" => "workspace_copy",
      "created_seq" => 1,
      "text" => "first share",
      "files" => [
        %{"status" => "ready", "name" => "notes.md", "path" => source, "size" => 12}
      ]
    })

    write_share_fixture!(b, %{
      "state" => "pending_review",
      "consumption" => "workspace_copy",
      "created_seq" => 2,
      "text" => "second share",
      "files" => []
    })

    view =
      view
      |> info({:share_intake_ready, a, "pending_review"})
      |> info({:share_intake_ready, b, "pending_review"})

    assert text(view) =~ "first share"
    assert text(view) =~ "second share"

    view = info(view, {:tap, {:share_confirm, a}})
    assert Map.has_key?(assigns(view).share_confirming, a)
    assert Enum.any?(assigns(view).share_intakes, &(&1["intake_id"] == b))
    refute Enum.any?(assigns(view).share_intakes, &(&1["intake_id"] == a))
    assert assigns(view).chat == nil
    assert assigns(view).draft == ""

    Application.put_env(:handbean_probe, :share_io_notify, self())
    on_exit(fn -> Application.delete_env(:handbean_probe, :share_io_notify) end)

    view = info(view, {:tap, {:share_discard, a}})
    refute Map.has_key?(assigns(view).share_confirming, a)
    assert_receive {:share_rollback, ^a, :ok}, 1_000

    dest = Path.join([workspace["path"], ".handbean", "shared", a])
    File.mkdir_p!(dest)
    File.write!(Path.join(dest, "notes.md"), "shared notes")

    view =
      info(
        view,
        {:share_workspace_result,
         %{
           intake_id: a,
           target: HandbeanProbe.ShareConfirm.target_from(workspace, nil, a),
           result: {:ok, [".handbean/shared/#{a}/notes.md"]}
         }}
      )

    assert_receive {:share_rollback, ^a, :ok}, 1_000
    refute File.exists?(dest)
    assert assigns(view).draft == ""
    refute MapSet.member?(assigns(view).merged_intake_ids, a)
  end

  test "late workspace copy after workspace switch does not merge current draft", %{view: view} do
    root = share_root!("share_ws_switch")
    Application.put_env(:handbean_probe, :share_io_notify, self())
    on_exit(fn -> Application.delete_env(:handbean_probe, :share_io_notify) end)

    original = assigns(view).workspace
    a = Ecto.UUID.generate()
    source_dir = Path.join(root, a)
    File.mkdir_p!(source_dir)
    source = Path.join(source_dir, "notes.md")
    File.write!(source, "shared notes")

    write_share_fixture!(a, %{
      "state" => "pending_review",
      "consumption" => "workspace_copy",
      "created_seq" => 1,
      "text" => "switch share",
      "files" => [
        %{"status" => "ready", "name" => "notes.md", "path" => source, "size" => 12}
      ]
    })

    view = info(view, {:share_intake_ready, a, "pending_review"})
    view = info(view, {:tap, {:share_confirm, a}})
    target = assigns(view).share_confirming[a]
    assert target["workspace_path"] == original["path"]

    dest = Path.join([original["path"], ".handbean", "shared", a])
    File.mkdir_p!(dest)
    File.write!(Path.join(dest, "notes.md"), "shared notes")

    other = %{"id" => "ws-other", "path" => Path.join(root, "other_ws")}
    File.mkdir_p!(other["path"])

    socket = %{
      view.socket
      | assigns:
          view.socket.assigns
          |> Map.put(:workspace, other)
          |> Map.put(:draft, "typed after switch")
          |> Map.put(:chat, nil)
    }

    view = %{view | socket: socket}

    view =
      info(
        view,
        {:share_workspace_result,
         %{
           intake_id: a,
           target: target,
           result: {:ok, [".handbean/shared/#{a}/notes.md"]}
         }}
      )

    assert_receive {:share_rollback, ^a, :ok}, 1_000
    refute File.exists?(dest)
    assert assigns(view).draft == "typed after switch"
    refute MapSet.member?(assigns(view).merged_intake_ids, a)
    refute File.exists?(Path.join([other["path"], ".handbean", "shared", a]))
  end

  test "lost share send ack is visible and does not auto retry", %{view: view} do
    root = share_root!("share_lost")

    {:ok, conv} = Handbean.ConversationStore.create("default")

    id = Ecto.UUID.generate()

    write_share_fixture!(id, %{
      "state" => "send_pending",
      "send_attempt_id" => "never-written",
      "conversation_id" => conv["id"],
      "text" => "x"
    })

    view = info(view, {:share_intake_ready, id, "send_pending"})

    assert notice_text(view) =~
             gettext(
               "Send outcome unknown. Not resent automatically; check the conversation before deciding."
             )

    refute assigns(view).last_send_ack
    assert {:ok, %{"state" => "outcome_unknown"}} = HandbeanProbe.ShareIntake.get(id)
  end

  test "user delivery taps only send typed url or snapshot commands", %{view: view} do
    parent = self()

    install_platform_fake(fn req, _opts ->
      send(parent, {:platform_cmd, req})
      {:ok, :async}
    end)

    workspace = assigns(view).workspace
    File.write!(Path.join(workspace["path"], "report.pdf"), "%PDF")

    view = info(view, {:tap, {:delivery, :open_url, "file:///tmp/x"}})
    assert assigns(view).notice
    refute_received {:platform_cmd, _}

    view = info(view, {:tap, {:delivery, :open_url, "https://example.com/order"}})
    assert_receive {:platform_cmd, url_req}, 1_000
    assert url_req.op == "platform_open_url"
    assert url_req.payload["url"] == "https://example.com/order"
    refute Map.has_key?(url_req.payload, "action")

    view = info(view, {:tap, {:delivery, :share_file, "report.pdf"}})
    assert_receive {:platform_cmd, export_req}, 1_000
    assert export_req.op == "platform_export"
    assert export_req.payload["relative_path"] == "report.pdf"
    request_id = export_req.request_id

    view =
      info(
        view,
        {:platform, :result, request_id,
         {:ok,
          %{
            "snapshot_id" => "snap-9",
            "owner_request_id" => request_id,
            "display_name" => "report.pdf"
          }}}
      )

    assert_receive {:platform_cmd, share_req}, 1_000
    assert share_req.op == "platform_share_snapshot"
    assert share_req.payload["snapshot_id"] == "snap-9"
    refute Map.has_key?(share_req.payload, "component")

    view =
      info(
        view,
        {:platform, :result, share_req.request_id, {:ok, %{"outcome" => "chooser_presented"}}}
      )

    # Outcome copy is owned by sigil's Intent, not this backend.
    assert notice_text(view) =~ ArtifactDelivery.format_outcome("chooser_presented")
  end

  test "a delivery request past its deadline is cancelled and reported once", %{view: view} do
    parent = self()

    install_platform_fake(fn req, _opts ->
      send(parent, {:platform_cmd, req})
      {:ok, :async}
    end)

    Application.put_env(:handbean_probe, :android_intent_await_ms, 0)
    on_exit(fn -> Application.delete_env(:handbean_probe, :android_intent_await_ms) end)

    view = info(view, {:tap, {:delivery, :open_url, "https://example.com/slow"}})
    assert_receive {:platform_cmd, %{op: "platform_open_url", request_id: request_id}}, 1_000
    assert PendingRequests.has?(assigns(view).pending_requests, request_id)

    tag = PendingRequests.timeout_message()
    assert_receive {^tag, ^request_id}, 1_000
    view = info(view, {tag, request_id})

    refute PendingRequests.has?(assigns(view).pending_requests, request_id)
    assert_receive {:platform_cmd, %{op: "platform_cancel", payload: payload}}, 1_000
    assert payload["target_request_id"] == request_id

    assert notice_text(view) =~
             gettext("The system operation did not answer in time and was cancelled.")

    # A late host reply for the expired request is dropped without a second notice.

    view =
      info(view, {:engine_result, %{request_id: request_id, result: ~s({"outcome":"opened"})}})

    refute (notice_text(view) || "") =~ ArtifactDelivery.format_outcome("opened")
  end

  test "an engine_result whose generation does not match the request is dropped", %{view: view} do
    parent = self()

    install_platform_fake(fn req, _opts ->
      send(parent, {:platform_cmd, req})
      {:ok, :async}
    end)

    view = info(view, {:tap, {:delivery, :open_url, "https://example.com/gen"}})
    assert_receive {:platform_cmd, %{op: "platform_open_url"} = req}, 1_000

    stale =
      info(
        view,
        {:engine_result,
         %{
           request_id: req.request_id,
           generation: req.generation + 1,
           result: ~s({"outcome":"opened"})
         }}
      )

    refute (notice_text(stale) || "") =~ ArtifactDelivery.format_outcome("opened")
    # The mismatching reply consumed the entry: correlation is one-shot.
    refute PendingRequests.has?(assigns(stale).pending_requests, req.request_id)

    fresh =
      info(
        view,
        {:engine_result,
         %{
           request_id: req.request_id,
           generation: req.generation,
           result: ~s({"outcome":"opened"})
         }}
      )

    assert notice_text(fresh) =~ ArtifactDelivery.format_outcome("opened")
  end
end
