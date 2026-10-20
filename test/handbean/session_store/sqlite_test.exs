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

  test "ordinary snapshots preserve distinct event and control histories", %{id: id} do
    snapshot = %{
      "seq" => 2,
      "events" => [
        %{"kind" => "message_delta", "seq" => 2, "payload" => %{"chunk" => "visible"}}
      ],
      "control_events" => [
        %{"kind" => "run_start", "seq" => 1, "payload" => %{"run_id" => "run-1"}}
      ]
    }

    assert :ok = SQLite.save(id, snapshot)
    assert {:ok, ^snapshot} = SQLite.load(id)
  end

  test "recovery projection redacts restored output and isolates reused tool ids by run", %{
    id: id
  } do
    for {run_id, entry_id, output} <- [
          {"run-a", "tool-run-a-shared", "run a api_key=first-secret"},
          {"run-b", "tool-run-b-shared", "run b password=second-secret"},
          {"run-c", "tool-run-c-shared", %{"items" => [1, true], "status" => "ok"}},
          {"run-array", "tool-run-array-shared", [1, "two"]},
          {"run-true", "tool-run-true-shared", true},
          {"run-false", "tool-run-false-shared", false},
          {"run-null", "tool-run-null-shared", nil},
          {"run-big-positive", "tool-run-big-positive-shared", 18_446_744_073_709_551_617},
          {"run-big-negative", "tool-run-big-negative-shared", -18_446_744_073_709_551_617},
          {"run-duplicate", "tool-run-duplicate-first", "first output"},
          {"run-duplicate", "tool-run-duplicate-later", "later output"}
        ] do
      assert {:ok, _entry} =
               Handbean.ConversationTranscriptStore.append(id, %{
                 "id" => entry_id,
                 "content_type" => "tool",
                 "role" => "tool",
                 "run_id" => run_id,
                 "tool_use_id" => "shared",
                 "output" => output
               })
    end

    events = [
      tool_end_event("run-duplicate", "shared", "snapshot duplicate"),
      tool_end_event("run-big-negative", "shared", "snapshot big negative"),
      tool_end_event("run-big-positive", "shared", "snapshot big positive"),
      tool_end_event("run-null", "shared", "snapshot null"),
      tool_end_event("run-false", "shared", "snapshot false"),
      tool_end_event("run-true", "shared", "snapshot true"),
      tool_end_event("run-array", "shared", "snapshot array"),
      tool_end_event("run-c", "shared", "snapshot output c"),
      tool_end_event("run-b", "shared", "snapshot output b"),
      tool_end_event("run-a", "shared", "snapshot output a")
    ]

    snapshot = %{"seq" => 2, "events" => events, "control_events" => events}

    assert :ok = SQLite.save(id, snapshot, recovery_projection?: true)
    assert {:ok, loaded} = SQLite.load(id)

    by_run = Map.new(loaded["events"], &{&1["payload"]["run_id"], &1["payload"]["output"]})
    assert by_run["run-a"] == "run a api_key=[REDACTED]"
    assert by_run["run-b"] == "run b password=[REDACTED]"
    assert by_run["run-c"] == %{"items" => [1, true], "status" => "ok"}
    assert by_run["run-array"] == [1, "two"]
    assert by_run["run-true"] == true
    assert by_run["run-false"] == false
    assert by_run["run-null"] == nil
    assert by_run["run-big-positive"] === 18_446_744_073_709_551_617
    assert by_run["run-big-negative"] === -18_446_744_073_709_551_617
    assert by_run["run-duplicate"] == "first output"

    null_event = Enum.find(loaded["events"], &(&1["payload"]["run_id"] == "run-null"))
    assert Map.has_key?(null_event["payload"], "output")
    refute inspect(loaded) =~ "first-secret"
    refute inspect(loaded) =~ "second-secret"
  end

  test "internal session recovery keeps its redacted output without bypassing transcript access" do
    id = "internal-session-store-#{System.unique_integer([:positive])}"
    {:ok, _conversation} = ConversationStore.create("default", id: id, visibility: "internal")
    event = tool_end_event("internal-run", "internal-tool", "body api_key=internal-secret")
    snapshot = %{"seq" => 1, "events" => [event], "control_events" => [event]}

    assert {:error, :not_found} = Handbean.ConversationTranscriptStore.list(id)
    assert :ok = SQLite.save(id, snapshot, recovery_projection?: true)
    assert {:ok, loaded} = SQLite.load(id)

    assert [loaded_event] = loaded["events"]
    assert loaded_event["payload"]["output"] == "body api_key=[REDACTED]"
    refute inspect(loaded) =~ "internal-secret"
  end

  test "missing canonical tool output keeps recovery controls without resurrecting snapshot text",
       %{
         id: id
       } do
    run_id = "run-missing-output"
    tool_use_id = "missing-output"
    entry_id = "tool-missing-output"

    assert {:ok, _entry} =
             Handbean.ConversationTranscriptStore.append(id, %{
               "id" => entry_id,
               "content_type" => "tool",
               "role" => "tool",
               "run_id" => run_id,
               "tool_use_id" => tool_use_id,
               "output" => "deleted canonical output"
             })

    events = [
      tool_end_event(run_id, tool_use_id, "snapshot must not restore this output"),
      %{
        "kind" => "tool_approval_requested",
        "seq" => 8,
        "payload" => %{
          "run_id" => run_id,
          "action_requests" => [%{"tool_call_id" => "approval", "tool_name" => "edit"}]
        }
      },
      %{
        "kind" => "tool_start",
        "seq" => 7,
        "payload" => %{
          "run_id" => run_id,
          "tool_use_id" => "active-tool",
          "tool" => "bash"
        }
      }
    ]

    snapshot = %{
      "seq" => 9,
      "events" => events,
      "control_events" => events,
      "next_turn_messages" => [%{"id" => "next", "content" => "continue later"}],
      "extension_state" => %{"checkpoint" => %{"value" => 42}}
    }

    assert :ok = SQLite.save(id, snapshot, recovery_projection?: true)
    assert :ok = Handbean.ConversationTranscriptStore.delete(id, entry_id)
    assert {:ok, loaded} = SQLite.load(id)

    assert loaded["seq"] == 9
    assert loaded["next_turn_messages"] == [%{"id" => "next", "content" => "continue later"}]
    assert loaded["extension_state"] == %{"checkpoint" => %{"value" => 42}}

    assert Enum.any?(loaded["control_events"], &(&1["kind"] == "tool_approval_requested"))

    assert Enum.any?(loaded["control_events"], fn event ->
             event["kind"] == "tool_start" and event["payload"]["tool_use_id"] == "active-tool"
           end)

    refute Enum.any?(loaded["events"], fn event ->
             Map.has_key?(event["payload"], "output")
           end)
  end

  test "foreign key rejects snapshots without a conversation" do
    assert {:error, :not_found} = SQLite.save("missing-conversation", %{"seq" => 1})
  end

  defp tool_end_event(run_id, tool_use_id, output) do
    %{
      "kind" => "tool_end",
      "payload" => %{
        "run_id" => run_id,
        "tool_use_id" => tool_use_id,
        "output" => output
      }
    }
  end
end
