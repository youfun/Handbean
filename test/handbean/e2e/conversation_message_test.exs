defmodule Handbean.E2E.ConversationMessageTest do
  @moduledoc """
  A parent run calls `create_conversation`. The child conversation is created in the
  same workspace and its transcript contains the delegated message.

  Run: mix test --include e2e test/handbean/e2e/conversation_message_test.exs
  """

  use ExUnit.Case, async: false

  alias Handbean.Agent.Coordinator
  alias Handbean.ConversationStore
  alias Handbean.PubSub.Session
  alias Handbean.TestSupport.E2EHarness

  @moduletag :e2e

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Handbean.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Handbean.Repo, {:shared, self()})
    :ok
  end

  test "create_conversation delivers the task into the child transcript" do
    %{workspace: workspace} = E2EHarness.isolate_home!("conversation-message")
    {:ok, ws} = Handbean.WorkspaceStore.add(workspace, name: "Conversations")
    {:ok, parent} = ConversationStore.create(ws["id"], title: "Parent")
    :ok = Session.subscribe(parent["id"])

    ExUnit.Callbacks.on_exit(fn -> E2EHarness.cancel!(parent["id"]) end)

    script = fn messages, _tools ->
      if Enum.any?(messages, &(&1.role == :tool_result)) do
        "Delegated"
      else
        {:tools,
         [
           %{
             name: "create_conversation",
             input: %{
               "title" => "Audit",
               "message" => "Inspect the marker ORCHID-4401",
               "request_id" => "req-conversation-e2e"
             }
           }
         ]}
      end
    end

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(parent["id"], "Delegate the audit",
               workspace_path: workspace,
               workspace_id: ws["id"],
               model: "fake-model",
               provider: Handbean.TestSupport.FakeProvider,
               provider_config: %{scenario: {:script, script}, api_key: "sk-fake"},
               tools: Handbean.Agent.default_tools(),
               source: :cli,
               streaming: false
             )

    payload = E2EHarness.await_run_end(parent["id"])
    assert payload[:status] in ["completed", :completed]

    parent_entries = E2EHarness.transcript(parent["id"])

    handoff =
      Enum.find(parent_entries, &(&1["content_type"] == "conversation_handoff")) ||
        flunk("missing handoff: #{inspect(parent_entries)}")

    child_id = handoff["target"]
    assert child_id =~ "delegated-"

    {:ok, child} = ConversationStore.get_metadata(child_id)
    assert child["workspace_id"] == ws["id"]
    assert child["parent_conversation_id"] == parent["id"]
    refute Map.has_key?(child["collaboration"], "parent")

    child_entries = E2EHarness.transcript(child_id)

    assert Enum.any?(
             child_entries,
             &(&1["role"] == "user" and &1["content"] =~ "Inspect the marker ORCHID-4401")
           )
  end
end
