defmodule HandbeanWeb.Feature.InlineWidgetFeatureTest do
  @moduledoc """
  Send → Runner → streamed assistant Markdown → durable transcript → reopen.
  PhoenixTest checks the LiveView contract; assets/test/inline_html_feature_test.mjs
  exercises the client hook, tabs, and iframe preservation from that contract.

  Run: mix test --include e2e test/feature/inline_widget_feature_test.exs
  """

  use HandbeanWeb.FeatureCase, async: false

  alias Handbean.ConversationStore
  alias Handbean.PubSub.Session
  alias Handbean.TestSupport.E2EHarness

  @moduletag :e2e

  test "a generated widget survives reopening without a separate artifact store", %{conn: conn} do
    %{workspace: workspace} = E2EHarness.isolate_home!("inline-widget")

    reply = """
    Try the counter:

    ```widget
    <button onclick="this.textContent=Number(this.textContent)+1">3</button>
    ```

    It runs locally in the preview.
    """

    E2EHarness.use_fake_provider!({:script, fn _messages, _tools -> reply end})
    {:ok, ws} = Handbean.WorkspaceStore.add(workspace, name: "Widget fixture")
    {:ok, conversation} = ConversationStore.create(ws["id"], title: "Inline widget")
    id = conversation["id"]
    :ok = Session.subscribe(id)
    ExUnit.Callbacks.on_exit(fn -> E2EHarness.cancel!(id) end)
    path = "/w/#{ws["id"]}/c/#{id}"

    conn
    |> visit(path)
    |> fill_in("#ai-input", "Message", with: "Make a counter", exact: false)
    |> click_button("#send-button", "")
    |> assert_has(".msg-bubble.msg-assistant", "Try the counter:", timeout: 5_000)

    assert E2EHarness.await_run_end(id)[:status] in [:completed, "completed"]

    entry = Enum.find(E2EHarness.transcript(id), &(&1["role"] == "assistant"))
    assert entry["content"] == reply
    assert entry["status"] == "completed"

    conn
    |> visit(path)
    |> assert_has("[phx-hook='StreamingMarkdown'][data-final='true']")
    |> assert_has("[data-source]", text: "It runs locally in the preview.")
  end
end
