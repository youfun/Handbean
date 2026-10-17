defmodule HandbeanProbe.NativeChangesTest do
  use ExUnit.Case, async: true

  alias HandbeanProbe.NativeChanges

  test "collapses repeated edits into one net row per path" do
    entries = [
      change_entry("one", "/workspace/lib/example.ex", "old\n", "middle\n", "change-one"),
      change_entry("two", "/workspace/lib/example.ex", "middle\n", "new\n", "change-two")
    ]

    assert [change] = NativeChanges.changes(entries)
    assert change["file_path"] == "/workspace/lib/example.ex"
    assert change["change"]["before_content"] == "old\n"
    assert change["change"]["after_content"] == "new\n"
    assert String.starts_with?(change["change"]["change_id"], "net-")

    assert Enum.any?(change["diff_lines"], fn line ->
             line["type"] in [:del, "del"] and line["text"] == "old"
           end)

    assert Enum.any?(change["diff_lines"], fn line ->
             line["type"] in [:ins, "ins"] and line["text"] == "new"
           end)
  end

  test "drops a file when the session net result returns to its baseline" do
    entries = [
      change_entry("one", "/workspace/lib/example.ex", "old\n", "middle\n", "change-one"),
      change_entry("two", "/workspace/lib/example.ex", "middle\n", "old\n", "change-two")
    ]

    assert NativeChanges.changes(entries) == []
  end

  test "tracks row expansion, inline confirmation and revert feedback" do
    state = %{changes_ui: nil}

    state = NativeChanges.toggle(state, "change-one")
    assert MapSet.member?(state.changes_ui.expanded, "change-one")

    state = NativeChanges.confirm(state, "change-one")
    assert state.changes_ui.confirming == "change-one"

    state = NativeChanges.mark_reverting(state, "change-one")
    assert state.changes_ui.confirming == nil
    assert state.changes_ui.status_overrides["change-one"] == "reverting"

    state = NativeChanges.apply_revert_result(state, "change-one", {:ok, :restored})
    assert state.changes_ui.status_overrides["change-one"] == "reverted"
    assert state.changes_ui.feedback.kind == :success
  end

  defp change_entry(id, path, before, after_content, change_id) do
    %{
      "id" => id,
      "tool_name" => "edit",
      "tool_status" => "done",
      "file_path" => path,
      "diff_lines" => Handbean.ChangeSnapshot.diff_lines(before, after_content),
      "change" => %{
        "change_id" => change_id,
        "change_type" => "edit",
        "file_path" => path,
        "before_content" => before,
        "after_content" => after_content,
        "existed_before" => true,
        "before_sha256" => Handbean.ChangeSnapshot.sha256(before),
        "after_sha256" => Handbean.ChangeSnapshot.sha256(after_content),
        "reversible" => true,
        "revert_status" => "available"
      }
    }
  end
end
