defmodule Handbean.Tool.Builtin.AndroidIntentTest do
  use ExUnit.Case, async: false

  alias Handbean.ExportSnapshot
  alias Handbean.ExportSnapshot.Binding
  alias Handbean.Tool.Builtin.{DeviceAlarm, DeviceCalendar, OpenFile, OpenUrl, ShareFile}

  setup do
    previous = Application.get_env(:handbean, :host)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:handbean, :host, previous),
        else: Application.delete_env(:handbean, :host)
    end)

    :ok
  end

  test "open url rejects extra intent fields and non-http schemes" do
    stub(fn _cmd, _ctx -> flunk("must not dispatch") end)

    assert {:error, _} = OpenUrl.execute(%{"url" => "https://a.com", "action" => "VIEW"}, %{})
    assert {:error, _} = OpenUrl.execute(%{"url" => "file:///tmp/x"}, %{})
  end

  test "open url reports ui_presented without claiming the page was read" do
    stub(fn cmd, _ctx ->
      assert cmd.op == :open_url
      assert cmd.url == "https://example.com/order"
      {:ok, %{outcome: "ui_presented", url: cmd.url}}
    end)

    assert {:ok, text, %{outcome: "ui_presented"}} =
             OpenUrl.execute(%{"url" => "https://example.com/order"}, %{})

    assert text =~ "界面已出现"
    assert text =~ "不表示对方已阅读"
  end

  test "file tools reject traversal and bind the approved snapshot" do
    dir = Path.join(System.tmp_dir!(), "android_intent_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "report.pdf"), "pdf")

    Binding.put("conv-1", "call-1", %{
      snapshot_id: "snap-1",
      owner_request_id: "owner-1",
      relative_path: "report.pdf",
      workspace_path: dir,
      action: :share_file
    })

    stub(fn cmd, _ctx ->
      assert cmd.op == :share_file
      assert cmd.snapshot_id == "snap-1"
      refute Map.has_key?(cmd, :action)
      {:ok, %{outcome: "chooser_presented", snapshot_id: "snap-1"}}
    end)

    assert {:ok, text, %{outcome: "chooser_presented"}} =
             ShareFile.execute(%{"path" => "report.pdf"}, %{
               working_directory: dir,
               conversation_id: "conv-1",
               tool_call_id: "call-1"
             })

    assert text =~ "选择器已出现"
    assert text =~ "不表示文件已发送"
    assert :error = Binding.fetch("conv-1", "call-1")

    assert {:error, _} =
             OpenFile.execute(%{"path" => "../secret"}, %{working_directory: dir})

    File.rm_rf!(dir)
  end

  test "missing binding fails and never recopies the source" do
    dir = Path.join(System.tmp_dir!(), "android_intent_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "ok.txt"), "ok")

    stub(fn cmd, _ -> flunk("must not dispatch #{inspect(cmd)}") end)

    assert {:error, text} =
             OpenFile.execute(%{"path" => "ok.txt"}, %{
               working_directory: dir,
               conversation_id: "conv-x",
               tool_call_id: "missing"
             })

    assert text =~ "导出副本不可用"
    assert {:error, :invalid_path} = ExportSnapshot.authorize(dir, "/etc/passwd")
    File.rm_rf!(dir)
  end

  test "execute uses the approved snapshot after the source file is deleted" do
    dir = Path.join(System.tmp_dir!(), "android_intent_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "gone.txt"), "bytes")

    Binding.put("conv-2", "call-2", %{
      snapshot_id: "snap-gone",
      owner_request_id: "owner-2",
      relative_path: "gone.txt",
      workspace_path: dir,
      action: :open_file
    })

    File.rm!(Path.join(dir, "gone.txt"))

    stub(fn cmd, _ctx ->
      assert cmd.op == :open_file
      assert cmd.snapshot_id == "snap-gone"
      refute Map.has_key?(cmd, :path)
      {:ok, %{outcome: "ui_presented", snapshot_id: "snap-gone"}}
    end)

    assert {:ok, _, %{outcome: "ui_presented"}} =
             OpenFile.execute(%{"path" => "gone.txt"}, %{
               working_directory: dir,
               conversation_id: "conv-2",
               tool_call_id: "call-2"
             })

    File.rm_rf!(dir)
  end

  test "binding must match conversation workspace path and action" do
    dir = Path.join(System.tmp_dir!(), "android_intent_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    Binding.put("conv-3", "call-3", %{
      snapshot_id: "snap-3",
      owner_request_id: "owner-3",
      relative_path: "a.txt",
      workspace_path: dir,
      action: :open_file
    })

    stub(fn cmd, _ -> flunk("must not dispatch #{inspect(cmd)}") end)

    assert {:error, _} =
             ShareFile.execute(%{"path" => "a.txt"}, %{
               working_directory: dir,
               conversation_id: "conv-3",
               tool_call_id: "call-3"
             })

    File.rm_rf!(dir)
  end

  test "calendar insert writes through the backend and does not claim attendance" do
    stub(fn cmd, _ctx ->
      assert cmd.op == :device_calendar
      assert cmd.calendar_action == "insert_event"
      assert cmd.title == "牙医"
      refute Map.has_key?(cmd, :intent)
      {:ok, %{outcome: "inserted", event_id: "42", calendar_id: "1"}}
    end)

    assert {:ok, text, %{outcome: "inserted", event_id: "42"}} =
             DeviceCalendar.execute(
               %{
                 "calendar_action" => "insert_event",
                 "title" => "牙医",
                 "start_ms" => 1_700_000_000_000,
                 "end_ms" => 1_700_000_360_000
               },
               %{}
             )

    assert text =~ "已写入系统日历"
    assert text =~ "没有打开日历应用"
  end

  test "calendar rejects raw intent fields and inverted times" do
    stub(fn _cmd, _ctx -> flunk("must not dispatch") end)

    assert {:error, "raw Intent fields are not allowed"} =
             DeviceCalendar.execute(
               %{"calendar_action" => "insert_event", "title" => "x", "extras" => %{}},
               %{}
             )

    assert {:error, text} =
             DeviceCalendar.execute(
               %{
                 "calendar_action" => "insert_event",
                 "title" => "x",
                 "start_ms" => 20,
                 "end_ms" => 10
               },
               %{}
             )

    assert text =~ "时间"
  end

  test "alarm prefills the clock and does not claim the alarm was saved" do
    stub(fn cmd, _ctx ->
      assert cmd.op == :device_alarm
      assert cmd.hour == 7
      assert cmd.minute == 30
      assert cmd.message == "起床"
      assert cmd.skip_ui == false
      {:ok, %{outcome: "alarm_prefilled", hour: 7, minute: 30}}
    end)

    assert {:ok, text, %{outcome: "alarm_prefilled"}} =
             DeviceAlarm.execute(
               %{"hour" => 7, "minute" => 30, "message" => "起床"},
               %{}
             )

    assert text =~ "预填"
    assert text =~ "不是静默写入"
  end

  test "alarm rejects out-of-range clock fields" do
    stub(fn _cmd, _ctx -> flunk("must not dispatch") end)
    assert {:error, _} = DeviceAlarm.execute(%{"hour" => 24, "minute" => 0}, %{})

    assert {:error, _} =
             DeviceAlarm.execute(%{"hour" => 7, "minute" => 0, "action" => "SET_ALARM"}, %{})
  end

  defp stub(fun) when is_function(fun, 2) do
    Handbean.Host.put!(%{artifact_delivery_backend: fun})
  end
end
