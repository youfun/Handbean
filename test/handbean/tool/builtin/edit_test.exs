defmodule Handbean.Tool.Builtin.EditTest do
  @moduledoc """
  Tests for the edit builtin tool.

  Reference: `gong/tools/edit.ex` (Gong Edit tool — fuzzy match + BOM + CRLF + Diff)
  Test pattern: hand-written from Gong Edit source behavior

  Covers:
    - Exact match replacement
    - Multiple ordered replacements in one call
    - No match error
    - Duplicate match error (without replace_all)
    - Replace all occurrences
    - Empty old_string validation
    - Identical old/new validation
    - File not found error
    - BOM detection and preservation
    - CRLF line ending handling
    - LF line ending preservation
    - Fuzzy matching via normalization
    - Large file rejection
    - Permission denied (read-only)
    - Binary file protection
    - Diff first changed line number
    - Huge file performance (@tag :slow)
  """

  use Handbean.DataCase, async: false

  alias Handbean.Tool.Builtin.Edit

  @work_dir Path.join(System.tmp_dir!(), "sigil_edit_test_#{System.unique_integer([:positive])}")

  setup do
    File.mkdir_p!(@work_dir)
    on_exit(fn -> File.rm_rf!(@work_dir) end)
  end

  describe "exact match replacement" do
    test "replaces a unique string" do
      path = Path.join(@work_dir, "exact.txt")
      File.write!(path, "hello world\n")

      {:ok, output, data} =
        Edit.execute(
          %{"file_path" => path, "old_string" => "hello", "new_string" => "goodbye"},
          %{working_directory: @work_dir}
        )

      assert output =~ "replacement"
      assert data.replacements == 1
      assert File.read!(path) == "goodbye world\n"
    end

    @tag :bdd
    test "[BDD-EDIT-006] exact match prioritized over fuzzy" do
      path = Path.join(@work_dir, "exact_006.txt")
      File.write!(path, "hello world")

      {:ok, _output, data} =
        Edit.execute(
          %{"file_path" => path, "old_string" => "hello world", "new_string" => "goodbye"},
          %{working_directory: @work_dir}
        )

      assert data.replacements == 1
      assert File.read!(path) == "goodbye"
    end

    test "applies multiple ordered replacements in one call" do
      path = Path.join(@work_dir, "multi.txt")
      File.write!(path, "one\ntwo\nthree\n")

      {:ok, output, data} =
        Edit.execute(
          %{
            "file_path" => path,
            "edits" => [
              %{"old_string" => "one", "new_string" => "ONE"},
              %{"old_string" => "three", "new_string" => "THREE"}
            ]
          },
          %{working_directory: @work_dir}
        )

      assert output =~ "2 replacement"
      assert data.replacements == 2
      assert data.edit_count == 2
      assert File.read!(path) == "ONE\ntwo\nTHREE\n"
    end

    test "applies replacements sequentially so later edits can target earlier output" do
      path = Path.join(@work_dir, "ordered.txt")
      File.write!(path, "value = 1\n")

      {:ok, _output, data} =
        Edit.execute(
          %{
            "file_path" => path,
            "edits" => [
              %{"old_string" => "value = 1", "new_string" => "value = 2"},
              %{"old_string" => "value = 2", "new_string" => "value = 3"}
            ]
          },
          %{working_directory: @work_dir}
        )

      assert data.replacements == 2
      assert File.read!(path) == "value = 3\n"
    end

    test "accepts replacements alias and oldText/newText item keys" do
      path = Path.join(@work_dir, "aliases.txt")
      File.write!(path, "alpha\nbeta\n")

      {:ok, _output, data} =
        Edit.execute(
          %{
            "file_path" => path,
            "replacements" => [
              %{"oldText" => "alpha", "newText" => "ALPHA"},
              %{"oldText" => "beta", "newText" => "BETA"}
            ]
          },
          %{working_directory: @work_dir}
        )

      assert data.replacements == 2
      assert File.read!(path) == "ALPHA\nBETA\n"
    end

    test "reports the failing replacement index for multi edits" do
      path = Path.join(@work_dir, "multi_error.txt")
      File.write!(path, "one\ntwo\n")

      {:error, reason} =
        Edit.execute(
          %{
            "file_path" => path,
            "edits" => [
              %{"old_string" => "one", "new_string" => "ONE"},
              %{"old_string" => "missing", "new_string" => "MISSING"}
            ]
          },
          %{working_directory: @work_dir}
        )

      assert reason =~ "edit #2"
      assert reason =~ "Re-read the file"
      assert File.read!(path) == "one\ntwo\n"
    end

    test "produces a diff in the output and structured details" do
      path = Path.join(@work_dir, "diff.txt")
      File.write!(path, "AAA\nBBB\n")

      {:ok, output, data} =
        Edit.execute(
          %{"file_path" => path, "old_string" => "AAA", "new_string" => "ZZZ"},
          %{working_directory: @work_dir, conversation_id: "edit-test"}
        )

      assert output =~ "- AAA"
      assert output =~ "+ ZZZ"

      # Small diff (≤ 6 eq lines) — no skip, all lines preserved
      assert data.diff_lines == [
               %{"type" => "del", "text" => "AAA"},
               %{"type" => "ins", "text" => "ZZZ"},
               %{"type" => "eq", "text" => "BBB"},
               %{"type" => "eq", "text" => ""}
             ]

      assert data.change_id
      assert data.reversible == true
      assert data.revert_status == "available"
      refute Map.has_key?(data, :before_content)
      refute Map.has_key?(data, :after_content)
      refute Map.has_key?(data, :change)
      assert {:ok, snapshot} = Handbean.ChangeSnapshot.load(data.change_snapshot_ref)
      assert snapshot["before_content"] == "AAA\nBBB\n"
      assert snapshot["after_content"] == "ZZZ\nBBB\n"
      assert snapshot["diff_lines"] == data.diff_lines
    end

    test "diff_lines preserves raw HTML text (HEEx will escape later)" do
      path = Path.join(@work_dir, "xss_diff.txt")
      File.write!(path, "<script>alert(1)</script>\n")

      {:ok, _output, data} =
        Edit.execute(
          %{
            "file_path" => path,
            "old_string" => "<script>alert(1)</script>",
            "new_string" => "safe"
          },
          %{working_directory: @work_dir}
        )

      assert data.replacements == 1

      # The data layer keeps raw text — no HTML escaping at this level.
      # HEEx is responsible for escaping in the template.
      assert Enum.any?(data.diff_lines, fn
               %{"text" => "<script>alert(1)</script>"} -> true
               _ -> false
             end)
    end

    test "diff_lines clips large unchanged blocks with skip lines" do
      path = Path.join(@work_dir, "big_diff.txt")

      # 20 lines, change only line 10
      lines = Enum.map_join(1..20, "\n", fn n -> "line #{n}" end)
      File.write!(path, lines)

      {:ok, _output, data} =
        Edit.execute(
          %{
            "file_path" => path,
            "old_string" => "line 10",
            "new_string" => "LINE TEN"
          },
          %{working_directory: @work_dir}
        )

      assert data.replacements == 1

      diff_lines = data.diff_lines

      # Should NOT contain all 20 unchanged lines
      assert is_list(diff_lines)
      assert length(diff_lines) < 20

      # Should contain at least one skip line
      assert Enum.any?(diff_lines, &(&1["type"] == "skip"))

      # Should contain the change lines
      assert Enum.any?(diff_lines, &(&1["type"] == "del"))
      assert Enum.any?(diff_lines, &(&1["type"] == "ins"))

      # Should have context near the change
      assert Enum.any?(diff_lines, &(&1["type"] == "eq"))
    end

    @tag :bdd
    test "[BDD-EDIT-022] diff output includes changed line number" do
      path = Path.join(@work_dir, "big_022.txt")
      # 100 lines, unique prefix per line so exact match finds only line 50
      lines =
        Enum.map_join(1..100, "\n", fn n ->
          "#{String.pad_leading("#{n}", 3, "0")}: content line here"
        end)

      File.write!(path, lines)

      {:ok, _output, data} =
        Edit.execute(
          %{
            "file_path" => path,
            "old_string" => "050: content line here",
            "new_string" => "050: REPLACED"
          },
          %{working_directory: @work_dir}
        )

      assert data.replacements == 1
      assert data.diff_first_changed_line == 50
    end
  end

  describe "validation" do
    test "rejects empty old_string" do
      path = Path.join(@work_dir, "empty.txt")
      File.write!(path, "content")

      {:error, reason} =
        Edit.execute(
          %{"file_path" => path, "old_string" => "", "new_string" => "new"},
          %{working_directory: @work_dir}
        )

      assert reason =~ "cannot be empty"
    end

    test "rejects identical old and new strings" do
      path = Path.join(@work_dir, "same.txt")
      File.write!(path, "content")

      {:error, reason} =
        Edit.execute(
          %{"file_path" => path, "old_string" => "content", "new_string" => "content"},
          %{working_directory: @work_dir}
        )

      assert reason =~ "identical"
    end

    test "rejects non-existent file" do
      {:error, reason} =
        Edit.execute(
          %{
            "file_path" => Path.join(@work_dir, "nope.txt"),
            "old_string" => "x",
            "new_string" => "y"
          },
          %{working_directory: @work_dir}
        )

      assert reason =~ "File not found"
    end
  end

  describe "duplicate and replace_all" do
    test "reports error when multiple exact matches found" do
      path = Path.join(@work_dir, "dup.txt")
      File.write!(path, "foo is foo\n")

      {:error, reason} =
        Edit.execute(
          %{
            "file_path" => path,
            "old_string" => "foo",
            "new_string" => "bar",
            "replace_all" => false
          },
          %{working_directory: @work_dir}
        )

      assert reason =~ "Found"
      assert reason =~ "occurrences"
    end

    test "replace_all replaces all occurrences" do
      path = Path.join(@work_dir, "all.txt")
      File.write!(path, "foo is foo\n")

      {:ok, _output, data} =
        Edit.execute(
          %{
            "file_path" => path,
            "old_string" => "foo",
            "new_string" => "bar",
            "replace_all" => true
          },
          %{working_directory: @work_dir}
        )

      assert data.replacements == 2
      assert File.read!(path) == "bar is bar\n"
    end
  end

  describe "BOM handling" do
    test "preserves BOM after editing a BOM file" do
      path = Path.join(@work_dir, "bom.txt")
      bom = <<0xEF, 0xBB, 0xBF>>
      File.write!(path, bom <> "Hello World\n")

      {:ok, _output, _data} =
        Edit.execute(
          %{"file_path" => path, "old_string" => "Hello", "new_string" => "Goodbye"},
          %{working_directory: @work_dir}
        )

      content = File.read!(path)
      assert String.starts_with?(content, bom)
      assert content =~ "Goodbye World"
    end
  end

  describe "CRLF handling" do
    test "handles files with CRLF line endings" do
      path = Path.join(@work_dir, "crlf.txt")
      # Write explicit CRLF
      File.write!(path, "line1\r\nline2\r\nline3\r\n")

      {:ok, _output, _data} =
        Edit.execute(
          %{"file_path" => path, "old_string" => "line2", "new_string" => "modified"},
          %{working_directory: @work_dir}
        )

      content = File.read!(path)
      assert content =~ "line1\r\n"
      assert content =~ "modified\r\n"
      assert content =~ "line3\r\n"
    end

    test "handles old_string with CRLF line endings sent by provider" do
      path = Path.join(@work_dir, "crlf2.txt")
      File.write!(path, "line1\r\nline2\r\nline3\r\n")

      {:ok, _output, _data} =
        Edit.execute(
          %{
            "file_path" => path,
            "old_string" => "line1\r\nline2",
            "new_string" => "start\r\nmiddle"
          },
          %{working_directory: @work_dir}
        )

      content = File.read!(path)
      assert content =~ "start\r\nmiddle"
    end

    @tag :bdd
    test "[BDD-EDIT-019] LF line endings preserved after edit" do
      path = Path.join(@work_dir, "lf_019.txt")
      File.write!(path, "aaa\nbbb\nccc\n")

      {:ok, _output, _data} =
        Edit.execute(
          %{"file_path" => path, "old_string" => "bbb", "new_string" => "xxx"},
          %{working_directory: @work_dir}
        )

      content = File.read!(path)
      assert content == "aaa\nxxx\nccc\n"
      refute String.contains?(content, "\r\n")
    end
  end

  describe "fuzzy matching" do
    test "finds match via trailing whitespace normalization" do
      path = Path.join(@work_dir, "fuzzy.txt")
      # File has trailing spaces — normalize strips them for matching,
      # but the original trailing spaces are preserved in the file.
      File.write!(path, "hello world   \n")

      # old_string has no trailing spaces
      {:ok, _output, data} =
        Edit.execute(
          %{"file_path" => path, "old_string" => "hello world", "new_string" => "hi there"},
          %{working_directory: @work_dir}
        )

      assert data.replacements == 1
      # Trailing spaces from original file are preserved after replacement
      assert File.read!(path) == "hi there   \n"
    end
  end

  describe "security — workspace boundary" do
    test "rejects editing files outside the workspace" do
      {:error, reason} =
        Edit.execute(
          %{"file_path" => "/etc/passwd", "old_string" => "x", "new_string" => "y"},
          %{working_directory: @work_dir}
        )

      assert reason =~ "Path traversal" or reason =~ "outside workspace"
    end

    test "rejects relative path traversal for edit" do
      {:error, reason} =
        Edit.execute(
          %{"file_path" => "../../etc/hosts", "old_string" => "x", "new_string" => "y"},
          %{working_directory: @work_dir}
        )

      assert reason =~ "Path traversal" or reason =~ "outside workspace"
    end

    test "yolo edits a file outside the workspace" do
      outside =
        Path.join(
          System.tmp_dir!(),
          "handbean-yolo-edit-#{System.unique_integer([:positive])}.txt"
        )

      File.write!(outside, "before")
      on_exit(fn -> File.rm(outside) end)

      assert {:ok, _output, %{file_path: ^outside}} =
               Edit.execute(
                 %{"file_path" => outside, "old_string" => "before", "new_string" => "after"},
                 %{
                   working_directory: @work_dir,
                   approval_mode: :yolo,
                   conversation_id: "edit-yolo-test"
                 }
               )

      assert File.read!(outside) == "after"
    end
  end

  describe "permission handling" do
    @tag :bdd
    test "[BDD-EDIT-012] permission denied on read-only file" do
      path = Path.join(@work_dir, "locked_012.txt")
      File.write!(path, "secret")
      File.chmod!(path, 0o444)

      {:error, reason} =
        Edit.execute(
          %{"file_path" => path, "old_string" => "secret", "new_string" => "open"},
          %{working_directory: @work_dir}
        )

      assert reason =~ "Read-only"
    end
  end

  describe "binary file protection" do
    @tag :bdd
    test "[BDD-EDIT-025] binary file rejected" do
      path = Path.join(@work_dir, "image_025.png")
      # Write a minimal PNG-like binary with null bytes
      File.write!(path, <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82>>)

      {:error, reason} =
        Edit.execute(
          %{"file_path" => path, "old_string" => "PNG", "new_string" => "JPG"},
          %{working_directory: @work_dir}
        )

      assert reason =~ "Binary file"
    end
  end

  describe "performance" do
    @tag :slow
    @tag :bdd
    test "[BDD-EDIT-023] huge file performance" do
      path = Path.join(@work_dir, "big_023.txt")
      # 50_000 lines, 80 chars each
      line_template = String.duplicate("x", 78)

      lines =
        Enum.map_join(1..50_000, "\n", fn n ->
          "#{String.pad_leading("#{n}", 5, "0")}: #{line_template}"
        end)

      File.write!(path, lines)

      {:ok, _output, data} =
        Edit.execute(
          %{
            "file_path" => path,
            "old_string" => "25000: #{line_template}",
            "new_string" => "25000: REPLACED"
          },
          %{working_directory: @work_dir}
        )

      assert data.replacements == 1
    end
  end

  describe "diff mode" do
    test "applies diff to add a line" do
      path = Path.join(@work_dir, "diff_add.txt")
      File.write!(path, "line1\nline3\n")

      diff = """
      --- a/diff_add.txt
      +++ b/diff_add.txt
      @@ -1,2 +1,3 @@
       line1
      +line2
       line3
      """

      {:ok, output, data} =
        Edit.execute(
          %{"file_path" => path, "mode" => "diff", "diff" => diff},
          %{working_directory: @work_dir, conversation_id: "edit-test"}
        )

      assert output =~ "diff mode"
      assert data.mode == "diff"
      assert data.replacements >= 1
      assert data.change_id
      assert data.reversible == true
      assert data.revert_status == "available"
      assert File.read!(path) == "line1\nline2\nline3\n"
    end

    test "applies diff to delete a line" do
      path = Path.join(@work_dir, "diff_del.txt")
      File.write!(path, "line1\nline2\nline3\n")

      diff = """
      --- a/diff_del.txt
      +++ b/diff_del.txt
      @@ -1,3 +1,2 @@
       line1
      -line2
       line3
      """

      {:ok, output, data} =
        Edit.execute(
          %{"file_path" => path, "mode" => "diff", "diff" => diff},
          %{working_directory: @work_dir, conversation_id: "edit-test"}
        )

      assert output =~ "diff mode"
      assert data.mode == "diff"
      assert data.replacements >= 1
      assert File.read!(path) == "line1\nline3\n"
    end

    test "applies diff to modify a line" do
      path = Path.join(@work_dir, "diff_mod.txt")
      File.write!(path, "hello world\n")

      diff = """
      --- a/diff_mod.txt
      +++ b/diff_mod.txt
      @@ -1 +1 @@
      -hello world
      +goodbye world
      """

      {:ok, output, data} =
        Edit.execute(
          %{"file_path" => path, "mode" => "diff", "diff" => diff},
          %{working_directory: @work_dir}
        )

      assert output =~ "diff mode"
      assert data.mode == "diff"
      assert data.replacements >= 1
      assert File.read!(path) == "goodbye world\n"
    end

    test "applies diff with multiple hunks" do
      path = Path.join(@work_dir, "diff_multi.txt")
      File.write!(path, "aaa\nbbb\nccc\nddd\neee\n")

      diff = """
      --- a/diff_multi.txt
      +++ b/diff_multi.txt
      @@ -1,3 +1,4 @@
       aaa
      +xxx
       bbb
       ccc
      @@ -4,2 +5,2 @@
       ddd
      -eee
      +yyy
      """

      {:ok, output, data} =
        Edit.execute(
          %{"file_path" => path, "mode" => "diff", "diff" => diff},
          %{working_directory: @work_dir}
        )

      assert output =~ "diff mode"
      assert data.mode == "diff"
      # 2 hunks: 1 add + 1 delete+add = at least 3 changes
      assert data.replacements >= 3
      assert File.read!(path) == "aaa\nxxx\nbbb\nccc\nddd\nyyy\n"
    end

    test "rejects empty diff" do
      path = Path.join(@work_dir, "diff_empty_err.txt")
      File.write!(path, "content\n")

      {:error, reason} =
        Edit.execute(
          %{"file_path" => path, "mode" => "diff", "diff" => ""},
          %{working_directory: @work_dir}
        )

      assert reason =~ "cannot be empty"
    end

    test "rejects missing diff parameter" do
      path = Path.join(@work_dir, "diff_missing_err.txt")
      File.write!(path, "content\n")

      {:error, reason} =
        Edit.execute(
          %{"file_path" => path, "mode" => "diff"},
          %{working_directory: @work_dir}
        )

      assert reason =~ "diff"
    end

    test "rejects diff with no valid hunks" do
      path = Path.join(@work_dir, "diff_nohunk.txt")
      File.write!(path, "content\n")

      {:error, reason} =
        Edit.execute(
          %{"file_path" => path, "mode" => "diff", "diff" => "this is not a diff"},
          %{working_directory: @work_dir}
        )

      assert reason =~ "No valid hunks"
    end

    test "rejects diff when file does not exist" do
      {:error, reason} =
        Edit.execute(
          %{
            "file_path" => Path.join(@work_dir, "no_such.txt"),
            "mode" => "diff",
            "diff" => "@@ -1 +1 @@\n-old\n+new\n"
          },
          %{working_directory: @work_dir}
        )

      assert reason =~ "File not found"
    end

    test "diff mode output includes diff_text and structured data" do
      path = Path.join(@work_dir, "diff_meta.txt")
      File.write!(path, "AAA\nBBB\n")

      diff = """
      --- a/diff_meta.txt
      +++ b/diff_meta.txt
      @@ -1,2 +1,2 @@
      -AAA
      +ZZZ
       BBB
      """

      {:ok, output, data} =
        Edit.execute(
          %{"file_path" => path, "mode" => "diff", "diff" => diff},
          %{working_directory: @work_dir, conversation_id: "edit-test"}
        )

      # Output includes diff text
      assert output =~ "- AAA"
      assert output =~ "+ ZZZ"

      # Structured metadata
      assert data.file_path == path
      assert data.mode == "diff"
      assert data.replacements >= 1
      assert data.change_id
      refute Map.has_key?(data, :before_content)
      refute Map.has_key?(data, :after_content)
      assert {:ok, snapshot} = Handbean.ChangeSnapshot.load(data.change_snapshot_ref)
      assert snapshot["before_content"] == "AAA\nBBB\n"
      assert snapshot["after_content"] == "ZZZ\nBBB\n"
      assert data.diff_first_changed_line == 1

      # Diff lines should contain the changes
      assert is_list(data.diff_lines)
      assert Enum.any?(data.diff_lines, &(&1["type"] == "del"))
      assert Enum.any?(data.diff_lines, &(&1["type"] == "ins"))
    end

    test "diff mode ignores old_string/new_string when mode=diff" do
      path = Path.join(@work_dir, "diff_ignore.txt")
      File.write!(path, "original\n")

      diff = """
      --- a/diff_ignore.txt
      +++ b/diff_ignore.txt
      @@ -1 +1 @@
      -original
      +modified
      """

      {:ok, output, data} =
        Edit.execute(
          %{
            "file_path" => path,
            "mode" => "diff",
            "diff" => diff,
            "old_string" => "should be ignored",
            "new_string" => "also ignored"
          },
          %{working_directory: @work_dir}
        )

      assert output =~ "diff mode"
      assert data.mode == "diff"
      assert data.replacements >= 1
      assert File.read!(path) == "modified\n"
    end
  end

  describe "tool metadata" do
    test "has correct name" do
      assert Edit.name() == "edit"
    end

    test "has input_schema with required fields" do
      schema = Edit.input_schema()
      assert "file_path" in schema.required
      refute "old_string" in schema.required
      refute "new_string" in schema.required
      assert Map.has_key?(schema.properties, :edits)
      assert Map.has_key?(schema.properties, :replacements)
    end

    test "declares max_result_chars" do
      assert Edit.max_result_chars() == 5_000
    end

    test "has input_schema with diff mode fields" do
      schema = Edit.input_schema()
      assert Map.has_key?(schema.properties, :mode)
      assert Map.has_key?(schema.properties, :diff)
      assert schema.properties.mode.default == "replace"
    end
  end
end
