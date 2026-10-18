defmodule Handbean.Agent.Tool.ResultTest do
  @moduledoc """
  Tests for the ToolResult dual-channel struct.

  Reference: `gong/tool_result.ex` (Gong ToolResult behavior)

  Covers:
    - Construction with content + optional details
    - Error results
    - from_text backward compatibility
    - llm_content / ui_details accessors
    - has_details? predicate
    - Details preserved when not in provider text
  """

  use ExUnit.Case, async: true

  alias Handbean.Agent.Tool.Result

  describe "new/3" do
    test "constructs a result with content and details" do
      result = Result.new("content text", %{exit_code: 0}, false)

      assert result.content == "content text"
      assert result.details == %{exit_code: 0}
      assert result.is_error == false
    end

    test "defaults details to nil and is_error to false" do
      result = Result.new("plain text")

      assert result.content == "plain text"
      assert result.details == nil
      assert result.is_error == false
    end

    test "supports nested details maps" do
      details = %{file_path: "/tmp/test.txt", lines: 42, meta: %{encoding: "UTF-8"}}
      result = Result.new("output", details)

      assert result.details.file_path == "/tmp/test.txt"
      assert result.details.meta.encoding == "UTF-8"
    end
  end

  describe "from_text/1" do
    test "constructs from plain text with nil details" do
      result = Result.from_text("hello")

      assert result.content == "hello"
      assert result.details == nil
      assert result.is_error == false
    end

    test "provides backward-compatible path for tools returning only a string" do
      result = Result.from_text("some output")

      assert Result.llm_content(result) == "some output"
      assert Result.ui_details(result) == nil
    end
  end

  describe "error/2" do
    test "constructs error result with error flag" do
      result = Result.error("File not found")

      assert result.content == "File not found"
      assert result.is_error == true
      assert Result.error?(result)
    end

    test "accepts optional details" do
      result = Result.error("Command failed", %{exit_code: 127})

      assert result.is_error == true
      assert result.details.exit_code == 127
    end
  end

  describe "accessors" do
    test "llm_content/1 returns content string" do
      result = Result.new("the content", %{key: "value"})

      assert Result.llm_content(result) == "the content"
    end

    test "ui_details/1 returns details map" do
      result = Result.new("content", %{meta: "data"})

      assert Result.ui_details(result) == %{meta: "data"}
    end

    test "ui_details/1 returns nil when no details" do
      result = Result.new("content only")

      assert Result.ui_details(result) == nil
    end

    test "error?/1 returns true for error results" do
      assert Result.error?(Result.error("oops"))
      refute Result.error?(Result.new("ok"))
    end

    test "has_details?/1 returns true only when details is non-nil" do
      assert Result.has_details?(Result.new("x", %{a: 1}))
      refute Result.has_details?(Result.new("x"))
      refute Result.has_details?(Result.from_text("x"))
    end
  end

  describe "published media projection" do
    test "keeps validated public media on the UI block and strips it from model history" do
      descriptor = %{
        media_id: "media-1",
        conversation_id: "conversation-1",
        kind: "image",
        mime_type: "image/png",
        filename: "result.png",
        size_bytes: 8,
        sha256: String.duplicate("a", 64),
        source: "agent"
      }

      result =
        Result.contract("published",
          side_effect: :committed,
          published_media: [descriptor]
        )

      block = Handbean.Agent.Tool.Executor.result_to_block(result, "tool-1")
      assert block.published_media == [descriptor]

      model_block = Handbean.Agent.Tool.Executor.strip_details(block)
      refute Map.has_key?(model_block, :published_media)
      refute Map.has_key?(model_block, :details)
    end
  end

  describe "details preservation" do
    test "error result preserves details even though provider only sees content" do
      result = Result.error("Permission denied", %{file_path: "/etc/shadow"})

      # LLM gets the string
      assert Result.llm_content(result) == "Permission denied"

      # UI gets the metadata
      assert Result.ui_details(result).file_path == "/etc/shadow"
    end

    test "success result with details separates content from metadata" do
      result =
        Result.new(
          "Wrote /tmp/demo.txt (42 bytes, 3 lines)",
          %{file_path: "/tmp/demo.txt", bytes: 42, lines: 3}
        )

      assert Result.llm_content(result) =~ "Wrote"
      assert Result.ui_details(result).bytes == 42
      assert Result.ui_details(result).lines == 3
    end

    test "details survive truncation (content may shrink, details remain full)" do
      long_content = String.duplicate("x", 100_000)
      result = Result.new(long_content, %{exit_code: 0, timed_out: false})

      # Simulate what executor does: truncate content, stash original in details
      truncated = %Result{result | content: String.slice(long_content, 0, 100)}

      # LLM gets the truncated version
      assert String.length(Result.llm_content(truncated)) <= 100

      # UI still has the original metadata
      assert Result.ui_details(truncated).exit_code == 0
    end
  end
end
