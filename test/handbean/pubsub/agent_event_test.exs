defmodule Handbean.PubSub.AgentEventTest do
  @moduledoc """
  Tests for AgentEvent struct and factory functions.

  Reference: `alloy/` (event pubsub pattern)
  Test pattern: hand-written

  Covers:
    - Event creation with seq
    - Message delta events
    - Tool start/end events
    - Run start/end events
    - Monotonic seq tracking
  """

  use ExUnit.Case, async: true

  alias Handbean.PubSub.AgentEvent

  describe "new/4 — event creation" do
    test "creates an event with topic, kind, payload, and seq" do
      event = AgentEvent.new("session:abc", :run_start, %{model: "claude"}, 1)

      assert event.topic == "session:abc"
      assert event.kind == :run_start
      assert event.payload == %{model: "claude"}
      assert event.seq == 1
      assert event.ts_ms > 0
    end

    test "seq increments monotonically" do
      e1 = AgentEvent.new("topic", :run_start, %{}, 1)
      e2 = AgentEvent.new("topic", :tool_start, %{}, 2)
      e3 = AgentEvent.new("topic", :run_end, %{}, 3)

      assert e1.seq < e2.seq
      assert e2.seq < e3.seq
    end
  end

  describe "message_delta/3" do
    test "creates a message_delta event" do
      event = AgentEvent.message_delta("session:x", "Hello", 5)

      assert event.kind == :message_delta
      assert event.payload.chunk == "Hello"
      assert event.seq == 5
    end
  end

  describe "tool_start/4" do
    test "creates a tool_start event with tool name and input" do
      event = AgentEvent.tool_start("session:x", "read", %{file_path: "a.txt"}, 10)

      assert event.kind == :tool_start
      assert event.payload.tool == "read"
      assert event.payload.input.file_path == "a.txt"
      assert event.seq == 10
    end
  end

  describe "tool_end/5" do
    test "creates a tool_end event with duration and error flag" do
      event = AgentEvent.tool_end("session:x", "read", 1500, false, 11)

      assert event.kind == :tool_end
      assert event.payload.tool == "read"
      assert event.payload.duration_ms == 1500
      assert event.payload.error == false
      assert event.seq == 11
    end

    test "tool_end with error flag" do
      event = AgentEvent.tool_end("session:x", "bash", 500, true, 12)

      assert event.payload.error == true
    end
  end

  describe "run_start/4" do
    test "creates a run_start event with model and prompt" do
      event = AgentEvent.run_start("session:x", "claude-sonnet-4", "List files", 0)

      assert event.kind == :run_start
      assert event.payload.model == "claude-sonnet-4"
      assert event.payload.prompt == "List files"
      assert event.seq == 0
    end
  end

  describe "run_end/4" do
    test "creates a run_end event with status and turns" do
      event = AgentEvent.run_end("session:x", :completed, 5, 15)

      assert event.kind == :run_end
      assert event.payload.status == :completed
      assert event.payload.turns == 5
      assert event.seq == 15
    end
  end
end
