defmodule Handbean.PubSub.Session.RecoveryProjectionTest do
  use ExUnit.Case, async: true

  alias Handbean.PubSub.AgentEvent
  alias Handbean.PubSub.Session.RecoveryProjection

  test "run boundaries reset controls while resume preserves active tools" do
    events = [
      event(1, :run_start, %{run_id: "current"}),
      event(2, :session_state, %{run_id: "current", state: :old}),
      event(3, :tool_start, %{run_id: "current", tool_use_id: "old-tool"}),
      event(4, :tool_approval_requested, %{run_id: "current"}),
      event(5, :run_start, %{"run_id" => "current"}),
      event(6, :session_state, %{run_id: "current", state: :working}),
      event(7, :tool_approval_requested, %{run_id: "current"}),
      event(8, :tool_start, %{run_id: "current", tool_use_id: "active"}),
      event(9, :run_resumed, %{"run_id" => "current"}),
      event(10, :turn_start, %{run_id: "current"}),
      event(11, :usage_updated, %{run_id: "current"}),
      event(12, :run_start, %{run_id: "other"})
    ]

    projected = RecoveryProjection.events(Enum.reverse(events), "current")

    assert Enum.map(projected, & &1.seq) == [5, 9, 10, 11, 8]
    refute Enum.any?(projected, &(&1.kind == :session_state))
    refute Enum.any?(projected, &(&1.kind == :tool_approval_requested))
    refute Enum.any?(projected, &(&1.seq == 3))
  end

  test "pairs tools by atom or string identifiers and keeps active tools" do
    events = [
      event(1, :run_start, %{run_id: "run"}),
      event(2, :tool_start, %{"run_id" => "run", "tool_use_id" => "done"}),
      event(3, :tool_start, %{run_id: "run", tool_use_id: "active"}),
      event(4, :tool_end, %{run_id: "run", tool_use_id: "done"})
    ]

    projected = RecoveryProjection.events(events, "run")

    assert Enum.map(projected, & &1.seq) == [1, 3]
  end

  test "pending candidate events span runs and remain sequenced" do
    events = [
      event(4, :candidate_message_deleted, %{run_id: "new"}),
      event(3, :tool_start, %{run_id: "new"}),
      event(2, :candidate_message_injected, %{"run_id" => "old"})
    ]

    assert RecoveryProjection.pending_events(events) |> Enum.map(& &1.seq) == [2, 4]
  end

  defp event(seq, kind, payload) do
    AgentEvent.new("session:test", kind, payload, seq)
  end
end
