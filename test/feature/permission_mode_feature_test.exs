defmodule HandbeanWeb.Feature.PermissionModeFeatureTest do
  @moduledoc """
  Switching the permission pill writes workspace settings, and the next run
  honors that mode: safe mode asks before a write, yolo runs it.

  Run: mix test --include e2e test/feature/permission_mode_feature_test.exs
  """

  use HandbeanWeb.FeatureCase, async: false

  alias Handbean.ConversationStore
  alias Handbean.PubSub.Session
  alias Handbean.TestSupport.E2EHarness
  alias Handbean.WorkspaceSettings

  @moduletag :e2e

  test "safe mode asks before a write, yolo runs it", %{conn: conn} do
    %{workspace: workspace} = E2EHarness.isolate_home!("permission-mode")

    parent = self()

    E2EHarness.use_fake_provider!(
      {:script,
       fn messages, _tools ->
         result_text =
           messages
           |> Enum.filter(&(&1.role == :tool_result))
           |> Enum.map_join("\n", fn
             %{content: content} when is_binary(content) ->
               content

             %{content: blocks} when is_list(blocks) ->
               Enum.map_join(blocks, "\n", &(&1[:content] || &1["content"] || ""))

             _ ->
               ""
           end)

         cond do
           result_text =~ "denied" ->
             "Write denied"

           result_text != "" ->
             send(parent, :wrote)
             "Write finished"

           true ->
             {:tools, [%{name: "write", input: %{"file_path" => "out.txt", "content" => "kept"}}]}
         end
       end}
    )

    {:ok, ws} = Handbean.WorkspaceStore.add(workspace, name: "Permissions")
    {:ok, first} = ConversationStore.create(ws["id"], title: "Safe")
    {:ok, second} = ConversationStore.create(ws["id"], title: "YOLO")
    :ok = Session.subscribe(first["id"])
    :ok = Session.subscribe(second["id"])

    ExUnit.Callbacks.on_exit(fn ->
      E2EHarness.cancel!(first["id"])
      E2EHarness.cancel!(second["id"])
    end)

    page =
      conn
      |> visit("/w/#{ws["id"]}/c/#{first["id"]}")
      |> click_button("button[phx-click='toggle_permission_menu']", "智能审批")
      |> click_button("button[phx-value-mode='prompt']", "Safe Mode")

    assert {:ok, settings} = WorkspaceSettings.load(workspace)
    assert get_in(settings, ["tools", "default_mode"]) == "prompt"

    page =
      page
      |> fill_in("#ai-input", "Message", with: "Write the file", exact: false)
      |> click_button("#send-button", "")
      |> assert_has("#tool-approval-overlay", "write", timeout: 5_000)
      |> click_button("Allow once")
      |> assert_has(".msg-bubble.msg-assistant", "Write finished", timeout: 5_000)

    assert_receive :wrote, 5_000
    assert File.read!(Path.join(workspace, "out.txt")) == "kept"

    assert E2EHarness.await_run_end(first["id"], 8_000)[:status] in ["completed", :completed]

    page
    |> visit("/w/#{ws["id"]}/c/#{second["id"]}")
    |> click_button("button[phx-click='toggle_permission_menu']", "安全模式")
    |> click_button("button[phx-value-mode='yolo']", "yolo")

    assert {:ok, settings} = WorkspaceSettings.load(workspace)
    assert get_in(settings, ["tools", "default_mode"]) == "yolo"

    conn
    |> visit("/w/#{ws["id"]}/c/#{second["id"]}")
    |> fill_in("#ai-input", "Message", with: "Write again", exact: false)
    |> click_button("#send-button", "")
    |> assert_has(".msg-bubble.msg-assistant", "Write finished", timeout: 5_000)
    |> refute_has("#tool-approval-overlay")

    assert E2EHarness.await_run_end(second["id"])[:status] in ["completed", :completed]
    assert File.read!(Path.join(workspace, "out.txt")) == "kept"

    refute Enum.any?(
             E2EHarness.transcript(second["id"]),
             &(&1["role"] == "tool" and &1["tool_status"] == "error" and
                 &1["output"] =~ "denied")
           )
  end
end
