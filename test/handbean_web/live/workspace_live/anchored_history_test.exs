defmodule HandbeanWeb.WorkspaceLive.AnchoredHistoryTest do
  use ExUnit.Case, async: true

  alias Handbean.PubSub.AgentEvent
  alias HandbeanWeb.WorkspaceLive.RuntimeProjection
  alias HandbeanWeb.WorkspaceLive.RuntimeProjection.Timeline

  test "runtime inserts outside an around window do not replace history and mark newer content" do
    socket = socket([entry("old", 10), entry("anchor", 11), entry("new", 12)])

    updated = Timeline.timeline_insert(socket, entry("outside", 13))

    assert updated.assigns.timeline == socket.assigns.timeline
    assert updated.assigns.history_has_newer?
  end

  test "reconciliation respects both around-window boundaries" do
    socket = socket([entry("old", 10), entry("anchor", 11), entry("new", 12)])

    updated =
      Timeline.reconcile_transcript(socket, [
        entry("too-old", 9),
        entry("too-new", 13)
      ])

    assert updated.assigns.timeline == socket.assigns.timeline
    assert updated.assigns.history_has_newer?
  end

  test "streaming text outside an around window updates control state without appending text" do
    socket =
      socket([entry("old", 10), entry("anchor", 11), entry("new", 12)])
      |> Phoenix.Component.assign(:current_assistant_entry_id, nil)
      |> Phoenix.Component.assign(:think_buffer, "")
      |> Phoenix.Component.assign(:thinking_active, false)

    updated = Timeline.update_messages(socket, "new response")

    assert updated.assigns.timeline == socket.assigns.timeline
    assert updated.assigns.history_has_newer?
    assert is_binary(updated.assigns.current_assistant_entry_id)
  end

  test "sequential persisted deltas outside the window advance admission without recovery" do
    socket = socket([entry("old", 10), entry("anchor", 11), entry("new", 12)])

    updated =
      Enum.reduce(1..3, socket, fn sequence, acc ->
        RuntimeProjection.handle_current_agent_event(
          %AgentEvent{
            topic: "session:conversation",
            epoch: "epoch-1",
            seq: sequence,
            kind: :message_delta,
            payload: %{
              transcript_id: "outside-assistant",
              text_offset: sequence * 5,
              text: "chunk"
            }
          },
          acc
        )
      end)

    assert updated.assigns.timeline == socket.assigns.timeline
    assert updated.assigns.session_seq == 3
    assert updated.assigns.current_assistant_entry_id == "outside-assistant"
    assert updated.assigns.history_has_newer?
  end

  defp socket(timeline) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        history_window: :around,
        history_has_more?: true,
        history_has_newer?: false,
        current_conversation_id: "conversation",
        current_assistant_entry_id: nil,
        session_seq: 0,
        session_epoch: "epoch-1",
        timeline: timeline
      }
    }
  end

  defp entry(id, sequence) do
    %{
      "id" => id,
      "sequence" => sequence,
      "role" => "assistant",
      "content_type" => "assistant_msg",
      "content" => id
    }
  end
end
