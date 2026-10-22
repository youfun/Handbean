defmodule Handbean.ConversationsReadTest do
  use Handbean.ConversationsCase, async: false

  alias Handbean.{ConversationTranscriptStore, Conversations}

  test "Unicode and single-message continuation preserve the entire tail", c do
    body = "甲🙂é乙終"

    {:ok, _} =
      ConversationTranscriptStore.append(c.target, %{
        "id" => "stable",
        "role" => "assistant",
        "content" => body,
        "details" => %{secret: "hidden"}
      })

    input = %{"conversation" => c.target, "max_chars" => 2}
    {:ok, p1} = Conversations.read(input, c.context)
    {:ok, p1_empty} = Conversations.read(Map.put(input, "cursor", ""), c.context)
    assert p1_empty.messages == p1.messages
    assert p1_empty.truncated == p1.truncated
    {:ok, p2} = Conversations.read(Map.put(input, "cursor", p1_empty.next_cursor), c.context)
    {:ok, p3} = Conversations.read(Map.put(input, "cursor", p2.next_cursor), c.context)
    assert Enum.map_join(p1.messages ++ p2.messages ++ p3.messages, & &1["content"]) == body
    assert Enum.map(p1.messages ++ p2.messages ++ p3.messages, & &1["offset"]) == [0, 2, 4]
    assert Enum.all?(p1.messages ++ p2.messages ++ p3.messages, &(&1["id"] == "stable"))
    refute Map.has_key?(hd(p1.messages), "details")
    assert p3.next_cursor == nil

    {:ok, _} =
      ConversationTranscriptStore.append(c.target, %{"id" => "new", "content" => "append"})

    assert {:error, :stale_or_invalid_cursor} =
             Conversations.read(Map.put(input, "cursor", p1.next_cursor), c.context)

    {:ok, fresh} = Conversations.read(input, c.context)
    ConversationTranscriptStore.update(c.target, "stable", %{"content" => "edited"})

    assert {:error, :stale_or_invalid_cursor} =
             Conversations.read(Map.put(input, "cursor", fresh.next_cursor), c.context)
  end

  test "reads text messages by default and includes tool summaries/outputs when opted in", c do
    {:ok, _} =
      ConversationTranscriptStore.append(c.target, %{
        "id" => "user-1",
        "role" => "user",
        "content" => "Read app.ex"
      })

    {:ok, _} =
      ConversationTranscriptStore.append(c.target, %{
        "id" => "tool-call-1",
        "role" => "tool",
        "content_type" => "tool",
        "tool_name" => "read",
        "tool_status" => "done",
        "input" => %{"file_path" => "lib/app.ex", "api_key" => "top-secret"},
        "output" => "1: defmodule App\nAuthorization: Bearer sub-token-value"
      })

    {:ok, _} =
      ConversationTranscriptStore.append(c.target, %{
        "id" => "assistant-1",
        "role" => "assistant",
        "content" => "Done"
      })

    assert {:ok, %{messages: text_only}} =
             Conversations.read(%{"conversation" => c.target}, c.context)

    assert Enum.map(text_only, & &1["id"]) == ["user-1", "assistant-1"]

    assert {:ok, %{messages: [_, msg, _]}} =
             Conversations.read(%{"conversation" => c.target, "include_tools" => true}, c.context)

    assert msg["id"] == "tool-call-1"
    assert msg["role"] == "tool"
    assert msg["tool_name"] == "read"
    assert msg["tool_status"] == "done"
    assert msg["content"] =~ "[tool read (done)]"
    assert msg["content"] =~ ~s("file_path":"lib/app.ex")
    assert msg["content"] =~ "1: defmodule App"
    refute msg["content"] =~ "top-secret"
    refute msg["content"] =~ "sub-token-value"

    assert {:error, :invalid_input} =
             Conversations.read(
               %{"conversation" => c.target, "include_tools" => "yes"},
               c.context
             )
  end

  test "historical status is idle without inventing success", c do
    assert {:ok, %{state: "idle", current_run: nil, last_result: nil}} =
             Conversations.status(%{"conversation" => c.target}, c.context)
  end

  test "generic updates return full entries while streaming append returns byte position", c do
    assert {:ok, _entry} =
             ConversationTranscriptStore.append(c.target, %{
               "id" => "stream-entry",
               "role" => "assistant",
               "content" => "你",
               "status" => "streaming",
               "metadata" => %{"kept" => true}
             })

    assert {:ok,
            %{
              "id" => "stream-entry",
              "content" => "你好",
              "metadata" => %{"kept" => true},
              "status" => "streaming"
            }} =
             ConversationTranscriptStore.update(c.target, "stream-entry", %{
               "content" => %{"$append" => "好"}
             })

    assert {:ok, %{id: "stream-entry", text_bytes: 10}} =
             ConversationTranscriptStore.append_content(
               c.target,
               "stream-entry",
               "🙂",
               "streaming"
             )

    assert {:ok, [%{"content" => "你好🙂", "metadata" => %{"kept" => true}}]} =
             ConversationTranscriptStore.list(c.target)
  end

  test "date filtering normalizes offsets and rejects malformed input", c do
    {:ok, %{conversations: []}} =
      Conversations.list(%{"updated_after" => "2999-01-01T00:00:00+08:00"}, c.context)

    {:ok, %{conversations: conversations}} =
      Conversations.list(%{"updated_after" => "2000-01-01T00:00:00+08:00"}, c.context)

    assert length(conversations) == 2

    assert {:error, :invalid_input} =
             Conversations.list(%{"updated_after" => "nonsense"}, c.context)
  end

  test "fragment count bounds empty messages and deletion invalidates continuation", c do
    for i <- 1..51,
        do: ConversationTranscriptStore.append(c.target, %{"id" => "m#{i}", "content" => ""})

    {:ok, page} = Conversations.read(%{"conversation" => c.target}, c.context)
    assert length(page.messages) == 50

    {:ok, tail} =
      Conversations.read(%{"conversation" => c.target, "cursor" => page.next_cursor}, c.context)

    assert [%{"id" => "m51"}] = tail.messages
    assert tail.next_cursor == nil
    ConversationTranscriptStore.delete(c.target, "m1")

    assert {:error, :stale_or_invalid_cursor} =
             Conversations.read(
               %{"conversation" => c.target, "cursor" => page.next_cursor},
               c.context
             )
  end
end
