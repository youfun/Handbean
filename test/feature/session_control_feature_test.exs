defmodule HandbeanWeb.Feature.SessionControlFeatureTest do
  @moduledoc """
  While a run is open, the composer can steer the next step, queue a message
  until the run finishes, or stop the run. Each path leaves a durable transcript.

  Run: mix test --include e2e test/feature/session_control_feature_test.exs
  """

  use HandbeanWeb.FeatureCase, async: false

  alias Handbean.Agent.Message
  alias Handbean.ConversationStore
  alias Handbean.PubSub.Session
  alias Handbean.TestSupport.E2EHarness

  import Phoenix.LiveViewTest, only: [render_click: 3]

  @moduletag :e2e

  setup %{conn: conn} do
    %{workspace: workspace} = E2EHarness.isolate_home!("session-control")
    {:ok, ws} = Handbean.WorkspaceStore.add(workspace, name: "Control")
    {:ok, conversation} = ConversationStore.create(ws["id"], title: "Control")
    id = conversation["id"]
    :ok = Session.subscribe(id)
    ExUnit.Callbacks.on_exit(fn -> E2EHarness.cancel!(id) end)
    {:ok, conn: conn, ws: ws, id: id}
  end

  test "steer inserts the next message before the run answers", %{conn: conn, ws: ws, id: id} do
    parent = self()

    E2EHarness.use_fake_provider!(
      {:script,
       fn messages, _tools ->
         if Enum.any?(messages, &(Message.text(&1) =~ "steered line")) do
           send(parent, :saw_steer)
           "Saw the steered line"
         else
           send(parent, {:held, self()})
           receive do: (:release -> "Ignored")
         end
       end}
    )

    page =
      conn
      |> visit("/w/#{ws["id"]}/c/#{id}")
      |> fill_in("#ai-input", "Message", with: "Start and wait", exact: false)
      |> click_button("#send-button", "")

    assert_receive {:held, provider}, 5_000

    page
    |> fill_in("#ai-input", "Message", with: "steered line", exact: false)
    |> click_button("#send-button", "")
    |> assert_has(".msg-bubble.msg-user", "steered line", timeout: 2_000)

    send(provider, :release)

    page
    |> assert_has(".msg-bubble.msg-assistant", "Saw the steered line", timeout: 5_000)

    assert_receive :saw_steer, 1_000
    assert E2EHarness.await_run_end(id)[:status] in ["completed", :completed]

    assert Enum.any?(
             E2EHarness.transcript(id),
             &(&1["role"] == "user" and &1["content"] == "steered line")
           )
  end

  test "queue waits until the run finishes, then starts the next run", %{
    conn: conn,
    ws: ws,
    id: id
  } do
    parent = self()

    E2EHarness.use_fake_provider!(
      {:script,
       fn messages, _tools ->
         text = messages |> Enum.map_join("\n", &Message.text/1)

         cond do
           text =~ "queued line" ->
             send(parent, :saw_queue)
             "Answered the queue"

           true ->
             send(parent, {:held, self()})
             receive do: (:release -> "First answer")
         end
       end}
    )

    page =
      conn
      |> visit("/w/#{ws["id"]}/c/#{id}")
      |> fill_in("#ai-input", "Message", with: "Start and wait", exact: false)
      |> click_button("#send-button", "")

    assert_receive {:held, provider}, 5_000

    page =
      page
      |> unwrap(fn view ->
        render_click(view, "queue_message", %{"message" => "queued line"})
      end)
      |> assert_has(".msg-bubble.msg-user", "queued line", timeout: 2_000)
      |> assert_has("#ai-messages", "Queued", timeout: 2_000)

    refute_received :saw_queue
    send(provider, :release)

    page = assert_has(page, ".msg-bubble.msg-assistant", "First answer", timeout: 5_000)
    assert E2EHarness.await_run_end(id)[:status] in ["completed", :completed]

    _page = assert_has(page, ".msg-bubble.msg-assistant", "Answered the queue", timeout: 5_000)
    assert_receive :saw_queue, 5_000

    user_texts =
      id
      |> E2EHarness.transcript()
      |> Enum.filter(&(&1["role"] == "user"))
      |> Enum.map(& &1["content"])

    assert "queued line" in user_texts
    assert "Answered the queue" in Enum.map(E2EHarness.transcript(id), & &1["content"])
  end

  test "stop cancels the open run and records a cancelled ending", %{conn: conn, ws: ws, id: id} do
    E2EHarness.use_fake_provider!(
      {:script,
       fn _messages, _tools ->
         receive do
           :release -> "Should not finish"
         end
       end}
    )

    conn
    |> visit("/w/#{ws["id"]}/c/#{id}")
    |> fill_in("#ai-input", "Message", with: "Start and wait", exact: false)
    |> click_button("#send-button", "")
    |> assert_has("[data-run-id='#{id}'][data-run-state='running']", timeout: 5_000)
    |> click_button("button[phx-click='stop_run']", "Stop")
    |> assert_has("[data-run-id='#{id}'][data-run-state='idle']", timeout: 5_000)

    payload = E2EHarness.await_run_end(id)
    assert payload[:status] in ["cancelled", :cancelled]

    assert Enum.any?(
             E2EHarness.transcript(id),
             &(&1["role"] == "user" and &1["content"] == "Start and wait")
           )
  end
end
