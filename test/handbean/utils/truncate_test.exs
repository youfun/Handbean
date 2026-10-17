defmodule Handbean.Utils.TruncateTest do
  @moduledoc """
  Tests for the unified truncation utility.

  Reference: `gong/utils/truncate.ex` (Gong Truncate behavior)
  Test pattern: hand-written from Gong Truncate source behavior

  Covers:
    - head_tail strategy: preserves head + tail, truncates middle
    - tail strategy: preserves only the end
    - max_bytes / max_chars stable behavior
    - Identity returns for non-truncating cases
    - Trailing newline handling
  """

  use ExUnit.Case, async: true

  alias Handbean.Utils.Truncate

  alias Handbean.Tool.Builtin.{Bash, Read}

  describe "truncate_head_tail/2" do
    test "returns unchanged when within limits" do
      text = "hello world"
      result = Truncate.truncate_head_tail(text, max_bytes: 100)

      assert result.truncated == false
      assert result.content == text
      assert result.output_bytes == byte_size(text)
    end

    test "truncates middle when line count exceeds head+tail" do
      lines = Enum.map(1..200, &"line #{&1}")
      text = Enum.join(lines, "\n")

      result = Truncate.truncate_head_tail(text, head_lines: 5, tail_lines: 5, max_bytes: 100_000)

      assert result.truncated == true
      assert result.truncated_by == :lines

      # Head lines present
      assert result.content =~ "line 1"
      assert result.content =~ "line 5"

      # Tail lines present
      assert result.content =~ "line 196"
      assert result.content =~ "line 200"

      # Omission marker present
      assert result.content =~ "省略"

      # Middle lines not present
      refute result.content =~ "line 100"
    end

    test "truncates by bytes when within line limit but exceeds byte limit" do
      long_line = String.duplicate("a", 10_000)
      text = "start\n#{long_line}\nend"

      result = Truncate.truncate_head_tail(text, head_lines: 50, tail_lines: 50, max_bytes: 1_000)

      assert result.truncated == true
      assert result.content =~ "start"
      assert result.content =~ "end"
      assert result.content =~ "省略"
    end

    test "handles single very-long line with byte truncation" do
      long_text = String.duplicate("abcdefghij", 10_000)

      result = Truncate.truncate_head_tail(long_text, max_bytes: 1_000)

      assert result.truncated == true
      assert result.truncated_by == :bytes
      assert result.output_bytes <= 1000
      assert result.content =~ "省略"
    end

    test "handles empty string" do
      result = Truncate.truncate_head_tail("", max_bytes: 100)

      assert result.truncated == false
      assert result.content == ""
      # Empty string splits to one empty element
      assert result.total_lines == 1
    end

    test "truncation marker appears in output" do
      lines = Enum.map(1..150, &"line #{&1}")
      text = Enum.join(lines, "\n")

      result = Truncate.truncate_head_tail(text, head_lines: 10, tail_lines: 10)

      assert result.truncated == true
      assert result.content =~ "..."
      assert result.content =~ "省略"
    end

    test "respects trailing newline in identity path" do
      text = "abc\ndef\n"

      result = Truncate.truncate_head_tail(text, max_bytes: 1_000_000)

      assert result.truncated == false
      assert result.content == text
    end
  end

  describe "truncate/3 :tail strategy" do
    test "returns unchanged when within limits" do
      text = "hello world"
      result = Truncate.truncate(text, :tail, max_bytes: 100)

      assert result.truncated == false
      assert result.content == text
    end

    test "keeps last N lines when line count exceeds limit" do
      lines = Enum.map(1..200, &"line #{&1}")
      text = Enum.join(lines, "\n")

      result = Truncate.truncate(text, :tail, max_lines: 5, max_bytes: 100_000)

      assert result.truncated == true
      assert result.truncated_by == :lines
      assert result.output_lines == 5
      assert result.content =~ "line 196"
      assert result.content =~ "line 200"
      # Tail preserves original order (not reversed)
      lines = String.split(result.content, "\n")
      assert lines == ["line 196", "line 197", "line 198", "line 199", "line 200"]
    end

    test "truncates by bytes when byte limit triggers first" do
      long_line = String.duplicate("x", 5_000)
      text = "prefix\n#{long_line}\nsuffix"

      result = Truncate.truncate(text, :tail, max_bytes: 500)

      assert result.truncated == true
      assert result.truncated_by == :bytes
      assert result.output_bytes <= 500
    end

    test "handles empty input" do
      result = Truncate.truncate("", :tail, max_bytes: 100)

      assert result.truncated == false
      assert result.content == ""
    end

    test "returns last partial line when exact byte fit" do
      text = String.duplicate("a", 50) <> "\n" <> String.duplicate("b", 50)

      result = Truncate.truncate(text, :tail, max_bytes: 60)

      # Should keep some subset of the tail
      assert result.truncated
      assert byte_size(result.content) <= 60
    end
  end

  describe "truncate_line/2" do
    test "returns unchanged when within max_chars" do
      text = "short line"
      result = Truncate.truncate_line(text, 50)

      assert result.truncated == false
      assert result.content == text
    end

    test "truncates and appends marker when exceeding max_chars" do
      text = String.duplicate("x", 200)

      result = Truncate.truncate_line(text, 100)

      assert result.truncated == true
      assert result.truncated_by == :chars
      assert result.content =~ "[truncated]"
      # Output should be slightly longer than max_chars due to marker suffix
      assert String.length(result.content) > 100
    end
  end

  describe "UTF-8 safety" do
    test "does not produce invalid UTF-8 in head_tail truncation" do
      # Build text with multi-byte UTF-8 chars near the truncation boundary
      prefix = String.duplicate("a", 100)
      japanese = String.duplicate("日本語", 50)
      text = prefix <> japanese

      result = Truncate.truncate_head_tail(text, max_bytes: 500)

      assert String.valid?(result.content)
    end

    test "does not produce invalid UTF-8 in tail truncation" do
      prefix = String.duplicate("b", 200)
      emoji = String.duplicate("😀", 50)
      text = prefix <> emoji

      result = Truncate.truncate(text, :tail, max_bytes: 500)

      assert String.valid?(result.content)
    end
  end

  describe "Result struct metadata" do
    test "provides accurate byte and line counts" do
      lines = Enum.map(1..10, &"line #{&1}")
      text = Enum.join(lines, "\n")

      result = Truncate.truncate(text, :tail, max_bytes: 1_000_000)

      assert result.total_lines == 10
      assert result.total_bytes == byte_size(text)
      assert result.output_lines == 10
      assert result.output_bytes == byte_size(text)
    end

    test "reports truncation metadata correctly" do
      lines = Enum.map(1..200, &"line #{&1}")
      text = Enum.join(lines, "\n")
      max_bytes = 1_000

      result =
        Truncate.truncate_head_tail(text, head_lines: 5, tail_lines: 5, max_bytes: max_bytes)

      assert result.truncated == true
      assert result.total_lines == 200
      assert result.total_bytes == byte_size(text)
      assert result.max_bytes == max_bytes
      assert result.output_bytes <= max_bytes
    end
  end

  describe "Gong BDD scenarios" do
    test "[BDD-TRC-005] head 首行超限" do
      text = String.duplicate("x", 500)
      result = Truncate.truncate(text, :head, max_bytes: 100)

      assert result.truncated == true
      assert result.truncated_by == :bytes
      assert result.first_line_exceeds_limit == true
    end

    test "[BDD-TRC-010] tail UTF-8 安全截断" do
      text = "你好世界测试\n第二行中文\n第三行数据\n第四行内容\n第五行结束"
      result = Truncate.truncate(text, :tail, max_bytes: 40)

      assert result.truncated == true
      assert result.truncated_by == :bytes
      assert result.last_line_partial == true
      assert String.valid?(result.content)
    end

    test "[BDD-TRC-013] read truncation notification" do
      tmp_dir = Path.join(System.tmp_dir!(), "sigil_trunc_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      target = Path.join(tmp_dir, "big.txt")
      lines = Enum.map(1..100, fn i -> String.duplicate("x", 200) <> " line #{i}" end)
      File.write!(target, Enum.join(lines, "\n"))

      {:ok, output, _meta} =
        Read.execute(
          %{"file_path" => target, "limit" => 50},
          %{working_directory: tmp_dir}
        )

      # Truncation hint with exact continuation offset
      assert output =~ "more lines"
      assert output =~ "offset=51"

      # Only the first 50 lines are returned
      assert output =~ "line 1"
      assert output =~ "line 50"
      refute output =~ "line 51"
    end

    @tag :os_sandbox
    test "[BDD-TRC-014] bash truncation notification" do
      # This is an end-to-end Bash sandbox test, not a pure truncation test.
      tmp_dir = Path.join(System.tmp_dir!(), "sigil_trunc_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      {:ok, output, _data} =
        Bash.execute(
          %{"command" => "seq 1 3000"},
          %{working_directory: tmp_dir}
        )

      # Bash tail-truncation: 3000 lines > @max_output_lines (2000)
      # → 1000 lines omitted, last 2000 lines kept
      # Since the output is well under @max_output_bytes (50K),
      # only the bash-internal tail truncation triggers (no executor head-tail)
      assert output =~ "1000 lines omitted"
      assert output =~ "3000"
      assert output =~ "1001"

      # Original head sequence must NOT appear intact
      refute output =~ "1\n2\n3\n4\n5"
    end
  end
end
