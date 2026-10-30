defmodule HandbeanWeb.ChangeHelperTest do
  @moduledoc """
  Tests for HandbeanWeb.ChangeHelper — pure data transformation helpers
  for change/reversion extracted from HandbeanWeb.WorkspaceLive.
  """

  use ExUnit.Case, async: true

  alias HandbeanWeb.ChangeHelper

  # ── normalize_diff_lines/1 ──

  describe "normalize_diff_lines/1" do
    test "normalizes string-keyed diff lines" do
      lines = [
        %{"type" => "ins", "text" => "added line"},
        %{"type" => "del", "text" => "removed line"}
      ]

      result = ChangeHelper.normalize_diff_lines(lines)

      assert result == [
               %{"type" => "ins", "text" => "added line"},
               %{"type" => "del", "text" => "removed line"}
             ]
    end

    test "normalizes atom-keyed diff lines to string keys" do
      lines = [
        %{type: :ins, text: "added"},
        %{type: :del, text: "removed"}
      ]

      result = ChangeHelper.normalize_diff_lines(lines)

      assert result == [
               %{"type" => "ins", "text" => "added"},
               %{"type" => "del", "text" => "removed"}
             ]
    end

    test "crashes on non-standard map structures (to_string limitation)" do
      # Maps don't implement String.Chars, so to_string raises.
      # This is acceptable because diff_lines always come from tool output
      # and have either string or atom :type/:text keys.
      assert_raise Protocol.UndefinedError, fn ->
        ChangeHelper.normalize_diff_lines([%{foo: "bar"}])
      end
    end

    test "returns nil for non-list input" do
      assert ChangeHelper.normalize_diff_lines(nil) == nil
      assert ChangeHelper.normalize_diff_lines(%{}) == nil
      assert ChangeHelper.normalize_diff_lines("string") == nil
    end

    test "returns empty list for empty list input" do
      assert ChangeHelper.normalize_diff_lines([]) == []
    end

    test "to_string converts types" do
      lines = [%{type: :ins, text: 123}]
      result = ChangeHelper.normalize_diff_lines(lines)
      assert result == [%{"type" => "ins", "text" => "123"}]
    end
  end

  # ── stringify_keys/1 ──

  describe "stringify_keys/1" do
    test "converts atom keys to string keys" do
      map = %{a: 1, b: "hello"}
      result = ChangeHelper.stringify_keys(map)
      assert result == %{"a" => 1, "b" => "hello"}
    end

    test "keeps existing string keys" do
      map = %{"a" => 1, b: 2}
      result = ChangeHelper.stringify_keys(map)
      assert result == %{"a" => 1, "b" => 2}
    end

    test "converts nested maps recursively" do
      map = %{outer: %{inner: "value"}}
      result = ChangeHelper.stringify_keys(map)
      assert result == %{"outer" => %{"inner" => "value"}}
    end

    test "converts lists of maps" do
      map = %{items: [%{name: "one"}, %{name: "two"}]}
      result = ChangeHelper.stringify_keys(map)
      assert result == %{"items" => [%{"name" => "one"}, %{"name" => "two"}]}
    end

    test "returns empty map for non-map input" do
      assert ChangeHelper.stringify_keys(nil) == %{}
      assert ChangeHelper.stringify_keys("string") == %{}
      assert ChangeHelper.stringify_keys([]) == %{}
    end
  end

  # ── stringify_nested/1 ──

  describe "stringify_nested/1" do
    test "converts nested maps" do
      nested = %{a: %{b: %{c: 1}}}
      result = ChangeHelper.stringify_nested(nested)
      assert result == %{"a" => %{"b" => %{"c" => 1}}}
    end

    test "converts lists of maps" do
      list = [%{x: 1}, %{y: 2}]
      result = ChangeHelper.stringify_nested(list)
      assert result == [%{"x" => 1}, %{"y" => 2}]
    end

    test "passes through primitives" do
      assert ChangeHelper.stringify_nested(42) == 42
      assert ChangeHelper.stringify_nested("hello") == "hello"
      assert ChangeHelper.stringify_nested(nil) == nil
      assert ChangeHelper.stringify_nested(:atom) == :atom
    end
  end

  # ── put_if_missing/3 ──

  describe "put_if_missing/3" do
    test "adds key when missing" do
      assert ChangeHelper.put_if_missing(%{}, "key", "value") == %{"key" => "value"}
    end

    test "does not overwrite existing key" do
      assert ChangeHelper.put_if_missing(%{"key" => "original"}, "key", "new") == %{
               "key" => "original"
             }
    end

    test "does nothing when value is nil" do
      assert ChangeHelper.put_if_missing(%{}, "key", nil) == %{}

      assert ChangeHelper.put_if_missing(%{"key" => "existing"}, "key", nil) == %{
               "key" => "existing"
             }
    end

    test "treats empty string as existing value" do
      assert ChangeHelper.put_if_missing(%{"key" => ""}, "key", "new") == %{"key" => ""}
    end

    test "overwrites false (falsy in Elixir)" do
      assert ChangeHelper.put_if_missing(%{"key" => false}, "key", "new") == %{"key" => "new"}
    end
  end

  # ── value/2 ──

  describe "value/2" do
    test "reads string key from map" do
      assert ChangeHelper.value(%{"name" => "test"}, "name") == "test"
    end

    test "falls back to existing atom key when string key missing" do
      map = %{name: "atom_value"}
      assert ChangeHelper.value(map, "name") == "atom_value"
    end

    test "returns nil when key not found" do
      assert ChangeHelper.value(%{}, "missing") == nil
    end

    test "returns nil for non-map input" do
      assert ChangeHelper.value(nil, "key") == nil
      assert ChangeHelper.value("string", "key") == nil
    end

    test "returns nil for non-binary key" do
      assert ChangeHelper.value(%{"key" => "val"}, :key) == nil
    end

    test "string key takes priority over atom key" do
      map = %{"name" => "string_win", name: "atom_lose"}
      assert ChangeHelper.value(map, "name") == "string_win"
    end
  end

  # ── change_from_entry/1 ──

  describe "change_from_entry/1" do
    test "extracts change from string-keyed entry with top-level change" do
      entry = %{
        "id" => "tool-abc",
        "tool_name" => "edit",
        "file_path" => "/tmp/test.ex",
        "change" => %{
          change_id: "ch-001",
          file_path: "/tmp/test.ex",
          diff_lines: [%{"type" => "ins", "text" => "new"}],
          reversible: true,
          revert_status: "available"
        }
      }

      result = ChangeHelper.change_from_entry(entry)
      assert result["change_id"] == "ch-001"
      assert result["change_type"] == "edit"
      assert result["file_path"] == "/tmp/test.ex"
      assert result["reversible"] == true
      assert result["revert_status"] == "available"
    end

    test "marks an unloadable snapshot reference unavailable despite recorded metadata" do
      for entry <- [
            %{
              "change" => %{
                "change_id" => "missing-change",
                "change_snapshot_ref" => "invalid-ref",
                "reversible" => true,
                "revert_status" => "available"
              }
            },
            %{
              "change" => %{change_id: "missing-change"},
              "details" => %{
                change_snapshot_ref: "invalid-ref",
                reversible: true,
                revert_status: "available"
              }
            }
          ] do
        change = ChangeHelper.change_from_entry(entry)

        assert change["change_id"] == "missing-change"
        assert change["reversible"] == false
        assert change["revert_status"] == "unavailable"
        assert change["revert_reason"] == "snapshot_unavailable"
      end
    end

    test "preserves legacy inline snapshots when there is no reference" do
      entry = %{
        "change" => %{
          "change_id" => "legacy-change",
          "before_content" => "before",
          "after_content" => "after",
          "reversible" => true,
          "revert_status" => "available"
        }
      }

      change = ChangeHelper.change_from_entry(entry)

      assert change["before_content"] == "before"
      assert change["after_content"] == "after"
      assert change["reversible"] == true
      assert change["revert_status"] == "available"
    end

    test "reads change from nested details map" do
      entry = %{
        "id" => "tool-xyz",
        "details" => %{
          change: %{change_id: "ch-002", diff_lines: []}
        }
      }

      result = ChangeHelper.change_from_entry(entry)
      assert result["change_id"] == "ch-002"
    end

    test "falls back to entry-level fields when change block missing" do
      entry = %{
        "id" => "tool-def",
        "tool_name" => "write",
        "file_path" => "/tmp/write.ex",
        "change_id" => "ch-003",
        "diff_lines" => [%{"type" => "ins", "text" => "content"}],
        "reversible" => false
      }

      result = ChangeHelper.change_from_entry(entry)
      assert result["change_id"] == "ch-003"
      assert result["change_type"] == "write"
      assert result["file_path"] == "/tmp/write.ex"
      # reversible is false, but false || nil → nil (|  operator treats false as falsy)
      assert result["reversible"] == nil
    end

    test "returns default revert_status when not present" do
      entry = %{"id" => "tool-ghi", "change" => %{}}
      result = ChangeHelper.change_from_entry(entry)
      assert result["revert_status"] == "unavailable"
    end

    test "handles atom-keyed entry" do
      entry = %{
        id: "tool-atom",
        tool_name: "bash",
        change: %{change_id: "ch-atom"}
      }

      result = ChangeHelper.change_from_entry(entry)
      assert result["change_id"] == "ch-atom"
    end

    test "handles entry with no change data gracefully" do
      entry = %{"id" => "msg-123", "content_type" => "user_msg"}
      result = ChangeHelper.change_from_entry(entry)
      assert is_map(result)
      assert result["revert_status"] == "unavailable"
    end

    test "normalizes diff_lines from the entry" do
      entry = %{
        "change" => %{
          "change_id" => "ch-diff",
          "diff_lines" => [%{type: :ins, text: "added"}]
        }
      }

      result = ChangeHelper.change_from_entry(entry)
      assert result["diff_lines"] == [%{"type" => "ins", "text" => "added"}]
    end
  end

  # ── change_from_details/4 ──

  describe "change_from_details/4" do
    test "builds change from tool details" do
      details = %{
        file_path: "/tmp/edit.ex",
        diff_lines: [%{"type" => "ins", "text" => "new line"}],
        change: %{change_id: "ch-detail-001"}
      }

      result =
        ChangeHelper.change_from_details(
          details,
          "/tmp/edit.ex",
          [%{"type" => "ins", "text" => "new line"}],
          "edit"
        )

      assert result["change_id"] == "ch-detail-001"
      assert result["change_type"] == "edit"
      assert result["file_path"] == "/tmp/edit.ex"
      assert is_list(result["diff_lines"])
    end

    test "uses tool_name when details lack change_type" do
      details = %{}
      result = ChangeHelper.change_from_details(details, "/tmp/path.ex", nil, "write")

      assert result["change_type"] == "write"
      assert result["file_path"] == "/tmp/path.ex"
    end

    test "does not override change_type from details (put_if_missing semantics)" do
      details = %{change: %{change_type: "old_tool"}}
      result = ChangeHelper.change_from_details(details, "/tmp/path.ex", nil, "new_tool")

      # put_if_missing won't overwrite an existing change_type from details
      assert result["change_type"] == "old_tool"
    end

    test "does not override file_path from details (put_if_missing semantics)" do
      details = %{file_path: "/old/path.ex"}
      result = ChangeHelper.change_from_details(details, "/new/path.ex", nil, "tool")

      assert result["file_path"] == "/old/path.ex"
    end

    test "normalizes diff_lines from argument" do
      details = %{}
      diff_lines = [%{type: :ins, text: "added"}]

      result = ChangeHelper.change_from_details(details, "/tmp/path.ex", diff_lines, "edit")

      assert result["diff_lines"] == [%{"type" => "ins", "text" => "added"}]
    end
  end

  # ── find_change/2 ──

  describe "find_change/2" do
    test "finds change by change_id in timeline" do
      timeline = [
        %{"id" => "msg-1", "content_type" => "user_msg"},
        %{
          "id" => "tool-1",
          "change" => %{change_id: "ch-target"},
          "tool_name" => "edit"
        },
        %{
          "id" => "tool-2",
          "change" => %{change_id: "ch-other"},
          "tool_name" => "write"
        }
      ]

      result = ChangeHelper.find_change(timeline, "ch-target")
      assert result["change_id"] == "ch-target"
    end

    test "returns nil when change_id not found" do
      timeline = [
        %{"id" => "tool-1", "change" => %{change_id: "ch-1"}}
      ]

      assert ChangeHelper.find_change(timeline, "ch-nonexistent") == nil
    end

    test "returns nil for non-binary change_id" do
      timeline = [%{"change" => %{change_id: "ch-1"}}]
      assert ChangeHelper.find_change(timeline, nil) == nil
    end

    test "returns nil for empty timeline" do
      assert ChangeHelper.find_change([], "ch-1") == nil
    end
  end

  # ── Round-trip / integration tests ──

  describe "integration" do
    test "change_from_entry → find_change round-trip" do
      entry = %{
        "id" => "tool-roundtrip",
        "tool_name" => "edit",
        "file_path" => "/tmp/roundtrip.ex",
        "change" => %{
          change_id: "ch-roundtrip-001",
          diff_lines: [%{"type" => "ins", "text" => "hello"}],
          reversible: true
        }
      }

      change = ChangeHelper.change_from_entry(entry)
      assert change["change_id"] == "ch-roundtrip-001"

      found = ChangeHelper.find_change([entry], "ch-roundtrip-001")
      assert found["change_id"] == "ch-roundtrip-001"
    end

    test "stringify_keys preserves structure through put_if_missing" do
      map = %{a: 1}
      result = map |> ChangeHelper.stringify_keys() |> ChangeHelper.put_if_missing("b", 2)
      assert result == %{"a" => 1, "b" => 2}
    end
  end
end
