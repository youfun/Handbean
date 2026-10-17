defmodule Handbean.Extension.EventTest do
  use Handbean.DataCase, async: true

  alias Handbean.Extension.Event

  describe "new/3" do
    test "creates an event with known name" do
      assert {:ok, event} = Event.new(:agent_start, "session-1", %{some: "data"})
      assert event.name == :agent_start
      assert event.session_id == "session-1"
      assert event.payload == %{some: "data"}
      assert event.timestamp != nil
      assert %DateTime{} = event.timestamp
    end

    test "sets default empty payload" do
      assert {:ok, event} = Event.new(:session_start, "session-1")
      assert event.payload == %{}
    end

    test "sets default empty context" do
      assert {:ok, event} = Event.new(:session_start, "session-1", %{})
      assert event.context == %{}
    end

    test "accepts context map" do
      assert {:ok, event} =
               Event.new(:turn_start, "session-1", %{turn: 1}, %{
                 workspace_root: "/tmp",
                 model: "claude"
               })

      assert event.context == %{workspace_root: "/tmp", model: "claude"}
    end

    test "rejects non-map payload" do
      assert {:error, %{message: "event payload must be a map"}} =
               Event.new(:turn_start, "session-1", "not a map")
    end

    test "rejects non-map context" do
      assert {:error, %{message: "event context must be a map"}} =
               Event.new(:turn_start, "session-1", %{}, "not a map")
    end

    test "unknown event name returns error" do
      assert {:error, diagnostic} = Event.new(:unknown_event, "session-1")
      assert diagnostic.type == :validation_error
    end

    test "nil event name returns error" do
      assert {:error, _} = Event.new(nil, "session-1")
    end
  end

  describe "known_event?/1" do
    test "returns true for all known events" do
      known = [
        :session_start,
        :session_shutdown,
        :before_agent_start,
        :agent_start,
        :agent_end,
        :turn_start,
        :turn_end,
        :message_delta,
        :tool_start,
        :tool_end,
        :context,
        :before_provider_request,
        :after_provider_response,
        :input,
        :model_select,
        :resources_discover
      ]

      Enum.each(known, fn name ->
        assert Event.known_event?(name), "#{name} should be known"
      end)
    end

    test "returns false for unknown events" do
      refute Event.known_event?(:made_up_event)
    end

    test "valid_event? returns true for known events" do
      assert Event.valid_event?(:agent_start) == true
      assert Event.valid_event?(:nope) == false
    end
  end

  describe "secrets redaction in inspect" do
    test "secret-looking keys are redacted" do
      {:ok, event} =
        Event.new(:agent_start, "session-1", %{
          api_key: "sk-secret-123",
          token: "bearer-token",
          password: "hunter2",
          normal: "value",
          deep: %{secret: "hidden"}
        })

      assert event.payload.normal == "value"
      assert event.payload.api_key == "sk-secret-123"

      inspected = inspect(event)
      refute inspected =~ "sk-secret-123"
      refute inspected =~ "bearer-token"
      refute inspected =~ "hunter2"
      refute inspected =~ "hidden"
    end
  end

  describe "list_known_events/0" do
    test "returns list of known event names" do
      events = Event.list_known_events()
      assert :agent_start in events
      assert length(events) >= 16
    end
  end
end
