defmodule Handbean.PubSub.Session.SnapshotCodecTest do
  use ExUnit.Case, async: true

  alias Handbean.Agent.Message
  alias Handbean.PubSub.AgentEvent
  alias Handbean.PubSub.Session.SnapshotCodec

  test "loads event structs and persisted maps while dropping malformed entries" do
    struct_event = AgentEvent.new("session:test", :run_start, %{}, 1)

    persisted = %{
      "seq" => 2,
      "epoch" => "epoch",
      "topic" => "session:test",
      "kind" => "tool_start",
      "payload" => %{"tool" => "read"},
      "ts_ms" => 10
    }

    assert [^struct_event, %AgentEvent{} = loaded] =
             SnapshotCodec.events([struct_event, persisted, :malformed])

    assert loaded.seq == 2
    assert loaded.kind == :tool_start
    assert loaded.payload == %{"tool" => "read"}
    assert SnapshotCodec.events(:malformed) == []
  end

  test "does not create atoms for unknown event kinds or message roles" do
    suffix = Integer.to_string(System.unique_integer([:positive]))
    unknown_kind = "unknown_kind_#{suffix}"
    unknown_role = "unknown_role_#{suffix}"

    assert [%AgentEvent{kind: ^unknown_kind}] =
             SnapshotCodec.events([%{"kind" => unknown_kind}])

    assert [%Message{role: ^unknown_role}] =
             SnapshotCodec.messages([%{"role" => unknown_role, "content" => "kept"}])

    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown_kind) end
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown_role) end
  end

  test "converts any existing atom string but leaves atom-keyed values unchanged" do
    existing = "codec_characterization_atom"

    assert [%AgentEvent{kind: :codec_characterization_atom}] =
             SnapshotCodec.events([%{"kind" => existing}])

    assert [%AgentEvent{kind: ^existing}] = SnapshotCodec.events([%{kind: existing}])
    assert [%Message{role: ^existing}] = SnapshotCodec.messages([%{role: existing}])
  end

  test "loads message structs and maps while dropping malformed entries" do
    struct_message = Message.user("struct")

    assert [^struct_message, %Message{role: :assistant, content: "map"}] =
             SnapshotCodec.messages([
               struct_message,
               %{"role" => "assistant", "content" => "map"},
               nil
             ])

    assert SnapshotCodec.messages(%{}) == []
  end

  test "encodes the established snapshot schema without runtime-only fields" do
    event = %{AgentEvent.new("session:test", :run_start, %{}, 7) | epoch: "event-epoch"}

    usage_event =
      %{
        AgentEvent.new("session:test", :usage_updated, %{run_id: "runtime-run"}, 8)
        | epoch: "event-epoch"
      }

    message = %Message{role: :user, content: "next", id: "message-id"}

    snapshot =
      SnapshotCodec.encode(%{
        seq: 7,
        epoch: "runtime-epoch",
        events: [event],
        control_events: [event],
        latest_usage_event: usage_event,
        meta: %{running?: true, run_id: "runtime-run"},
        model: "model-from-state",
        next_turn_messages: [message],
        extension_state: %{"extension" => %{"key" => "value"}}
      })

    assert Map.keys(snapshot) |> Enum.sort() ==
             Enum.sort([
               "seq",
               "events",
               "control_events",
               "latest_usage_event",
               "running?",
               "model",
               "next_turn_messages",
               "extension_state"
             ])

    assert snapshot["model"] == "model-from-state"
    assert snapshot["running?"] == true
    refute Map.has_key?(snapshot, "epoch")
    refute Map.has_key?(snapshot, "run_id")
    assert [%{kind: :run_start, epoch: "event-epoch"}] = snapshot["events"]
    assert %{kind: :usage_updated, epoch: "event-epoch"} = snapshot["latest_usage_event"]
    assert [%{role: :user, id: "message-id"}] = snapshot["next_turn_messages"]
  end
end
