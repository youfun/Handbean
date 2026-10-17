defmodule Handbean.PubSub.ProjectionTest do
  use ExUnit.Case, async: true

  alias Handbean.PubSub.{AgentEvent, Projection}

  # Boundary failures: another topic, duplicate/reordered seq, a missing seq,
  # snapshot/live overlap, UTF-8 byte offsets, and a missing text prefix.
  # None may duplicate, regress, or silently fabricate transcript text.
  test "sequence classification distinguishes gaps from stale events" do
    assert Projection.classify(AgentEvent.message_delta("session:a", "x", 8), "session:a", 7) ==
             :apply

    assert Projection.classify(AgentEvent.message_delta("session:a", "x", 7), "session:a", 7) ==
             :ignore

    assert Projection.classify(AgentEvent.message_delta("session:a", "x", 6), "session:a", 7) ==
             :ignore

    assert Projection.classify(AgentEvent.message_delta("session:a", "x", 9), "session:a", 7) ==
             :recover

    assert Projection.classify(AgentEvent.message_delta("session:b", "x", 8), "session:a", 7) ==
             :ignore
  end

  test "persisted text patches overlap a loaded snapshot without duplicating or regressing it" do
    entry = %{"id" => "reply", "content" => "你好 world", "status" => "completed"}

    assert :ignore =
             Projection.text_patch([entry], %{
               transcript_id: "reply",
               text_offset: 6,
               text: " world"
             })

    assert {:ok, patched} =
             Projection.text_patch([%{entry | "content" => "你好"}], %{
               transcript_id: "reply",
               text_offset: 6,
               text: " world"
             })

    assert patched["content"] == "你好 world"

    assert :recover =
             Projection.text_patch([], %{transcript_id: "reply", text_offset: 6, text: " world"})

    assert {:ok, new} =
             Projection.text_patch([], %{transcript_id: "new", text_offset: 0, text: "α"})

    assert new["id"] == "new"
    assert new["content"] == "α"
  end

  test "terminal status excludes approval waits and unknown status values" do
    for status <- [
          :interrupted,
          "interrupted",
          :awaiting_approval,
          "awaiting_approval",
          nil,
          "unknown"
        ] do
      refute AgentEvent.terminal_status?(status)
    end

    for status <- [
          :completed,
          "cancelled",
          :error,
          "timeout",
          :halted,
          "max_turns",
          :budget_exceeded,
          "stalled"
        ] do
      assert AgentEvent.terminal_status?(status)
    end
  end
end
