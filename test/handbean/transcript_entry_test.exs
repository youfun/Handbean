defmodule Handbean.TranscriptEntryTest do
  use ExUnit.Case, async: true

  alias Handbean.TranscriptEntry

  test "prefers the tool_* names written by TranscriptPersistence" do
    entry = %{
      "tool" => "old",
      "tool_name" => "write",
      "status" => "running",
      "tool_status" => "done",
      "duration_ms" => 1,
      "tool_duration_ms" => 42,
      "error" => nil,
      "tool_error" => "boom",
      "input" => %{"path" => "a.txt"}
    }

    assert TranscriptEntry.tool_name(entry) == "write"
    assert TranscriptEntry.tool_status(entry) == "done"
    assert TranscriptEntry.duration_ms(entry) == 42
    assert TranscriptEntry.error(entry) == "boom"
    assert TranscriptEntry.input(entry) == %{"path" => "a.txt"}
  end

  test "canonical nil fields override stale values on mixed legacy records" do
    entry = %{
      "tool_error" => nil,
      "error" => "stale error",
      "tool_duration_ms" => nil,
      "duration_ms" => 99
    }

    assert TranscriptEntry.error(entry) == nil
    assert TranscriptEntry.duration_ms(entry) == nil
  end

  test "falls back to the legacy bare names for old durable entries" do
    entry = %{"tool" => "bash", "status" => "error", "duration_ms" => 7, "error" => "exit 1"}

    assert TranscriptEntry.tool_name(entry) == "bash"
    assert TranscriptEntry.tool_status(entry) == "error"
    assert TranscriptEntry.duration_ms(entry) == 7
    assert TranscriptEntry.error(entry) == "exit 1"
    assert TranscriptEntry.input(entry) == %{}
    assert TranscriptEntry.input_summary(entry) == nil
  end

  test "handles missing fields and non-map entries without raising" do
    assert TranscriptEntry.tool_name(%{}) == nil
    assert TranscriptEntry.tool_status(nil) == nil
    assert TranscriptEntry.input("not a map") == %{}
    assert TranscriptEntry.input_summary(%{"input_summary" => "ls"}) == "ls"
  end

  test "reads atom-keyed transient projections" do
    entry = %{
      tool_name: "read",
      tool_status: :done,
      tool_duration_ms: 9,
      tool_error: :none,
      tool_input: %{path: "README.md"},
      tool_input_summary: "README.md"
    }

    assert TranscriptEntry.tool_name(entry) == "read"
    assert TranscriptEntry.tool_status(entry) == :done
    assert TranscriptEntry.duration_ms(entry) == 9
    assert TranscriptEntry.error(entry) == :none
    assert TranscriptEntry.input(entry) == %{path: "README.md"}
    assert TranscriptEntry.input_summary(entry) == "README.md"
  end
end
