defmodule Handbean.Extension.UITest do
  use ExUnit.Case, async: true

  alias Handbean.Extension.UI

  describe "topic/1" do
    test "returns per-session topic" do
      assert UI.topic("session-123") == "extension:ui:session-123"
    end
  end

  describe "set_status/3" do
    test "broadcasts status event on per-session topic" do
      session_id = "test-status-#{System.unique_integer([:positive])}"
      topic = UI.topic(session_id)
      Phoenix.PubSub.subscribe(Handbean.PubSub, topic)

      assert :ok = UI.set_status(session_id, "goal: running [5m]")

      assert_receive {:ext_ui,
                      %{event: "status", text: "goal: running [5m]", session_id: ^session_id}},
                     100
    end

    test "clears status with nil" do
      session_id = "test-clear-#{System.unique_integer([:positive])}"
      topic = UI.topic(session_id)
      Phoenix.PubSub.subscribe(Handbean.PubSub, topic)

      assert :ok = UI.set_status(session_id, nil)
      assert_receive {:ext_ui, %{event: "status", text: nil, session_id: ^session_id}}, 100
    end

    test "different sessions have isolated topics" do
      sid1 = "iso-1-#{System.unique_integer([:positive])}"
      sid2 = "iso-2-#{System.unique_integer([:positive])}"
      topic1 = UI.topic(sid1)
      topic2 = UI.topic(sid2)

      Phoenix.PubSub.subscribe(Handbean.PubSub, topic1)
      Phoenix.PubSub.subscribe(Handbean.PubSub, topic2)

      UI.set_status(sid1, "only session 1")

      # Session 1 receives the message
      assert_receive {:ext_ui, %{event: "status", text: "only session 1", session_id: ^sid1}}, 100

      # Session 2 does NOT receive the message
      refute_receive {:ext_ui, %{event: "status", text: "only session 1"}}, 50
    end
  end

  describe "notify/4" do
    test "broadcasts notification event on per-session topic" do
      session_id = "test-notify-#{System.unique_integer([:positive])}"
      topic = UI.topic(session_id)
      Phoenix.PubSub.subscribe(Handbean.PubSub, topic)

      assert :ok = UI.notify(session_id, "warning", "Goal paused by agent")

      assert_receive {:ext_ui,
                      %{
                        event: "notify",
                        type: "warning",
                        text: "Goal paused by agent",
                        session_id: ^session_id
                      }},
                     100
    end
  end

  describe "broadcast/4" do
    test "broadcasts custom UI event on per-session topic" do
      session_id = "test-broadcast-#{System.unique_integer([:positive])}"
      topic = UI.topic(session_id)
      Phoenix.PubSub.subscribe(Handbean.PubSub, topic)

      data = %{title: "Goal Widget", status: "running", objective: "add tests"}
      assert :ok = UI.broadcast(session_id, "goal_widget", data)

      assert_receive {:ext_ui, %{event: "goal_widget", data: ^data, session_id: ^session_id}},
                     100
    end
  end
end
