defmodule Handbean.Agent.MessageTest do
  @moduledoc """
  Tests for message creation and tool call extraction.

  Reference: `alloy/` (Message struct and helpers)

  Covers:
    - Creating user/assistant/tool_use/tool_result messages
    - tool_calls extraction
    - tool_result_block helpers
  """

  use ExUnit.Case, async: true

  alias Handbean.Agent.Message

  describe "message creation" do
    test "creates user message" do
      msg = Message.user("Hello")
      assert msg.role == :user
      assert msg.content == "Hello"
    end

    test "creates assistant message" do
      msg = Message.assistant("Response")
      assert msg.role == :assistant
      assert msg.content == "Response"
    end

    test "creates tool_use message" do
      calls = [
        %{
          type: "tool_use",
          id: "tool_1",
          name: "read",
          input: %{"file_path" => "test.txt"}
        }
      ]

      msg = Message.tool_use(calls)
      assert msg.role == :assistant
      assert is_list(msg.content)
      assert length(msg.content) == 1
    end

    test "creates tool_result message" do
      block = Message.tool_result_block("tool_1", "file contents", false)
      msg = Message.tool_result(block)
      assert msg.role == :tool_result
      assert msg.content[:tool_use_id] == "tool_1"
    end

    test "creates batched tool_results message" do
      blocks = [
        Message.tool_result_block("tool_a", "result a", false),
        Message.tool_result_block("tool_b", "result b", true)
      ]

      msg = Message.tool_results(blocks)
      assert msg.role == :tool_result
      assert is_list(msg.content)
      assert length(msg.content) == 2
    end
  end

  describe "tool_calls/1 extraction" do
    test "extracts tool calls from assistant message" do
      calls = [
        %{
          type: "tool_use",
          id: "tool_1",
          name: "read",
          input: %{"file_path" => "f.txt"}
        },
        %{
          type: "tool_use",
          id: "tool_2",
          name: "bash",
          input: %{"command" => "ls"}
        }
      ]

      msg = Message.tool_use(calls)
      extracted = Message.tool_calls(msg)

      assert length(extracted) == 2
      assert Enum.at(extracted, 0).name == "read"
      assert Enum.at(extracted, 1).name == "bash"
    end

    test "returns empty list for non-assistant messages" do
      msg = Message.user("Hello")
      assert Message.tool_calls(msg) == []
    end

    test "returns empty list for text assistant messages" do
      msg = Message.assistant("Text response")
      assert Message.tool_calls(msg) == []
    end
  end

  describe "tool_result_block/3" do
    test "creates a result block" do
      block = Message.tool_result_block("tid", "content")
      assert block[:type] == "tool_result"
      assert block[:tool_use_id] == "tid"
      assert block[:content] == "content"
      assert block[:is_error] == false
    end

    test "creates an error block" do
      block = Message.tool_result_block("tid", "fail", true)
      assert block[:is_error] == true
    end
  end

  describe "text/1" do
    test "extracts text from string-key content blocks" do
      msg = %Message{role: :assistant, content: [%{"type" => "text", "text" => "hello"}]}

      assert Message.text(msg) == "hello"
    end
  end
end
