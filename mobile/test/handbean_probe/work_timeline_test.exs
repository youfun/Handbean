defmodule HandbeanProbe.WorkTimelineTest do
  use ExUnit.Case, async: true
  alias HandbeanProbe.WorkTimeline
  alias HandbeanWeb.WorkspaceHelper

  defp tool(id, name, status \\ "done", input \\ %{}) do
    %{
      "id" => id,
      "content_type" => "tool",
      "tool" => name,
      "tool_status" => status,
      "input" => input
    }
  end

  defp assistant(id, phase) do
    %{"id" => id, "content_type" => "assistant_msg", "phase" => phase, "content" => id}
  end

  defp refute_segment_fields(entries) do
    Enum.each(entries, fn entry ->
      refute Map.has_key?(entry, "work_hidden")
      refute Map.has_key?(entry, "work_boundary_summary")
      refute Map.has_key?(entry, "work_segment_id")
      refute Map.has_key?(entry, "work_segment_first")
      refute Map.has_key?(entry, "work_segment_open")
    end)
  end

  test "commentary and the final answer stay visible around one collapsed tool group" do
    entries = [
      assistant("plan", "commentary"),
      tool("read", "read"),
      assistant("answer", "final")
    ]

    [plan, read, answer] = WorkTimeline.project(entries)
    refute Map.has_key?(plan, "work_group_id")
    assert read["work_group_id"] == "read"
    assert read["work_group_first"]
    assert read["work_group_complete"]
    assert read["work_collapsed"]
    assert read["work_summary"] == WorkspaceHelper.tool_work_summary([Enum.at(entries, 1)])
    refute Map.has_key?(answer, "work_group_id")
    refute_segment_fields([plan, read, answer])
    assert WorkTimeline.project(entries) == WorkTimeline.project(WorkTimeline.project(entries))
  end

  test "user messages split tool groups and late results stay on the same entry" do
    user = %{"id" => "u", "content_type" => "user_msg", "interrupts_work" => true}
    entries = [tool("before", "bash", "running"), user, tool("after", "bash", "running")]
    [before, user_entry, after_tool] = WorkTimeline.project(entries)
    assert before["work_group_id"] == "before"
    assert after_tool["work_group_id"] == "after"
    refute before["work_collapsed"]
    refute after_tool["work_collapsed"]
    refute Map.has_key?(user_entry, "work_group_id")
    refute_segment_fields([before, user_entry, after_tool])

    late = List.update_at(entries, 0, &Map.put(&1, "tool_status", "error"))
    [before, _, after_tool] = WorkTimeline.project(late)
    assert before["work_failed"] == 1
    assert before["id"] == "before"
    assert before["work_group_complete"]
    assert before["work_collapsed"]
    assert after_tool["id"] == "after"
    assert after_tool["work_group_id"] == "after"
  end

  test "steer, follow_up, and interrupt users all split groups the same way" do
    users = [
      %{"id" => "u", "content_type" => "user_msg", "delivery" => "steer"},
      %{"id" => "u2", "content_type" => "user_msg", "delivery" => "follow_up"},
      %{"id" => "u3", "content_type" => "user_msg", "interrupts_work" => true}
    ]

    Enum.each(users, fn user ->
      [before, middle, after_tool] =
        WorkTimeline.project([
          tool("before", "bash", "running"),
          user,
          tool("after", "bash", "running")
        ])

      assert before["work_group_id"] == "before"
      assert after_tool["work_group_id"] == "after"
      refute before["work_collapsed"]
      refute after_tool["work_collapsed"]
      refute Map.has_key?(middle, "work_group_id")
      refute_segment_fields([before, middle, after_tool])
    end)
  end

  test "a lone completed tool collapses and the segments argument is ignored" do
    [entry] = WorkTimeline.project([tool("t", "bash")], %{}, %{"t" => false})
    assert entry["work_group_complete"]
    assert entry["work_collapsed"]
    refute Map.has_key?(entry, "work_hidden")
    refute Map.has_key?(entry, "work_boundary_summary")

    [forced_open] = WorkTimeline.project([tool("t", "bash")], %{}, %{"t" => true})
    assert forced_open["work_collapsed"]
  end

  test "consecutive tools stay one group across explore and edit until a non-tool" do
    entries = [
      tool("r", "read", "done", %{"file_path" => "lib/a.ex"}),
      tool("g", "read", "done", %{"file_path" => "sigil/AGENTS.md"}),
      tool("s", "file_search"),
      tool("e", "edit"),
      tool("r2", "read"),
      assistant("explanation", "commentary"),
      tool("r3", "read")
    ]

    result = WorkTimeline.project(entries)
    streak = Enum.take(entries, 5)
    summary = WorkspaceHelper.tool_work_summary(streak)

    assert Enum.map(Enum.take(result, 5), & &1["work_group_id"]) == ["r", "r", "r", "r", "r"]
    assert Enum.map(Enum.take(result, 5), & &1["work_summary"]) == List.duplicate(summary, 5)
    assert summary == "Edited 1 file, Explored 3 files, 1 search"
    assert Enum.at(result, 0)["work_group_first"]
    refute Enum.at(result, 4)["work_group_first"]
    assert Enum.at(result, 0)["work_indent"] == 2
    assert Enum.at(result, 2)["work_indent"] == 2
    assert Enum.at(result, 3)["work_indent"] == 1
    assert Enum.at(result, 3)["work_edit"]
    refute Map.has_key?(Enum.at(result, 5), "work_group_id")
    refute Map.has_key?(Enum.at(result, 5), "work_hidden")
    assert Enum.at(result, 6)["work_group_id"] == "r3"
    assert Enum.at(result, 6)["work_indent"] == 1
    refute Enum.at(result, 6)["work_edit"]
  end

  test "group open preferences and output choices ignore the segments map" do
    running = [tool("t", "bash", "running")]

    [closed] = WorkTimeline.project(running, %{"t" => false}, %{"t" => true}, %{"t" => true})
    assert closed["work_collapsed"]
    refute closed["work_group_complete"]
    assert closed["tool_output_open"]
    refute Map.has_key?(closed, "work_hidden")
    refute Map.has_key?(closed, "work_segment_open")

    [still_closed] =
      WorkTimeline.project(running, %{"t" => false}, %{"t" => false}, %{"t" => true})

    assert still_closed["work_collapsed"]
    assert still_closed["tool_output_open"]

    done = [tool("t", "bash")]
    [open] = WorkTimeline.project(done, %{"t" => true}, %{"t" => false}, %{})
    refute open["work_collapsed"]
    assert open["work_group_complete"]
    refute open["tool_output_open"]
  end

  test "failure and cancellation counts are distinct and edits count diff lines" do
    [first, _, _] =
      WorkTimeline.project([
        tool("a", "bash", "error"),
        tool("b", "bash", "cancelled"),
        tool("c", "bash")
      ])

    assert first["work_summary"] == "Ran 3 commands"
    assert first["work_group_id"] == "a"
    assert first["work_failed"] == 1
    assert first["work_cancelled"] == 1

    edit =
      tool("e", "edit")
      |> Map.put("diff_lines", [
        %{type: :ins, text: "added one"},
        %{"type" => "ins", "text" => "added two"},
        %{"type" => "del", "text" => "removed"}
      ])

    [edit] = WorkTimeline.project([edit])
    assert edit["work_edit"]
    assert edit["work_added"] == 2
    assert edit["work_removed"] == 1
  end

  test "expanded lines carry a verb and nest only inside a mixed group" do
    [read, grep] =
      WorkTimeline.project([
        tool("r", "read", "done", %{"file_path" => "lib/a.ex", "offset" => 1, "limit" => 20}),
        tool("g", "grep", "done", %{"path" => "lib", "pattern" => "def run"})
      ])

    assert read["work_indent"] == 1
    assert read["work_verb"] == "read"
    assert read["work_target"] == "lib/a.ex L1-20"
    assert grep["work_verb"] == "Grep"
    assert grep["work_target"] == "lib \"def run\""

    [nested_read, edit, bash] =
      WorkTimeline.project([
        tool("r2", "read", "done", %{"file_path" => "lib/a.ex"}),
        tool("e", "edit", "done", %{"file_path" => "lib/a.ex"}),
        tool("b", "bash", "done", %{"command" => "mix test"})
      ])

    assert nested_read["work_indent"] == 2
    assert nested_read["work_verb"] == "read"
    assert edit["work_indent"] == 1
    assert edit["work_edit"]
    assert edit["work_verb"] == "edit"
    assert bash["work_indent"] == 1
    assert bash["work_verb"] == "$"
    assert bash["work_target"] == "mix test"
  end
end
