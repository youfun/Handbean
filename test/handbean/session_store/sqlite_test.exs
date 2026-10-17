defmodule Handbean.SessionStore.SQLiteTest do
  use Handbean.DataCase, async: false

  alias Handbean.{ConversationStore, SessionStore}
  alias Handbean.SessionStore.SQLite

  setup do
    id = "session-store-#{System.unique_integer([:positive])}"
    {:ok, _conversation} = ConversationStore.create("default", id: id)
    %{id: id}
  end

  test "saves, loads, updates, lists, and deletes a redacted projection", %{id: id} do
    snapshot = %{
      "seq" => 2,
      "agent_pid" => self(),
      "next_turn_messages" => [%{"content" => "later"}],
      "events" => [%{"payload" => %{"api_key" => "secret"}}]
    }

    assert :ok = SQLite.save(id, snapshot)
    assert {:ok, loaded} = SQLite.load(id)
    assert loaded["seq"] == 2
    refute Map.has_key?(loaded, "agent_pid")
    assert loaded["events"] == [%{"payload" => %{"api_key" => "[REDACTED]"}}]

    assert :ok = SQLite.update(id, %{"model" => "fake"})
    assert {:ok, %{"model" => "fake", "seq" => 2}} = SQLite.load(id)
    assert {:ok, ids} = SQLite.list_active()
    assert id in ids

    assert :ok = SQLite.delete(id)
    assert {:error, :not_found} = SQLite.load(id)
  end

  test "prepare_snapshot recursively strips runtime handles" do
    prepared =
      SessionStore.prepare_snapshot(%{
        "nested" => [%{"task_ref" => make_ref(), "kept" => true}],
        pid: self()
      })

    refute Map.has_key?(prepared, :pid)
    assert prepared["nested"] == [%{"kept" => true}]
  end

  test "foreign key rejects snapshots without a conversation" do
    assert {:error, :not_found} = SQLite.save("missing-conversation", %{"seq" => 1})
  end
end
