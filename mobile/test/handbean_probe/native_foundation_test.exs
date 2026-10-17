defmodule HandbeanProbe.NativeFoundationTest do
  use ExUnit.Case, async: false
  use Gettext, backend: HandbeanProbe.Gettext

  alias HandbeanProbe.{NativeApproval, NativeChat, Platform}

  setup do
    dir = Path.join(System.tmp_dir!(), "native_found_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    host = Application.get_env(:handbean, :host)
    Handbean.Host.put!(%{data_dir: dir, shell: false, mcp: false})

    vars = %{
      "HANDBEAN_WORKSPACE" => Path.join(dir, "workspace"),
      "HANDBEAN_MODELS_FILE" => Path.join(dir, "models.json"),
      "HANDBEAN_WORKSPACES_FILE" => Path.join(dir, "workspaces.json"),
      "HANDBEAN_GLOBAL_SETTINGS_FILE" => Path.join(dir, "settings.json")
    }

    previous = Map.new(vars, fn {key, _} -> {key, System.get_env(key)} end)
    Enum.each(vars, fn {key, value} -> System.put_env(key, value) end)

    on_exit(fn ->
      HandbeanProbe.RuntimeCleanup.stop!()

      if host,
        do: Application.put_env(:handbean, :host, host),
        else: Application.delete_env(:handbean, :host)

      Enum.each(previous, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)

      File.rm_rf!(dir)
    end)

    {:ok, workspace} = Handbean.WorkspaceStore.ensure_default!()
    %{dir: dir, workspace: workspace}
  end

  test "platform host uses the fake and never loads a NIF" do
    req =
      HandbeanProbe.Platform.Request.new(
        "platform_export",
        "req-1",
        1,
        self(),
        %{"workspace_path" => "/tmp/ws", "path" => "a.txt"}
      )

    Application.put_env(:handbean_probe, :platform_fake, fn cmd, _ -> {:ok, %{op: cmd.op}} end)
    on_exit(fn -> Application.delete_env(:handbean_probe, :platform_fake) end)
    assert {:ok, %{op: "platform_export"}} = Platform.start(req)
    assert {:error, :invalid_platform_request} = Platform.request(%{op: "platform_export"})

    assert {:error, :invalid_platform_request} =
             Platform.request(%{
               op: "platform_export",
               request_id: "x",
               generation: 1,
               caller: self(),
               payload: %{}
             })
  end

  test "cancel allocates a fresh command id and export_file authorizes first", %{
    workspace: workspace
  } do
    parent = self()

    Application.put_env(:handbean_probe, :platform_fake, fn cmd, _ ->
      send(parent, {:platform_cmd, cmd})
      {:ok, :async}
    end)

    on_exit(fn -> Application.delete_env(:handbean_probe, :platform_fake) end)

    assert {:ok, :async} = Platform.cancel(self(), "import-target", 7)
    assert_receive {:platform_cmd, cancel_req}, 1_000
    assert cancel_req.op == "platform_cancel"
    assert cancel_req.request_id != "import-target"
    assert cancel_req.generation == 7
    assert cancel_req.payload["target_request_id"] == "import-target"
    assert cancel_req.payload["op"] == "platform_cancel"

    File.write!(Path.join(workspace["path"], "ok.txt"), "hello")
    assert {:ok, :async} = Platform.export_file(self(), "exp-1", 2, workspace["path"], "ok.txt")
    assert_receive {:platform_cmd, export_req}, 1_000
    assert export_req.op == "platform_export"
    assert export_req.payload["path"] == Path.expand(Path.join(workspace["path"], "ok.txt"))
    assert export_req.payload["relative_path"] == "ok.txt"
    assert export_req.payload["workspace_path"] == workspace["path"]

    refute match?(
             {:ok, _},
             Platform.export_file(self(), "exp-2", 2, workspace["path"], "../secret")
           )

    refute match?(
             {:ok, _},
             Platform.export_file(self(), "exp-3", 2, workspace["path"], "/etc/passwd")
           )

    outside = Path.join(System.tmp_dir!(), "not_import_#{System.unique_integer([:positive])}.txt")
    File.write!(outside, "nope")
    assert {:error, :outside_import_root} = Platform.safe_rm_controlled(outside)
    assert File.exists?(outside)
    File.rm!(outside)
  end

  test "NIF wire map uses the C atom schema and engine_result decode" do
    req =
      HandbeanProbe.Platform.Request.new("platform_import", "rid-c", 4, self(), %{"path" => "x"})

    wired = HandbeanProbe.Platform.Nif.wire_map(req)
    assert Map.keys(wired) |> Enum.sort() == [:caller, :generation, :op, :payload, :request_id]
    assert wired.op == "platform_import"
    assert wired.request_id == "rid-c"
    assert wired.generation == 4
    assert wired.caller == self()
    assert {:ok, payload} = Jason.decode(wired.payload)
    assert payload["op"] == "platform_import"
    refute Map.has_key?(wired, "op")

    assert {:ok, %HandbeanProbe.Bridge.Inbound.EngineResult{} = decoded} =
             HandbeanProbe.Platform.Nif.decode_engine_result(%{
               request_id: "rid-c",
               generation: 4,
               result: ~s({"cancelled":true})
             })

    assert decoded.request_id == "rid-c"
    assert decoded.generation == 4
    assert decoded.body == :cancelled
  end

  test "native send with a text attachment writes refs and no base64", %{workspace: workspace} do
    {:ok, conv} = Handbean.ConversationStore.create(workspace["id"])
    path = Path.join(workspace["path"], "readme.md")
    File.write!(path, "# hi\n")

    imported = %Handbean.Attachments.Imported{
      attachment_id: "md-1",
      source: :test,
      display_name: "readme.md",
      canonical_type: "text/markdown",
      size_bytes: 5,
      controlled_path: path
    }

    Application.put_env(:handbean_probe, :staging_roots, [workspace["path"]])
    on_exit(fn -> Application.delete_env(:handbean_probe, :staging_roots) end)

    no_model = gettext("Add a model in Settings first")

    assert {:error, ^no_model} =
             NativeChat.send_message(workspace, conv, "see", [imported])

    persistable = [
      %{
        "id" => "md-1",
        "kind" => "text",
        "mime_type" => "text/markdown",
        "filename" => "readme.md",
        "relative_path" => "readme.md"
      }
    ]

    {:ok, entry} =
      Handbean.Agent.TranscriptPersistence.append_inbound(conv["id"], "see",
        attachments: persistable,
        inbound_id: "corr-1"
      )

    refute Jason.encode!(entry) =~ "IyBoaQ"
    assert entry["attachments"] != []
    assert Handbean.Attachments.inbound_ack(conv["id"], "corr-1") == :acknowledged
  end

  test "open_url and snapshot share helpers stay typed", %{workspace: workspace} do
    parent = self()

    Application.put_env(:handbean_probe, :platform_fake, fn cmd, _ ->
      send(parent, {:platform_cmd, cmd})
      {:ok, :async}
    end)

    on_exit(fn -> Application.delete_env(:handbean_probe, :platform_fake) end)

    assert "platform_open_url" in HandbeanProbe.Platform.Request.ops()
    assert "platform_share_text" in HandbeanProbe.Platform.Request.ops()
    assert "platform_device_calendar" in HandbeanProbe.Platform.Request.ops()
    assert "platform_device_alarm" in HandbeanProbe.Platform.Request.ops()
    assert "platform_app_settings" in HandbeanProbe.Platform.Request.ops()
    assert {:ok, :async} = Platform.open_url(self(), "url-1", 3, "https://example.com")
    assert_receive {:platform_cmd, url_req}, 1_000
    assert url_req.op == "platform_open_url"
    assert url_req.payload["url"] == "https://example.com"

    File.write!(Path.join(workspace["path"], "pack.zip"), "zip")

    assert {:ok, :async} =
             Platform.export_file(self(), "exp-url", 3, workspace["path"], "pack.zip")

    assert_receive {:platform_cmd, _export}, 1_000

    assert {:ok, :async} = Platform.share_snapshot(self(), "sh-1", 3, "snap-a", "exp-url")
    assert_receive {:platform_cmd, share_req}, 1_000
    assert share_req.op == "platform_share_snapshot"
    assert share_req.payload["snapshot_id"] == "snap-a"
    assert share_req.payload["owner_request_id"] == "exp-url"
    assert is_integer(url_req.payload["deadline_ms"])
    assert is_integer(share_req.payload["deadline_ms"])

    assert {:ok, :async} = Platform.share_text(self(), "txt-1", 3, "评价草稿")
    assert_receive {:platform_cmd, text_req}, 1_000
    assert text_req.op == "platform_share_text"
    assert text_req.payload["text"] == "评价草稿"
    assert is_integer(text_req.payload["deadline_ms"])
    assert {:error, :empty} = Platform.share_text(self(), "txt-empty", 3, "  ")
  end

  test "decide_one skips other Android actions without calling them user denials" do
    pending = %{
      "action_requests" => [
        %{"tool_call_id" => "a1", "tool_name" => "open_url"},
        %{"tool_call_id" => "a2", "tool_name" => "share_file"}
      ]
    }

    skipped = NativeApproval.skipped_android_requests(pending, "a1")
    assert Enum.map(skipped, & &1["tool_call_id"]) == ["a2"]
    assert :ok = NativeApproval.validate_decide_one(pending, "a1")

    mixed = %{
      "action_requests" => [
        %{"tool_call_id" => "a1", "tool_name" => "open_url"},
        %{"tool_call_id" => "w1", "tool_name" => "write"}
      ]
    }

    assert {:error, :mixed_approval_batch} = NativeApproval.validate_decide_one(mixed, "a1")

    writes = %{
      "action_requests" => [
        %{"tool_call_id" => "w1", "tool_name" => "write"},
        %{"tool_call_id" => "w2", "tool_name" => "bash"}
      ]
    }

    assert {:error, :mixed_approval_batch} = NativeApproval.validate_decide_one(writes, "w1")
  end

  test "approve refuses unready file snapshots and launches only one android action" do
    pending = %{
      "action_requests" => [
        %{
          "tool_call_id" => "f1",
          "tool_name" => "open_file",
          "arguments" => %{"path" => "a.txt"}
        },
        %{
          "tool_call_id" => "f2",
          "tool_name" => "share_file",
          "arguments" => %{"path" => "b.txt"}
        }
      ]
    }

    assert {:error, :snapshot_not_ready} = NativeApproval.validate_decide(pending, :approve, %{})

    ready = %{"f1" => %{snapshot_id: "s1"}, "f2" => %{snapshot_id: "s2"}}
    assert {:ok, decisions} = NativeApproval.validate_decide(pending, :approve, ready)
    assert Enum.map(decisions, & &1["action"]) == ["approve", "skip"]
    assert NativeApproval.snapshots_ready?(pending, ready)
  end
end
