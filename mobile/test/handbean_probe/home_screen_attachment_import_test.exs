defmodule HandbeanProbe.HomeScreenAttachmentImportTest do
  use HandbeanProbe.HomeScreenCase

  alias HandbeanProbe.{HomeScreen, PendingRequests}
  alias HandbeanProbe.HomeScreenCase.IOSAdapter

  test "late import receipts after cancel do not open a workspace", %{view: view, dir: dir} do
    view = info(view, {:tap, {:page, :workspace}})
    view = info(view, {:tap, :start_import})
    request_id = assigns(view).workspaces.import.request_id
    assert request_id
    current = assigns(view).workspace["id"]
    view = info(view, {:tap, :cancel_import})

    dest = Path.join(HandbeanProbe.NativeWorkspaces.imported_root(), request_id)
    File.mkdir_p!(dest)
    File.write!(Path.join(dest, "copied.txt"), "payload")

    view =
      info(view, {:files, :picked, [%{path: dest, name: "Late", request_id: request_id}]})

    assert assigns(view).workspace["id"] == current
    refute Enum.any?(Handbean.WorkspaceStore.list(), &(&1["name"] == "Late"))
    refute File.dir?(dest)
    assert File.dir?(dir)
  end

  test "platform begin starts a typed Request and the C wire map has required keys", %{view: view} do
    parent = self()

    install_platform_fake(fn req, _opts ->
      send(parent, {:platform_started, req, HandbeanProbe.Platform.Nif.wire_map(req)})
      {:ok, :async}
    end)

    import_payload = %{
      "path" => "/cache/controlled_import/draft/note.ex",
      "display_name" => "note.ex",
      "mime" => "text/x-source"
    }

    view = info(view, {:platform, :begin, :import, import_payload})
    request_id = assigns(view).last_platform_request
    generation = composer_generation(view)
    assert is_binary(request_id)
    assert PendingRequests.has?(assigns(view).pending_requests, request_id)

    assert_receive {:platform_started, req, wired}, 1_000
    assert %HandbeanProbe.Platform.Request{} = req
    assert req.op == "platform_import"
    assert req.request_id == request_id
    assert req.generation == generation
    assert is_pid(req.caller)
    assert req.payload["path"] == import_payload["path"]
    assert req.payload["display_name"] == "note.ex"
    assert {:ok, payload} = Jason.decode(wired.payload)
    assert payload["op"] == "platform_import"
    assert payload["path"] == import_payload["path"]
    assert Map.keys(wired) |> Enum.sort() == [:caller, :generation, :op, :payload, :request_id]
    assert is_binary(wired.request_id) and wired.request_id != ""
    assert is_integer(wired.generation)
    assert is_pid(wired.caller)

    pending_after_import = assigns(view).pending_requests
    view = info(view, {:platform, :begin, :export})
    assert assigns(view).pending_requests == pending_after_import
    assert assigns(view).notice

    assert {:error, :unknown_op} =
             HandbeanProbe.Platform.Request.for_kind(
               :camera,
               %{
                 request_id: request_id,
                 composer_generation: generation,
                 workspace_id: "default",
                 conversation_id: nil
               },
               self()
             )
  end

  test "platform start failure does not leave a pending request", %{view: view} do
    install_platform_fake(fn _req, _opts -> {:error, :host_unbound} end)

    before = PendingRequests.entries(assigns(view).pending_requests)
    view = info(view, {:platform, :begin, :import, %{"path" => "/cache/controlled_import/a.txt"}})
    assert PendingRequests.entries(assigns(view).pending_requests) == before
    assert assigns(view).last_platform_request == nil
    assert assigns(view).notice
  end

  test "fake import joins the current draft and stale results are ignored", %{view: view} do
    parent = self()

    install_platform_fake(fn req, _opts ->
      send(parent, {:platform_cmd, req})
      {:ok, :async}
    end)

    dir = Path.join(System.tmp_dir!(), "native_import_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "note.ex")
    File.write!(path, "defmodule Note do\nend\n")

    view =
      info(view, {:platform, :begin, :import, %{"path" => path, "display_name" => "note.ex"}})

    request_id = assigns(view).last_platform_request
    generation = composer_generation(view)
    assert_receive {:platform_cmd, %{op: "platform_import"}}, 1_000

    imported = %Handbean.Attachments.Imported{
      attachment_id: "att-live",
      source: :test,
      display_name: "note.ex",
      canonical_type: "text/x-source",
      size_bytes: File.stat!(path).size,
      controlled_path: path
    }

    view = info(view, {:platform, :result, request_id, {:ok, imported}})
    assert length(assigns(view).pending_attachments) == 1
    assert text(view) =~ "note.ex"

    view = info(view, {:tap, :new_chat})
    assert composer_generation(view) > generation
    assert assigns(view).pending_attachments == []
    assert PendingRequests.by_kind(assigns(view).pending_requests, :import) == []
    assert File.exists?(path)

    view = info(view, {:platform, :result, request_id, {:ok, imported}})
    assert assigns(view).pending_attachments == []
    assert File.exists?(path)
  end

  test "image draft thumbs open a local preview without sending", %{view: view} do
    parent = self()

    install_platform_fake(fn req, _opts ->
      send(parent, {:platform_cmd, req})
      {:ok, :async}
    end)

    dir = Path.join(System.tmp_dir!(), "native_img_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "shot.png")

    File.write!(
      path,
      <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8,
        6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 248, 207, 192,
        240, 31, 0, 5, 0, 1, 253, 46, 43, 34, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>
    )

    view =
      info(view, {:platform, :begin, :import, %{"path" => path, "display_name" => "shot.png"}})

    request_id = assigns(view).last_platform_request

    imported = %Handbean.Attachments.Imported{
      attachment_id: "img-live",
      source: :test,
      display_name: "shot.png",
      canonical_type: "image/png",
      size_bytes: File.stat!(path).size,
      controlled_path: path
    }

    view = info(view, {:platform, :result, request_id, {:ok, imported}})
    assert length(assigns(view).pending_attachments) == 1
    assert assigns(view).composer_open_id == nil
    refute assigns(view).chat && assigns(view).chat.running

    view = info(view, {:tap, {:open_draft_image, "img-live"}})
    assert assigns(view).composer_open_id == "img-live"
    assert text(view) =~ "shot.png"
    assert text(view) =~ "image/png"
    refute assigns(view).chat && assigns(view).chat.running

    view = info(view, {:tap, :close_draft_image})
    assert assigns(view).composer_open_id == nil
    assert length(assigns(view).pending_attachments) == 1
  end

  test "restored sent images open from message and attachment ids without sending", %{
    view: view
  } do
    workspace = assigns(view).workspace
    {:ok, conv} = Handbean.ConversationStore.create(workspace["id"])

    dest =
      Path.join(
        Handbean.Uploads.ensure_conversation_dir!(workspace["path"], conv["id"]),
        "sent-1.png"
      )

    File.write!(
      dest,
      <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8,
        6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 248, 207, 192,
        240, 31, 0, 5, 0, 1, 253, 46, 43, 34, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>
    )

    relative = Path.join([".handbean", "uploads", conv["id"], "sent-1.png"])

    {:ok, entry} =
      Handbean.Agent.TranscriptPersistence.append_inbound(conv["id"], "历史图片",
        attachments: [
          %{
            "id" => "sent-1",
            "kind" => "image",
            "mime_type" => "image/png",
            "filename" => "hist.png",
            "relative_path" => relative
          }
        ],
        inbound_id: "sent-in"
      )

    view = info(view, {:tap, {:conversation, conv["id"]}})
    chat = assigns(view).chat
    assert chat.workspace_id == workspace["id"]
    assert chat.workspace_path == workspace["path"]
    refute chat.running
    assert Enum.any?(chat.entries, &(&1["id"] == entry["id"]))

    view = info(view, {:tap, {:open_sent_image, entry["id"], "sent-1"}})
    assert assigns(view).timeline_open == %{message_id: entry["id"], attachment_id: "sent-1"}
    assert assigns(view).composer_open_id == nil
    assert text(view) =~ "hist.png"
    assert text(view) =~ "image/png"
    refute assigns(view).chat.running

    view = info(view, {:tap, :close_sent_image})
    assert assigns(view).timeline_open == nil
  end

  test "switching drafts cancels pending ops and only deletes importer-owned files", %{
    view: view
  } do
    parent = self()

    install_platform_fake(fn req, _opts ->
      send(parent, {:platform_cmd, req})
      {:ok, :async}
    end)

    owned = Path.join(System.tmp_dir!(), "owned_import_#{System.unique_integer([:positive])}")
    File.mkdir_p!(owned)
    owned_path = Path.join(owned, "kept.ex")
    File.write!(owned_path, "defmodule Kept do\nend\n")

    foreign = Path.join(System.tmp_dir!(), "foreign_import_#{System.unique_integer([:positive])}")
    File.mkdir_p!(foreign)
    foreign_path = Path.join(foreign, "secret.ex")
    File.write!(foreign_path, "secret")

    Application.put_env(:handbean_probe, :staging_roots, [owned])
    on_exit(fn -> Application.delete_env(:handbean_probe, :staging_roots) end)

    view = info(view, {:platform, :begin, :import, %{"path" => owned_path}})
    request_id = assigns(view).last_platform_request
    assert_receive {:platform_cmd, %{op: "platform_import", request_id: ^request_id}}, 1_000

    imported = %Handbean.Attachments.Imported{
      attachment_id: "owned-1",
      source: :test,
      display_name: "kept.ex",
      canonical_type: "text/x-source",
      size_bytes: 20,
      controlled_path: owned_path
    }

    view = info(view, {:platform, :result, request_id, {:ok, imported}})

    view =
      info(view, {:platform, :begin, :import, %{"path" => "/cache/controlled_import/pending.ex"}})

    pending_id = assigns(view).last_platform_request
    assert_receive {:platform_cmd, %{op: "platform_import", request_id: ^pending_id}}, 1_000

    view = info(view, {:tap, :new_chat})
    assert_receive {:platform_cmd, cancel_req}, 1_000
    assert cancel_req.op == "platform_cancel"
    assert cancel_req.request_id != pending_id
    assert cancel_req.payload["target_request_id"] == pending_id
    refute File.exists?(owned_path)
    assert File.exists?(foreign_path)

    view =
      info(
        view,
        {:platform, :result, pending_id,
         {:ok, %{controlled_path: foreign_path, display_name: "secret.ex", source: "test"}}}
      )

    assert assigns(view).pending_attachments == []
    assert File.exists?(foreign_path)
  end

  test "opening another conversation cancels pending attachment work", %{view: view} do
    parent = self()

    install_platform_fake(fn req, _opts ->
      send(parent, {:platform_cmd, req})
      {:ok, :async}
    end)

    view = info(view, {:platform, :begin, :import, %{"path" => "/cache/pending.txt"}})
    generation = composer_generation(view)
    assert_receive {:platform_cmd, %{request_id: request_id}}
    {:ok, conversation} = Handbean.ConversationStore.create(assigns(view).workspace["id"])
    view = info(view, {:tap, {:conversation, conversation["id"]}})

    assert composer_generation(view) > generation
    assert PendingRequests.by_kind(assigns(view).pending_requests, :import) == []
    assert assigns(view).pending_attachments == []
    assert_receive {:platform_cmd, %{op: "platform_cancel", payload: payload}}
    assert payload["target_request_id"] == request_id
  end

  test "engine_result with C atom keys joins the draft", %{view: view} do
    install_platform_fake(fn _req, _opts -> {:ok, :async} end)

    dir = Path.join(System.tmp_dir!(), "native_import_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "from_c.ex")
    File.write!(path, "defmodule FromC do\nend\n")

    view = info(view, {:platform, :begin, :import, %{"path" => path}})
    request_id = assigns(view).last_platform_request

    json =
      Jason.encode!(%{
        "attachment_id" => "from-c",
        "display_name" => "from_c.ex",
        "canonical_type" => "text/x-source",
        "controlled_path" => path,
        "size_bytes" => File.stat!(path).size,
        "source" => "test"
      })

    view =
      info(view, {:engine_result, %{request_id: request_id, generation: 1, result: json}})

    assert Enum.any?(assigns(view).pending_attachments, fn att ->
             (att["filename"] || att[:filename]) == "from_c.ex"
           end)
  end

  test "text-only model blocks photo picker with a dismissible warning", %{view: view} do
    view = seed_input_models(view)
    view = info(view, {:change, :draft, "keep this draft"})
    view = info(view, {:tap, {:platform, :begin, :pick_photos}})
    assert assigns(view).input_warning.status == :unsupported
    assert assigns(view).input_warning.model == "Step Router v1"
    assert assigns(view).last_platform_request == nil
    assert find(view, :sheet)
    view = info(view, {:dismiss, :dismiss_input_warning})
    assert assigns(view).input_warning == nil
    assert assigns(view).draft == "keep this draft"
  end

  test "image result after model switch is kept, warns, and cannot be sent", %{
    view: view,
    dir: dir
  } do
    view = seed_input_models(view)
    path = Path.join(dir, "draft.png")
    File.write!(path, <<0>>)
    view = info(view, {:tap, {:composer_setting, :default_model, "stepfun/step-3.7-flash"}})

    att = %{
      "id" => "image-draft",
      "kind" => "image",
      "mime_type" => "image/png",
      "filename" => "draft.png",
      "controlled_path" => path,
      "size_bytes" => 1
    }

    socket = HandbeanProbe.HomeScreen.Platform.add_attachment(view.socket, att)
    view = %{view | socket: socket}
    assert assigns(view).input_warning == nil

    view = info(view, {:tap, {:composer_setting, :default_model, "stepfun/step-router-v1"}})
    assert assigns(view).input_warning.status == :unsupported
    view = info(view, {:tap, :dismiss_input_warning})
    view = info(view, {:tap, :send})
    assert assigns(view).input_warning.status == :unsupported
    assert assigns(view).chat == nil
    assert length(assigns(view).pending_attachments) == 1
    assert Handbean.ConversationStore.list() == []

    view = info(view, {:tap, {:composer_setting, :default_model, "stepfun/step-3.7-flash"}})
    assert assigns(view).input_warning == nil
    view = info(view, {:tap, {:composer_setting, :default_model, "stepfun/step-router-v1"}})
    view = info(view, {:tap, {:remove_attachment, "image-draft"}})
    assert assigns(view).input_warning == nil
    assert assigns(view).pending_attachments == []
  end

  test "unknown image capability warns without discarding externally imported images", %{
    view: view,
    dir: dir
  } do
    view = seed_input_models(view)
    path = Path.join(dir, "shared.png")
    File.write!(path, <<0>>)
    :ok = Handbean.Agent.ModelConfig.add_model("stepfun", "custom", %{"name" => "Custom"})
    view = info(view, {:tap, {:composer_setting, :default_model, "stepfun/custom"}})

    att = %{
      "id" => "shared",
      "kind" => "image",
      "mime_type" => "image/png",
      "filename" => "shared.png",
      "controlled_path" => path,
      "size_bytes" => 1,
      "source" => "share"
    }

    socket = HandbeanProbe.HomeScreen.Platform.add_attachment(view.socket, att)
    assert socket.assigns.input_warning.status == :unknown
    assert socket.assigns.pending_attachments == [att]
  end

  test "photo picker begin uses one request id and stale batch files are released", %{
    view: view
  } do
    view = seed_input_models(view)
    view = info(view, {:tap, {:composer_setting, :default_model, "stepfun/step-3.7-flash"}})
    parent = self()

    install_platform_fake(fn req, _opts ->
      send(parent, {:platform_cmd, req})
      {:ok, :async}
    end)

    view = info(view, {:tap, {:platform, :begin, :pick_photos}})
    request_id = assigns(view).last_platform_request
    generation = composer_generation(view)
    assert_receive {:platform_cmd, req}, 1_000
    assert req.op == "platform_pick_photos"
    assert req.request_id == request_id

    dir = Path.join(System.tmp_dir!(), "photo_stale_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "pic.bin")
    File.write!(path, "img")
    Application.put_env(:handbean_probe, :staging_roots, [dir])
    on_exit(fn -> Application.delete_env(:handbean_probe, :staging_roots) end)

    view = info(view, {:tap, :new_chat})
    assert composer_generation(view) > generation

    json =
      Jason.encode!(%{
        "attachments" => [
          %{
            "attachment_id" => "p1",
            "display_name" => "pic.jpg",
            "canonical_type" => "image/jpeg",
            "controlled_path" => path,
            "size_bytes" => 3,
            "source" => "photo"
          }
        ],
        "errors" => []
      })

    view = info(view, {:engine_result, %{request_id: request_id, result: json}})
    assert assigns(view).pending_attachments == []
    refute File.exists?(path)
  end

  test "iOS photo pick waits for files_picked, imports into composer, and ignores late results",
       %{view: view} do
    previous_platform = Application.get_env(:handbean_probe, :native_platform)
    previous_adapter = Application.get_env(:handbean_probe, :ios_platform_adapter)
    Application.delete_env(:handbean_probe, :platform_fake)
    HandbeanProbe.NativePlatform.put!(:ios)

    Application.put_env(
      :handbean_probe,
      :ios_platform_adapter,
      IOSAdapter
    )

    Application.put_env(:handbean_probe, :ios_test_pid, self())
    Application.put_env(:handbean_probe, :ios_adapter_reply, :ok)

    staging = Path.join(System.tmp_dir!(), "hs_ios_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(staging, "draft"))
    Application.put_env(:handbean_probe, :staging_roots, [staging])

    on_exit(fn ->
      File.rm_rf!(staging)
      Application.delete_env(:handbean_probe, :staging_roots)
      Application.delete_env(:handbean_probe, :ios_test_pid)
      Application.delete_env(:handbean_probe, :ios_adapter_reply)

      if previous_platform,
        do: Application.put_env(:handbean_probe, :native_platform, previous_platform),
        else: Application.delete_env(:handbean_probe, :native_platform)

      if previous_adapter,
        do: Application.put_env(:handbean_probe, :ios_platform_adapter, previous_adapter),
        else: Application.delete_env(:handbean_probe, :ios_platform_adapter)
    end)

    view = seed_input_models(view)
    view = info(view, {:tap, {:composer_setting, :default_model, "stepfun/step-3.7-flash"}})
    view = info(view, {:tap, {:platform, :begin, :pick_photos}})
    request_id = assigns(view).last_platform_request
    generation = composer_generation(view)
    assert is_binary(request_id)
    assert_receive :pick_images
    refute_received {:engine_result, _}
    assert PendingRequests.has?(assigns(view).pending_requests, request_id)
    assert assigns(view).pending_attachments == []

    png = Path.join(System.tmp_dir!(), "hs_pick_#{System.unique_integer([:positive])}.png")

    File.write!(
      png,
      <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8,
        6, 0, 0, 0, 31, 21, 196, 137>>
    )

    view = info(view, {:files, :picked, [%{path: png, name: "shot.png", size: 32}]})
    assert_receive {:engine_result, map}, 1_000
    view = info(view, {:engine_result, map})
    assert length(assigns(view).pending_attachments) == 1
    att = hd(assigns(view).pending_attachments)
    assert att["filename"] == "shot.png"
    assert att["controlled_path"]
    assert String.starts_with?(att["controlled_path"], staging)

    view = info(view, {:tap, :new_chat})
    assert composer_generation(view) > generation
    assert assigns(view).pending_attachments == []

    view = info(view, {:files, :picked, [%{path: png, name: "late.png"}]})
    refute_received {:engine_result, _}
    assert assigns(view).pending_attachments == []
  end

  test "host directory picker opens the in-app folder browser and lists off-screen", %{
    view: view,
    dir: dir
  } do
    File.mkdir_p!(Path.join(dir, "picker-fixture"))
    Application.put_env(:handbean_probe, :directory_picker_screen, self())
    on_exit(fn -> Application.delete_env(:handbean_probe, :directory_picker_screen) end)
    # Same wiring as HandbeanProbe.App: the host key points at the probe picker.
    Handbean.Host.put!(
      Map.put(
        Application.get_env(:handbean, :host),
        :directory_picker,
        HandbeanProbe.DirectoryPicker
      )
    )

    assert Handbean.Host.request_directory_picker(%{source: :web}) == :ok
    assert_receive {:directory_picker, %{source: :web}} = request

    # Listing the root runs under TaskSupervisor; the browser renders as
    # loading until the reply is dispatched.
    {:noreply, socket} = HomeScreen.handle_info(request, view.socket)
    loading = %{view | socket: socket}
    assert assigns(loading).page == :workspace
    assert %{mode: :browse, browser: %{loading?: true, entries: []}} = assigns(loading).workspaces
    assert text(loading) =~ gettext("Loading…")

    view = settle(loading)
    assert %{browser: %{loading?: false}} = assigns(view).workspaces
    refute text(view) =~ gettext("Loading…")
    assert "picker-fixture" in Enum.map(assigns(view).workspaces.browser.entries, & &1.name)
    assert text(view) =~ "picker-fixture"
  end

  test "directory picker is unavailable without a screen" do
    Application.put_env(:handbean_probe, :directory_picker_screen, :no_such_screen_process)
    on_exit(fn -> Application.delete_env(:handbean_probe, :directory_picker_screen) end)
    assert HandbeanProbe.DirectoryPicker.request_directory_picker(%{}) == {:error, :unavailable}
  end
end
