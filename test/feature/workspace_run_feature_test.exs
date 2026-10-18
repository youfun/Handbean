defmodule HandbeanWeb.Feature.WorkspaceRunFeatureTest do
  @moduledoc """
  A composer send starts a real workspace run. FakeProvider scripts the tool
  call; the read tool, transcript, and finished run are real.

  Run: mix test --include e2e test/feature/workspace_run_feature_test.exs
  """

  use HandbeanWeb.FeatureCase, async: false

  alias Handbean.ConversationStore
  alias Handbean.PubSub.Session
  alias Handbean.TestSupport.E2EHarness

  @moduletag :e2e

  test "sending a message runs the tool and persists the finished reply", %{conn: conn} do
    %{workspace: workspace} = E2EHarness.isolate_home!("workspace-run")
    File.write!(Path.join(workspace, "note.txt"), "ORCHID-2048")

    E2EHarness.use_fake_provider!(
      {:script,
       fn messages, _tools ->
         if Enum.any?(messages, &(&1.role == :tool_result)) do
           "Read ORCHID-2048"
         else
           {:tools, [%{name: "read", input: %{"file_path" => "note.txt"}}]}
         end
       end}
    )

    {:ok, ws} = Handbean.WorkspaceStore.add(workspace, name: "Run fixture")
    {:ok, conversation} = ConversationStore.create(ws["id"], title: "Run")
    id = conversation["id"]
    :ok = Session.subscribe(id)

    ExUnit.Callbacks.on_exit(fn -> E2EHarness.cancel!(id) end)

    conn
    |> visit("/w/#{ws["id"]}/c/#{id}")
    |> fill_in("#ai-input", "Message", with: "Read the note", exact: false)
    |> click_button("#send-button", "")
    |> assert_has(".msg-bubble.msg-user", "Read the note")
    |> assert_has(".msg-bubble.msg-assistant", "Read ORCHID-2048", timeout: 5_000)

    payload = E2EHarness.await_run_end(id)
    assert payload[:status] in ["completed", :completed]

    entries = E2EHarness.transcript(id)
    assert Enum.any?(entries, &(&1["role"] == "user" and &1["content"] == "Read the note"))
    assert Enum.any?(entries, &(&1["role"] == "tool" and &1["tool_name"] == "read"))

    assert Enum.any?(
             entries,
             &(&1["role"] == "assistant" and &1["content"] == "Read ORCHID-2048")
           )
  end
end
