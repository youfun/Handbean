defmodule HandbeanWeb.FileChangeCardTest do
  use ExUnit.Case, async: true

  require Phoenix.LiveViewTest

  alias Handbean.ChangeSnapshot
  alias HandbeanWeb.FileChangeCard

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "handbean_net_change_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  test "edit and write card labels stay untranslated in Chinese and English" do
    for locale <- ["zh_CN", "en"] do
      Gettext.with_locale(Handbean.Gettext, locale, fn ->
        for {tool, label} <- [{"edit", "edit"}, {"write", "Created"}] do
          html =
            Phoenix.LiveViewTest.render_component(&FileChangeCard.card/1,
              entry: %{"id" => "e1", "tool_name" => tool, "file_path" => "lib/app.ex"}
            )

          assert html =~ label
        end
      end)
    end
  end

  describe "relative_display_path/2" do
    test "absolute paths inside the workspace keep their directory" do
      root = "/tmp/handbean"
      path = Path.join(root, "assets/css/workspace.css")

      assert FileChangeCard.relative_display_path(path, root) == "assets/css/workspace.css"
    end

    test "already relative paths are not reduced to the basename" do
      assert FileChangeCard.relative_display_path("assets/css/app.css", "/tmp/handbean") ==
               "assets/css/app.css"
    end

    test "paths outside the workspace stay identifiable" do
      path = "/other/project/lib/app.ex"

      assert FileChangeCard.relative_display_path(path, "/tmp/handbean") == path
    end
  end

  describe "changes/1 session net diff" do
    test "restored bounded tool details load the persisted snapshots and render the net diff" do
      path = "CHANGELOG.md"
      conversation_id = "net-preview-#{System.unique_integer([:positive])}"

      entries =
        Enum.map(
          [
            {"restored-1", "before\n", "before\nadded\n"},
            {"restored-2", "before\nadded\n", "before\nlatest\n"}
          ],
          fn {id, before, after_content} ->
            snapshot = ChangeSnapshot.build_edit_snapshot(path, before, after_content)
            details = ChangeSnapshot.result_details(snapshot, %{conversation_id: conversation_id})

            %{
              "id" => id,
              "tool_name" => "edit",
              "tool_status" => "done",
              "file_path" => path,
              "details" => details,
              "change" => %{"diff_lines" => nil}
            }
          end
        )

      assert [row] = FileChangeCard.changes(entries)
      assert row["change_type"] == "edit"
      assert change(row, "before_content") == "before\n"
      assert change(row, "after_content") == "before\nlatest\n"

      html =
        Phoenix.LiveViewTest.render_component(&FileChangeCard.card/1, entry: row, open?: true)

      assert html =~ "latest"
      assert html =~ "diff-ins"
      assert html =~ "+1"
      assert html =~ ~s(phx-hook="CopyText")
      assert html =~ ~s(data-copy="CHANGELOG.md")
      assert html =~ "Copy relative path"
    end

    test "two successful writes of one path are one row from first baseline to latest" do
      path = "lib/notes.ex"

      changes =
        FileChangeCard.changes([
          write_entry("w1", path, "one\n", "one\ntwo\n"),
          write_entry("w2", path, "one\ntwo\n", "one\ntwo\nthree\n")
        ])

      assert [entry] = changes
      assert entry["file_path"] == path
      assert change(entry, "before_content") == "one\n"
      assert change(entry, "after_content") == "one\ntwo\nthree\n"
      assert change(entry, "existed_before") == true
      assert entry["change_type"] == "edit"
      assert added(entry) == 2
      assert removed(entry) == 0
    end

    test "add then update of one path is one created row of the final content" do
      path = "lib/new.ex"

      changes =
        FileChangeCard.changes([
          write_entry("w1", path, nil, "first\n"),
          edit_entry("e1", path, "first\n", "first\nsecond\n")
        ])

      assert [entry] = changes
      assert entry["file_path"] == path
      assert change(entry, "existed_before") == false
      assert change(entry, "before_content") == nil
      assert change(entry, "after_content") == "first\nsecond\n"
      assert entry["change_type"] == "write"
      assert added(entry) == 2
      assert removed(entry) == 0
    end

    test "a path returns to its baseline and disappears without summed line counts" do
      path = "lib/notes.ex"

      changes =
        FileChangeCard.changes([
          edit_entry("e1", path, "keep\n", "keep\nadded\n"),
          edit_entry("e2", path, "keep\nadded\n", "keep\n")
        ])

      assert changes == []
    end

    test "a failed write does not set baseline or current content" do
      path = "lib/notes.ex"

      changes =
        FileChangeCard.changes([
          failed_write_entry("w-fail", path, "one\n", "one\nbad\n"),
          write_entry("w1", path, "one\n", "one\nok\n")
        ])

      assert [entry] = changes
      assert change(entry, "before_content") == "one\n"
      assert change(entry, "after_content") == "one\nok\n"
    end

    test "untouched files and unrecorded bash claims are absent" do
      changes =
        FileChangeCard.changes([
          %{
            "id" => "bash-1",
            "content_type" => "tool",
            "tool_name" => "bash",
            "tool_status" => "done",
            "file_path" => "lib/dirty.ex",
            "change" => %{
              "file_path" => "lib/dirty.ex",
              "diff_lines" => [%{"type" => "ins", "text" => "x"}]
            }
          },
          %{"id" => "msg-1", "content_type" => "text", "content" => "untouched"}
        ])

      assert changes == []
    end

    test "recorded multi-file command effects are current-conversation changes" do
      conversation_id = "bash-changes-#{System.unique_integer([:positive])}"

      changes =
        [
          ChangeSnapshot.build_write_snapshot("lib/created.ex", nil, "created\n"),
          ChangeSnapshot.build_edit_snapshot("lib/updated.ex", "before\n", "after\n")
        ]
        |> Enum.map(&ChangeSnapshot.result_details(&1, %{conversation_id: conversation_id}))

      rows =
        FileChangeCard.changes([
          %{
            "id" => "bash-1",
            "content_type" => "tool",
            "tool_name" => "bash",
            "tool_status" => "done",
            "details" => %{"changes" => changes}
          }
        ])

      assert Enum.map(rows, & &1["file_path"]) == ["lib/created.ex", "lib/updated.ex"]
      assert Enum.map(rows, & &1["change_type"]) == ["write", "edit"]
      assert Enum.map(rows, &change(&1, "before_content")) == [nil, "before\n"]
      assert Enum.map(rows, &change(&1, "after_content")) == ["created\n", "after\n"]
    end

    test "replayed job effects are deduplicated by stable change id" do
      snapshot =
        ChangeSnapshot.build_write_snapshot("lib/created.ex", nil, "created\n",
          change_id: "stable-change"
        )

      effect = ChangeSnapshot.result_details(snapshot, %{conversation_id: "dedupe-test"})

      entries =
        for id <- ["bash-result", "later-job-poll"] do
          %{
            "id" => id,
            "content_type" => "tool",
            "tool_name" => "job_status",
            "tool_status" => "done",
            "details" => %{"changes" => [effect]}
          }
        end

      assert [row] = FileChangeCard.changes(entries)
      assert change(row, "after_content") == "created\n"
    end

    test "an intervening external write resets the conversation net baseline" do
      path = "lib/shared.ex"

      [row] =
        FileChangeCard.changes([
          edit_entry("first", path, "a\n", "b\n"),
          edit_entry("second", path, "c\n", "d\n")
        ])

      assert change(row, "before_content") == "c\n"
      assert change(row, "after_content") == "d\n"
    end

    test "later effects with a reused legacy change id are not discarded" do
      path = "lib/transient.ex"

      created =
        ChangeSnapshot.build_write_snapshot(path, nil, "temporary\n", change_id: "legacy-id")

      deleted =
        ChangeSnapshot.build_delete_snapshot(path, "temporary\n", change_id: "legacy-id")

      entries =
        Enum.with_index([created, deleted], fn effect, index ->
          %{
            "id" => "batch-#{index}",
            "sequence" => index,
            "content_type" => "file_change_batch",
            "details" => %{"changes" => [effect]}
          }
        end)

      assert FileChangeCard.changes(entries) == []
    end

    test "a file created and later deleted in the conversation disappears" do
      path = "lib/transient.ex"

      changes =
        FileChangeCard.changes([
          write_entry("create", path, nil, "temporary\n"),
          delete_entry("delete", path, "temporary\n")
        ])

      assert changes == []
    end

    test "a git HEAD dirty baseline is not used when the session has not written the file" do
      changes =
        FileChangeCard.changes([
          %{
            "id" => "git-1",
            "content_type" => "git_status",
            "file_path" => "lib/dirty.ex",
            "change" => %{
              "file_path" => "lib/dirty.ex",
              "before_content" => "HEAD\n",
              "after_content" => "worktree\n",
              "diff_lines" => [%{"type" => "ins", "text" => "worktree"}]
            }
          }
        ])

      assert changes == []
    end

    test "revert target is the session baseline, deleting a file created in the session" do
      path = "lib/new.ex"

      [created] =
        FileChangeCard.changes([
          write_entry("w1", path, nil, "first\n"),
          edit_entry("e1", path, "first\n", "first\nsecond\n")
        ])

      assert change(created, "existed_before") == false
      assert change(created, "before_content") == nil
      assert change(created, "after_content") == "first\nsecond\n"
      assert change(created, "after_sha256") == ChangeSnapshot.sha256("first\nsecond\n")
    end

    test "revert uses the net row, restoring the first baseline and deleting a created file", %{
      tmp: tmp
    } do
      path = Path.join(tmp, "notes.ex")
      File.write!(path, "one\nlatest\n")

      [row] =
        FileChangeCard.changes([
          edit_entry("e1", path, "one\n", "one\ntwo\n"),
          edit_entry("e2", path, "one\ntwo\n", "one\nlatest\n")
        ])

      assert {:ok, result} =
               Handbean.ChangeReverter.revert(
                 HandbeanWeb.ChangeHelper.change_from_entry(row),
                 tmp
               )

      assert result["revert_status"] == "reverted"
      assert File.read!(path) == "one\n"
    end

    test "revert of a created path deletes the file when current content matches the net after state",
         %{tmp: tmp} do
      path = Path.join(tmp, "new.ex")
      File.write!(path, "first\nsecond\n")

      [row] =
        FileChangeCard.changes([
          write_entry("w1", path, nil, "first\n"),
          edit_entry("e1", path, "first\n", "first\nsecond\n")
        ])

      assert {:ok, _} =
               Handbean.ChangeReverter.revert(
                 HandbeanWeb.ChangeHelper.change_from_entry(row),
                 tmp
               )

      refute File.exists?(path)
    end

    test "revert refuses when current content does not match the latest successful write", %{
      tmp: tmp
    } do
      path = Path.join(tmp, "notes.ex")
      File.write!(path, "user edit\n")

      [row] =
        FileChangeCard.changes([
          edit_entry("e1", path, "one\n", "one\ntwo\n")
        ])

      assert {:conflict, result} =
               Handbean.ChangeReverter.revert(
                 HandbeanWeb.ChangeHelper.change_from_entry(row),
                 tmp
               )

      assert result["revert_status"] == "conflict"
      assert File.read!(path) == "user edit\n"
    end

    test "the changes lookup finds the net row, not an intermediate call" do
      path = "lib/notes.ex"

      timeline = [
        edit_entry("e1", path, "one\n", "one\ntwo\n"),
        edit_entry("e2", path, "one\ntwo\n", "one\nlatest\n")
      ]

      [row] = FileChangeCard.changes(timeline)

      found = HandbeanWeb.ChangeHelper.find_change(timeline, change(row, "change_id"))

      assert change(row, "change_id") == "net-lib-notes.ex"
      assert found["before_content"] == "one\n"
      assert found["after_content"] == "one\nlatest\n"
      refute found["change_id"] in ["e1", "e2"]
    end

    test "chat timeline stays one entry per call when changes collapse to one path" do
      timeline = [
        write_entry("w1", "lib/new.ex", nil, "first\n"),
        edit_entry("e1", "lib/new.ex", "first\n", "first\nsecond\n")
      ]

      assert Enum.map(timeline, & &1["id"]) == ["w1", "e1"]
      assert [collapsed] = FileChangeCard.changes(timeline)
      refute collapsed["id"] in ["w1", "e1"] or timeline == [collapsed]
    end
  end

  defp write_entry(id, path, before_content, after_content) do
    change =
      ChangeSnapshot.build_write_snapshot(path, before_content, after_content, change_id: id)

    %{
      "id" => id,
      "content_type" => "tool",
      "tool_name" => "write",
      "tool_status" => "done",
      "file_path" => path,
      "change" => change,
      "diff_lines" => change.diff_lines
    }
  end

  defp edit_entry(id, path, before_content, after_content) do
    change =
      ChangeSnapshot.build_edit_snapshot(path, before_content, after_content, nil, change_id: id)

    %{
      "id" => id,
      "content_type" => "tool",
      "tool_name" => "edit",
      "tool_status" => "done",
      "file_path" => path,
      "change" => change,
      "diff_lines" => change.diff_lines
    }
  end

  defp delete_entry(id, path, before_content) do
    change = ChangeSnapshot.build_delete_snapshot(path, before_content, change_id: id)

    %{
      "id" => id,
      "content_type" => "tool",
      "tool_name" => "delete",
      "tool_status" => "done",
      "file_path" => path,
      "change" => change,
      "diff_lines" => change.diff_lines
    }
  end

  defp failed_write_entry(id, path, before_content, after_content) do
    %{
      "id" => id,
      "content_type" => "tool",
      "tool_name" => "write",
      "tool_status" => "error",
      "file_path" => path,
      "change" => %{
        "change_id" => id,
        "change_type" => "write",
        "file_path" => path,
        "existed_before" => true,
        "before_content" => before_content,
        "after_content" => after_content,
        "diff_lines" => [%{"type" => "ins", "text" => "bad"}],
        "reversible" => false
      }
    }
  end

  defp change(entry, key) do
    entry |> Map.get("change", %{}) |> Map.get(key)
  end

  defp added(entry) do
    entry
    |> Map.get("diff_lines", [])
    |> Enum.count(&(&1["type"] == "ins"))
  end

  defp removed(entry) do
    entry
    |> Map.get("diff_lines", [])
    |> Enum.count(&(&1["type"] == "del"))
  end
end
