defmodule Handbean.Log.EventTest do
  @moduledoc """
  Tests for Handbean.Log.Event struct creation and validation.
  """
  use ExUnit.Case, async: true

  alias Handbean.Log.Event

  describe "new/1" do
    test "creates event with all required fields" do
      {:ok, event} =
        Event.new(
          kind: :session,
          level: :info,
          message: "Session started",
          session_id: "sess-001",
          turn: 1
        )

      assert event.kind == :session
      assert event.level == :info
      assert event.message == "Session started"
      assert event.session_id == "sess-001"
      assert event.turn == 1
    end

    test "auto-generates id as UUID string" do
      {:ok, event} = Event.new(kind: :general, level: :debug, message: "test")
      assert is_binary(event.id)
      assert String.match?(event.id, ~r/^[0-9a-f\-]{36}$/)
    end

    test "auto-generates timestamp" do
      {:ok, event} = Event.new(kind: :general, level: :debug, message: "test")
      assert is_integer(event.timestamp)
      assert event.timestamp > 0
    end

    test "defaults source to nil" do
      {:ok, event} = Event.new(kind: :general, level: :debug, message: "test")
      assert event.source == nil
    end

    test "defaults metadata to empty map" do
      {:ok, event} = Event.new(kind: :general, level: :debug, message: "test")
      assert event.metadata == %{}
    end

    test "defaults session_id to nil" do
      {:ok, event} = Event.new(kind: :general, level: :debug, message: "test")
      assert event.session_id == nil
    end

    test "defaults turn to nil" do
      {:ok, event} = Event.new(kind: :general, level: :debug, message: "test")
      assert event.turn == nil
    end

    test "accepts source field" do
      {:ok, event} =
        Event.new(kind: :tool, level: :info, message: "tool call", source: "read_tool")

      assert event.source == "read_tool"
    end

    test "accepts metadata map" do
      {:ok, event} =
        Event.new(
          kind: :provider,
          level: :debug,
          message: "API call",
          metadata: %{model: "claude", duration_ms: 150}
        )

      assert event.metadata == %{model: "claude", duration_ms: 150}
    end

    test "accepts all known kind values" do
      kinds = [
        :session,
        :tool,
        :provider,
        :memory,
        :security,
        :extension,
        :ui,
        :general
      ]

      for k <- kinds do
        {:ok, event} = Event.new(kind: k, level: :info, message: "test")
        assert event.kind == k, "expected kind #{k} to be valid"
      end
    end

    test "accepts all known level values" do
      levels = [:debug, :info, :warning, :error]

      for l <- levels do
        {:ok, event} = Event.new(kind: :general, level: l, message: "test")
        assert event.level == l, "expected level #{l} to be valid"
      end
    end
  end

  describe "new/1 — validation errors" do
    test "returns error for invalid kind" do
      assert {:error, reason} = Event.new(kind: :invalid_kind, level: :info, message: "test")
      assert reason == :invalid_kind
    end

    test "returns error for nil kind" do
      assert {:error, reason} = Event.new(kind: nil, level: :info, message: "test")
      assert reason == :invalid_kind
    end

    test "returns error for invalid level" do
      assert {:error, reason} = Event.new(kind: :general, level: :critical, message: "test")
      assert reason == :invalid_level
    end

    test "returns error for nil level" do
      assert {:error, reason} = Event.new(kind: :general, level: nil, message: "test")
      assert reason == :invalid_level
    end

    test "returns error for missing message" do
      assert {:error, reason} = Event.new(kind: :general, level: :info)
      assert reason == :missing_message
    end

    test "returns error for missing kind" do
      assert {:error, reason} = Event.new(level: :info, message: "test")
      assert reason == :invalid_kind
    end

    test "does not raise on any invalid input" do
      # Verifies we never raise
      assert {:error, :invalid_kind} = Event.new(%{kind: 123})
      assert {:error, :invalid_kind} = Event.new("not a keyword list")
      assert {:error, :invalid_kind} = Event.new([])
    end
  end
end
