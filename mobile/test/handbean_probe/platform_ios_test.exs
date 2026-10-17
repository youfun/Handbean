defmodule HandbeanProbe.Platform.IOSTest do
  use ExUnit.Case, async: false

  alias HandbeanProbe.Bridge.Inbound
  alias HandbeanProbe.NativePlatform
  alias HandbeanProbe.Platform.{IOS, Nif, Request}
  alias HandbeanProbe.Platform.IOS.{Adapter, Import, Registry}

  defmodule RecordingAdapter do
    @behaviour Adapter

    def open_url(url) do
      send(Process.get(:ios_test), {:open_url, url})
      Process.get(:ios_adapter_reply) || :ok
    end

    def share_text(text) do
      send(Process.get(:ios_test), {:share_text, text})
      Process.get(:ios_adapter_reply) || :ok
    end

    def pick_images do
      send(Process.get(:ios_test), :pick_images)
      Process.get(:ios_adapter_reply) || :ok
    end

    def present_file(path, mode) do
      send(Process.get(:ios_test), {:present_file, path, mode})
      Process.get(:ios_adapter_reply) || :ok
    end
  end

  defmodule BoomAdapter do
    @behaviour Adapter

    def open_url(_), do: raise("boom")
    def share_text(_), do: raise("boom")
    def pick_images, do: raise("boom")
    def present_file(_, _), do: raise("boom")
  end

  defmodule ErrorAdapter do
    @behaviour Adapter

    def open_url(_), do: {:error, :nif_not_loaded}
    def share_text(_), do: {:error, :nif_not_loaded}
    def pick_images, do: {:error, :nif_not_loaded}
    def present_file(_, _), do: {:error, :nif_not_loaded}
  end

  setup do
    previous_platform = Application.get_env(:handbean_probe, :native_platform)
    previous_adapter = Application.get_env(:handbean_probe, :ios_platform_adapter)
    previous_roots = Application.get_env(:handbean_probe, :staging_roots)
    previous_snap = Application.get_env(:handbean_probe, :ios_snapshot_root)

    NativePlatform.put!(:ios)
    Process.put(:ios_test, self())
    Process.put(:ios_adapter_reply, :ok)
    Application.put_env(:handbean_probe, :ios_platform_adapter, RecordingAdapter)

    staging = Path.join(System.tmp_dir!(), "ios_import_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(staging, "draft"))
    Application.put_env(:handbean_probe, :staging_roots, [staging])

    snap_root = Path.join(System.tmp_dir!(), "ios_snap_#{System.unique_integer([:positive])}")
    File.mkdir_p!(snap_root)
    Application.put_env(:handbean_probe, :ios_snapshot_root, snap_root)
    Registry.ensure_started()
    _ = Registry.take_pick(self())

    on_exit(fn ->
      restore(:native_platform, previous_platform)
      restore(:ios_platform_adapter, previous_adapter)
      restore(:staging_roots, previous_roots)
      restore(:ios_snapshot_root, previous_snap)
      _ = Registry.take_pick(self())
      File.rm_rf!(staging)
      File.rm_rf!(snap_root)
    end)

    %{staging: staging, snap_root: snap_root}
  end

  test "open_url only claims ui_presented after a successful adapter submit" do
    req =
      Request.new("platform_open_url", "req-ios-1", 2, self(), %{
        "op" => "platform_open_url",
        "url" => "https://example.com"
      })

    assert {:ok, :async} = Nif.command(req)
    assert_receive {:open_url, "https://example.com"}
    assert_receive {:engine_result, map}
    assert {:ok, decoded} = Nif.decode_engine_result(map)
    assert decoded.request_id == "req-ios-1"
    assert decoded.generation == 2
    assert {:ok, %{"outcome" => "ui_presented"}} = decoded.body
  end

  test "calendar and alarm are explicit unsupported results, not a presented outcome" do
    for op <- ["platform_device_calendar", "platform_device_alarm", "platform_app_settings"] do
      req = Request.new(op, "req-ios-#{op}", 1, self(), %{"op" => op})
      assert {:ok, :async} = Nif.command(req)
      assert_receive {:engine_result, map}
      assert {:ok, decoded} = Nif.decode_engine_result(map)
      assert {:error, "unsupported_on_ios"} = decoded.body
    end
  end

  test "adapter error is returned instead of a presented outcome" do
    Application.put_env(:handbean_probe, :ios_platform_adapter, ErrorAdapter)

    req =
      Request.new("platform_open_url", "req-ios-err", 1, self(), %{
        "op" => "platform_open_url",
        "url" => "https://example.com"
      })

    assert {:ok, :async} = Nif.command(req)
    assert_receive {:engine_result, map}
    assert {:ok, decoded} = Nif.decode_engine_result(map)
    assert {:error, "nif_not_loaded"} = decoded.body
  end

  test "adapter exception is not swallowed into a presented outcome" do
    Application.put_env(:handbean_probe, :ios_platform_adapter, BoomAdapter)

    req =
      Request.new("platform_share_text", "req-ios-boom", 1, self(), %{
        "op" => "platform_share_text",
        "text" => "hello"
      })

    assert_raise RuntimeError, fn -> Nif.command(req) end
    refute_received {:engine_result, _}
  end

  test "pick_photos does not complete until the picker receipt arrives", %{staging: staging} do
    req =
      Request.new("platform_pick_photos", "req-pick", 4, self(), %{
        "op" => "platform_pick_photos"
      })

    assert {:ok, :async} = Nif.command(req)
    assert_receive :pick_images
    refute_received {:engine_result, _}
    assert {:ok, %{request_id: "req-pick"}} = Registry.peek_pick(self())

    png = Path.join(System.tmp_dir!(), "pick_#{System.unique_integer([:positive])}.png")
    File.write!(png, png_bytes())

    assert :handled =
             IOS.consume_files_event(
               {:picked, [%Inbound.PickedFile{path: png, name: "shot.png", size: 68}]}
             )

    assert_receive {:engine_result, map}
    assert {:ok, decoded} = Nif.decode_engine_result(map)
    assert {:ok_batch, [att], []} = decoded.body
    assert att["source"] == "photo"
    assert att["canonical_type"] == "image/jpeg" or att["canonical_type"] == "image/png"
    assert att["controlled_path"]
    assert String.starts_with?(att["controlled_path"], staging)
    assert File.exists?(att["controlled_path"])
    assert :error = Registry.peek_pick(self())
  end

  test "picker cancel completes the live request as cancelled" do
    req =
      Request.new("platform_pick_photos", "req-cancel-pick", 1, self(), %{
        "op" => "platform_pick_photos"
      })

    assert {:ok, :async} = Nif.command(req)
    assert :handled = IOS.consume_files_event(:cancelled)
    assert_receive {:engine_result, map}
    assert {:ok, decoded} = Nif.decode_engine_result(map)
    assert decoded.body == :cancelled
  end

  test "late picker receipt after cancel is ignored as a cancelled completion" do
    req =
      Request.new("platform_pick_photos", "req-late", 1, self(), %{
        "op" => "platform_pick_photos"
      })

    assert {:ok, :async} = Nif.command(req)

    mapped = %{
      op: "platform_cancel",
      request_id: "cancel-cmd",
      generation: 1,
      caller: self(),
      payload: Jason.encode!(%{"target_request_id" => "req-late"})
    }

    assert {:ok, :async} = IOS.command(mapped)
    assert_receive {:engine_result, cancel_map}
    assert {:ok, cancel_decoded} = Nif.decode_engine_result(cancel_map)
    assert cancel_decoded.body == :cancelled

    png = Path.join(System.tmp_dir!(), "late_#{System.unique_integer([:positive])}.png")
    File.write!(png, png_bytes())

    assert :handled =
             IOS.consume_files_event(
               {:picked, [%Inbound.PickedFile{path: png, name: "late.png"}]}
             )

    assert_receive {:engine_result, late}
    assert {:ok, decoded} = Nif.decode_engine_result(late)
    assert decoded.request_id == "req-late"
    assert decoded.body == :cancelled
  end

  test "picker receipt with no live pick is ignored for workspace import" do
    assert :ignored = IOS.consume_files_event({:picked, [%{path: "/tmp/a.png", name: "a.png"}]})
    assert :ignored = IOS.consume_files_event(:cancelled)
  end

  test "platform_export copies inside the workspace and present uses snapshot_id" do
    ws = Path.join(System.tmp_dir!(), "ws_#{System.unique_integer([:positive])}")
    File.mkdir_p!(ws)
    src = Path.join(ws, "note.txt")
    File.write!(src, "hello export")

    export =
      Request.new("platform_export", "req-export", 3, self(), %{
        "op" => "platform_export",
        "workspace_path" => ws,
        "path" => src,
        "relative_path" => "note.txt",
        "owner_request_id" => "req-export"
      })

    assert {:ok, :async} = Nif.command(export)
    assert_receive {:engine_result, export_map}
    assert {:ok, export_decoded} = Nif.decode_engine_result(export_map)
    assert {:ok, doc} = export_decoded.body
    assert is_binary(doc["snapshot_id"])
    assert doc["owner_request_id"] == "req-export"
    refute Map.has_key?(doc, "path")

    present =
      Request.new("platform_open_snapshot", "req-open", 3, self(), %{
        "op" => "platform_open_snapshot",
        "snapshot_id" => doc["snapshot_id"],
        "owner_request_id" => "req-export"
      })

    assert {:ok, :async} = Nif.command(present)
    assert_receive {:present_file, path, :open}
    assert File.exists?(path)
    assert File.read!(path) == "hello export"
    assert_receive {:engine_result, present_map}
    assert {:ok, present_decoded} = Nif.decode_engine_result(present_map)
    assert {:ok, %{"outcome" => "ui_presented"}} = present_decoded.body
  after
    :ok
  end

  test "present without a snapshot is an error, not chooser_presented" do
    req =
      Request.new("platform_share_snapshot", "req-missing", 1, self(), %{
        "op" => "platform_share_snapshot",
        "snapshot_id" => "missing",
        "owner_request_id" => "owner"
      })

    assert {:ok, :async} = Nif.command(req)
    refute_received {:present_file, _, _}
    assert_receive {:engine_result, map}
    assert {:ok, decoded} = Nif.decode_engine_result(map)
    assert {:error, "file_unavailable"} = decoded.body
  end

  test "export refuses a path outside the workspace" do
    outside = Path.join(System.tmp_dir!(), "secret_#{System.unique_integer([:positive])}.txt")
    File.write!(outside, "nope")
    ws = Path.join(System.tmp_dir!(), "ws_#{System.unique_integer([:positive])}")
    File.mkdir_p!(ws)

    req =
      Request.new("platform_export", "req-out", 1, self(), %{
        "op" => "platform_export",
        "workspace_path" => ws,
        "path" => outside,
        "owner_request_id" => "req-out"
      })

    assert {:ok, :async} = Nif.command(req)
    assert_receive {:engine_result, map}
    assert {:ok, decoded} = Nif.decode_engine_result(map)
    assert {:error, reason} = decoded.body
    assert is_binary(reason)
    refute reason == "unsupported_on_ios"
  end

  test "owner mismatch cannot present or cleanup another request's snapshot" do
    ws = Path.join(System.tmp_dir!(), "ws_#{System.unique_integer([:positive])}")
    File.mkdir_p!(ws)
    src = Path.join(ws, "a.txt")
    File.write!(src, "a")

    {:ok, snap} = Registry.put_copy(src, ws, "owner-a")

    req =
      Request.new("platform_open_snapshot", "req-wrong", 1, self(), %{
        "op" => "platform_open_snapshot",
        "snapshot_id" => snap.snapshot_id,
        "owner_request_id" => "owner-b"
      })

    assert {:ok, :async} = Nif.command(req)
    refute_received {:present_file, _, _}
    assert_receive {:engine_result, map}
    assert {:ok, decoded} = Nif.decode_engine_result(map)
    assert {:error, "file_unavailable"} = decoded.body
    assert {:ok, _} = Registry.fetch(snap.snapshot_id, "owner-a")
  end

  test "import_images copies into the staging root and rejects non-images", %{staging: staging} do
    png = Path.join(System.tmp_dir!(), "ok_#{System.unique_integer([:positive])}.png")
    File.write!(png, png_bytes())
    txt = Path.join(System.tmp_dir!(), "note_#{System.unique_integer([:positive])}.txt")
    File.write!(txt, "hello")

    assert {:ok, [att], errors} =
             Import.import_images([
               %Inbound.PickedFile{path: png, name: "ok.png"},
               %Inbound.PickedFile{path: txt, name: "note.txt"}
             ])

    assert att["controlled_path"] =~ staging
    assert Enum.any?(errors, &(&1 == "unsupported_type"))
  end

  test "more than four picked images reports extra errors" do
    files =
      for i <- 1..5 do
        path = Path.join(System.tmp_dir!(), "n#{i}_#{System.unique_integer([:positive])}.png")
        File.write!(path, png_bytes())
        %Inbound.PickedFile{path: path, name: "n#{i}.png"}
      end

    assert {:ok, atts, errors} = Import.import_images(files)
    assert length(atts) == 4
    assert "too_many_attachments" in errors
  end

  defp restore(key, nil), do: Application.delete_env(:handbean_probe, key)
  defp restore(key, value), do: Application.put_env(:handbean_probe, key, value)

  defp png_bytes do
    <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6,
      0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 248, 207, 192, 0, 0,
      0, 2, 0, 1, 226, 33, 188, 51, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>
  end
end
