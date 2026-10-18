defmodule HandbeanWeb.Feature.ConversationActivityTest do
  use HandbeanWeb.FeatureCase, async: false

  alias Handbean.Agent.Coordinator
  alias Handbean.ConversationStore
  alias Handbean.PubSub.Session

  @moduletag :e2e

  test "background run survives navigation and reload, pauses for approval, then clears on completion",
       %{conn: conn} do
    old_home = System.get_env("HOME")
    home = Path.join(System.tmp_dir!(), "activity-#{Ecto.UUID.generate()}")
    workspace = Path.join(home, "workspace")
    File.mkdir_p!(Path.join(workspace, ".handbean"))

    File.write!(
      Path.join(workspace, ".handbean/settings.jsonc"),
      Handbean.JSON.encode!(%{"tools" => %{"per_tool" => %{"write" => "prompt"}}})
    )

    System.put_env("HOME", home)
    {:ok, ws} = Handbean.WorkspaceStore.ensure_default!()
    {:ok, active} = ConversationStore.create(ws["id"], title: "Active fixture")
    {:ok, other} = ConversationStore.create(ws["id"], title: "Other fixture")
    id = active["id"]

    on_exit(fn ->
      Handbean.TestSupport.E2EHarness.stop_runtime!()
      if old_home, do: System.put_env("HOME", old_home), else: System.delete_env("HOME")
      File.rm_rf!(home)
    end)

    parent = self()

    script = fn messages, _tools ->
      if Enum.any?(messages, &(&1.role == :tool_result)) do
        send(parent, {:resumed_provider, self()})
        receive do: (:finish -> "Activity verified")
      else
        send(parent, {:started_provider, self()})

        receive do: (:request_tool ->
                       {:tools,
                        [
                          %{
                            name: "write",
                            input: %{"file_path" => "result.txt", "content" => "verified"}
                          }
                        ]})
      end
    end

    :ok = Session.subscribe(id)
    page = visit(conn, "/w/#{ws["id"]}/c/#{other["id"]}")

    assert {:ok, _} =
             Coordinator.add_message(id, "Write the result",
               workspace_path: workspace,
               model: "fake-model",
               provider: Handbean.TestSupport.FakeProvider,
               provider_config: %{scenario: {:script, script}},
               tools: Handbean.Agent.default_tools(),
               source: :cli,
               streaming: false
             )

    assert_receive {:started_provider, provider}, 5_000
    selector = "[data-run-id='#{id}']"
    page = assert_has(page, selector <> "[data-run-state='running']", timeout: 2_000)

    page =
      click_button(
        page,
        "#conversation-#{id} button[phx-click='select_conversation']",
        "Active fixture"
      )

    page = assert_has(page, selector <> "[data-run-state='running']")
    page = visit(page, "/w/#{ws["id"]}/c/#{id}")
    page = assert_has(page, selector <> "[data-run-state='running']")

    send(provider, :request_tool)
    page = assert_has(page, selector <> "[data-run-state='waiting_confirmation']", timeout: 2_000)
    page = assert_has(page, "#tool-approval-overlay", timeout: 2_000)
    page = click_button(page, "Allow once")
    assert_receive {:resumed_provider, resumed}, 5_000
    page = assert_has(page, selector <> "[data-run-state='running']", timeout: 2_000)
    assert_receive {:agent_event, %{kind: :tool_end}}, 2_000
    assert File.read!(Path.join(workspace, "result.txt")) == "verified"

    page = visit(page, "/w/#{ws["id"]}/c/#{other["id"]}")
    page = visit(page, "/w/#{ws["id"]}/c/#{id}")
    page = assert_has(page, selector <> "[data-run-state='running']")
    page = refute_has(page, "#tool-approval-overlay")

    send(resumed, :finish)
    page = assert_has(page, selector <> "[data-run-state='idle']", timeout: 2_000)
    refute_has(page, selector <> "[role='img']")
    assert_receive {:agent_event, %{kind: :run_end, payload: %{status: :completed}}}, 2_000
    {:ok, entries} = Handbean.ConversationTranscriptStore.list(id)
    assert Enum.any?(entries, &(&1["content"] == "Activity verified"))
  end
end
