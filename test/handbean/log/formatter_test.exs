defmodule Handbean.Log.FormatterTest do
  @moduledoc """
  Tests for Handbean.Log.Formatter — event serialization and deserialization.
  """
  use ExUnit.Case, async: true

  alias Handbean.Log.{Event, Formatter, Redactor}

  describe "to_map/1" do
    test "converts event to plain map with all fields" do
      {:ok, event} =
        Event.new(
          kind: :tool,
          level: :info,
          message: "read file",
          session_id: "sess-001",
          turn: 3,
          source: "read_tool",
          metadata: %{file_path: "/tmp/test.exs"}
        )

      map = Formatter.to_map(event)

      assert is_map(map)
      assert map["id"] == event.id
      assert map["kind"] == "tool"
      assert map["level"] == "info"
      assert map["message"] == "read file"
      assert map["timestamp"] == event.timestamp
      assert map["session_id"] == "sess-001"
      assert map["turn"] == 3
      assert map["source"] == "read_tool"
      assert map["metadata"] == %{file_path: "/tmp/test.exs"}
    end

    test "handles event with nil optional fields" do
      {:ok, event} = Event.new(kind: :general, level: :debug, message: "test")

      map = Formatter.to_map(event)

      assert map["session_id"] == nil
      assert map["turn"] == nil
      assert map["source"] == nil
      assert map["metadata"] == %{}
    end

    test "stringifies atom kind and level" do
      {:ok, event} = Event.new(kind: :security, level: :warning, message: "alert")
      map = Formatter.to_map(event)
      assert map["kind"] == "security"
      assert map["level"] == "warning"
    end
  end

  describe "to_json/1" do
    test "produces valid JSON string" do
      {:ok, event} =
        Event.new(
          kind: :session,
          level: :info,
          message: "started",
          session_id: "s-1",
          turn: 0
        )

      json = Formatter.to_json(event)

      assert is_binary(json)
      assert String.starts_with?(json, "{")
      assert String.ends_with?(json, "}")

      decoded = Jason.decode!(json)
      assert decoded["kind"] == "session"
      assert decoded["level"] == "info"
      assert decoded["message"] == "started"
      assert decoded["session_id"] == "s-1"
      assert decoded["turn"] == 0
      assert decoded["metadata"] == %{}
    end

    test "roundtrip preserves all data" do
      {:ok, event} =
        Event.new(
          kind: :provider,
          level: :error,
          message: "timeout",
          session_id: "sess-abc",
          turn: 5,
          source: "anthropic",
          metadata: %{status: 429, retries: 3}
        )

      json = Formatter.to_json(event)
      decoded_map = Jason.decode!(json)

      # JSON roundtrip converts atom metadata keys to strings
      # but the core fields (kind/level) roundtrip through from_map correctly
      expected_metadata = %{"retries" => 3, "status" => 429}

      {:ok, reconstructed} = Formatter.from_map(decoded_map)

      assert reconstructed.id == event.id
      assert reconstructed.kind == event.kind
      assert reconstructed.level == event.level
      assert reconstructed.message == event.message
      assert reconstructed.timestamp == event.timestamp
      assert reconstructed.session_id == event.session_id
      assert reconstructed.turn == event.turn
      assert reconstructed.source == event.source
      assert reconstructed.metadata == expected_metadata
    end
  end

  describe "from_map/1" do
    test "reconstructs event from valid string-key map" do
      map = %{
        "id" => "abc-123",
        "kind" => "tool",
        "level" => "info",
        "message" => "bash executed",
        "timestamp" => 1_700_000_000_000,
        "session_id" => "sess-1",
        "turn" => 2,
        "source" => "bash_tool",
        "metadata" => %{"cmd" => "ls"}
      }

      {:ok, event} = Formatter.from_map(map)

      assert event.id == "abc-123"
      assert event.kind == :tool
      assert event.level == :info
      assert event.message == "bash executed"
      assert event.timestamp == 1_700_000_000_000
      assert event.session_id == "sess-1"
      assert event.turn == 2
      assert event.source == "bash_tool"
      assert event.metadata == %{"cmd" => "ls"}
    end

    test "reconstructs event from atom-key map" do
      map = %{
        id: "xyz-456",
        kind: "general",
        level: "debug",
        message: "ping",
        timestamp: 1_700_000_000_000,
        session_id: nil,
        turn: nil,
        source: nil,
        metadata: %{}
      }

      {:ok, event} = Formatter.from_map(map)

      assert event.id == "xyz-456"
      assert event.kind == :general
      assert event.level == :debug
      assert event.message == "ping"
    end

    test "returns error for missing required field" do
      map = %{"kind" => "tool", "level" => "info"}

      assert {:error, reason} = Formatter.from_map(map)
      assert reason == :invalid_event_map
    end

    test "returns error for invalid kind string" do
      map = %{
        "id" => "abc",
        "kind" => "not_a_real_kind_xyz",
        "level" => "info",
        "message" => "test",
        "timestamp" => 1_700_000_000_000
      }

      assert {:error, reason} = Formatter.from_map(map)
      assert reason == :invalid_kind
    end

    test "returns error for invalid level string" do
      map = %{
        "id" => "abc",
        "kind" => "general",
        "level" => "not_a_real_level_xyz",
        "message" => "test",
        "timestamp" => 1_700_000_000_000
      }

      assert {:error, reason} = Formatter.from_map(map)
      assert reason == :invalid_level
    end
  end

  describe "to_json/1 — redaction safety" do
    test "secret values in metadata are never leaked in JSON output" do
      {:ok, event} =
        Event.new(
          kind: :provider,
          level: :error,
          message: "API error",
          metadata: %{
            request: %{
              headers: %{
                "Authorization" => "Bearer sk-abc-secret-token",
                "Content-Type" => "application/json"
              }
            }
          }
        )

      # Apply redaction to event metadata before formatting
      safe_event = %{event | metadata: Redactor.redact(event.metadata)}

      json = Formatter.to_json(safe_event)

      refute json =~ "sk-abc-secret-token"
      assert json =~ "[REDACTED]"
      assert json =~ "application/json"
    end
  end
end
