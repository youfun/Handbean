defmodule Handbean.ConversationTranscriptStoreTest do
  use Handbean.DataCase, async: false

  alias Handbean.{ConversationStore, ConversationTranscriptStore}

  setup do
    id = "transcript-#{System.unique_integer([:positive])}"
    {:ok, conversation} = ConversationStore.create("default", id: id)
    %{id: conversation["id"]}
  end

  test "append, list, and deep patch preserve envelope and payload fields", %{id: id} do
    assert {:ok, first} =
             ConversationTranscriptStore.append(id, %{
               "id" => "user",
               "role" => "user",
               "content" => "hello",
               "created_at" => "2026-10-15T12:57:08Z",
               "raw_content" => [%{"type" => "text", "text" => "hello"}]
             })

    assert first["sequence"] == 1
    assert first["revision"] == 1
    assert first["created_at"] == "2026-10-15T12:57:08Z"

    assert {:ok, _} =
             ConversationTranscriptStore.append(id, %{
               "id" => "assistant",
               "role" => "assistant",
               "content" => "hi",
               "status" => "streaming",
               "details" => %{"a" => 1}
             })

    assert {:ok, updated} =
             ConversationTranscriptStore.update(id, "assistant", %{
               "content" => %{"$append" => " there"},
               "status" => "final",
               "details" => %{"b" => 2}
             })

    assert updated["content"] == "hi there"
    assert updated["status"] == "final"
    assert updated["details"] == %{"a" => 1, "b" => 2}
    assert updated["revision"] == 2

    assert {:ok, entries} = ConversationTranscriptStore.list(id)
    assert Enum.map(entries, & &1["id"]) == ["user", "assistant"]
  end

  test "explicit canonical nil clears a legacy tool error", %{id: id} do
    assert {:ok, _} =
             ConversationTranscriptStore.append(id, %{
               "id" => "tool",
               "content_type" => "tool",
               "status" => "error",
               "error" => "legacy",
               "tool_status" => "running"
             })

    assert {:ok, updated} = ConversationTranscriptStore.update(id, "tool", %{"tool_error" => nil})
    assert Map.has_key?(updated, "tool_error")
    assert updated["tool_error"] == nil
    assert Handbean.TranscriptEntry.error(updated) == nil
  end

  test "duplicate ids fail without consuming a sequence", %{id: id} do
    assert {:ok, %{"sequence" => 1}} = ConversationTranscriptStore.append(id, %{"id" => "same"})
    assert {:error, :duplicate_id} = ConversationTranscriptStore.append(id, %{"id" => "same"})
    assert {:ok, %{"sequence" => 2}} = ConversationTranscriptStore.append(id, %{"id" => "next"})
  end

  test "pagination is bounded, chronological, and rejects a deleted cursor", %{id: id} do
    for index <- 1..6 do
      assert {:ok, _} = ConversationTranscriptStore.append(id, %{"id" => "entry-#{index}"})
    end

    assert {:ok, %{entries: newest, before: "entry-4", has_more?: true}} =
             ConversationTranscriptStore.page(id, limit: 3)

    assert Enum.map(newest, & &1["id"]) == ~w(entry-4 entry-5 entry-6)

    assert {:ok, %{entries: oldest, before: nil, has_more?: false}} =
             ConversationTranscriptStore.page(id, limit: 3, before: "entry-4")

    assert Enum.map(oldest, & &1["id"]) == ~w(entry-1 entry-2 entry-3)
    assert :ok = ConversationTranscriptStore.delete(id, "entry-4")
    assert {:error, :invalid_cursor} = ConversationTranscriptStore.page(id, before: "entry-4")
  end

  test "replace_all rebuilds sequence and next append position", %{id: id} do
    assert {:ok, _} = ConversationTranscriptStore.append(id, %{"id" => "old"})

    assert :ok =
             ConversationTranscriptStore.replace_all(id, [
               %{"id" => "new-a", "sequence" => 99},
               %{"id" => "new-b", "sequence" => 100}
             ])

    assert {:ok, [%{"id" => "new-a", "sequence" => 1}, %{"id" => "new-b", "sequence" => 2}]} =
             ConversationTranscriptStore.list(id)

    assert {:ok, %{"sequence" => 3}} = ConversationTranscriptStore.append(id, %{"id" => "new-c"})
  end

  test "concurrent appends allocate unique monotonic sequences", %{id: id} do
    tasks =
      for index <- 1..40 do
        Task.async(fn ->
          ConversationTranscriptStore.append(id, %{"id" => "entry-#{index}", "content" => index})
        end)
      end

    assert Enum.all?(Enum.map(tasks, &Task.await(&1, 5_000)), &match?({:ok, _}, &1))
    assert {:ok, entries} = ConversationTranscriptStore.list(id)
    assert Enum.map(entries, & &1["sequence"]) == Enum.to_list(1..40)
    assert MapSet.size(MapSet.new(entries, & &1["id"])) == 40
  end

  test "concurrent CAS append patches do not lose bytes", %{id: id} do
    assert {:ok, _} = ConversationTranscriptStore.append(id, %{"id" => "stream", "content" => ""})

    tasks =
      for _ <- 1..20 do
        Task.async(fn ->
          ConversationTranscriptStore.update(id, "stream", %{"content" => %{"$append" => "x"}})
        end)
      end

    assert Enum.all?(Enum.map(tasks, &Task.await(&1, 5_000)), &match?({:ok, _}, &1))

    assert {:ok, [%{"content" => content, "revision" => 21}]} =
             ConversationTranscriptStore.list(id)

    assert content == String.duplicate("x", 20)
  end

  test "delete is idempotent and missing conversations map to not_found", %{id: id} do
    assert {:ok, _} = ConversationTranscriptStore.append(id, %{"id" => "remove"})
    assert :ok = ConversationTranscriptStore.delete(id, "remove")
    assert :ok = ConversationTranscriptStore.delete(id, "remove")
    assert {:ok, []} = ConversationTranscriptStore.list(id)

    assert {:error, :not_found} = ConversationTranscriptStore.list("missing")
    assert {:error, :not_found} = ConversationTranscriptStore.append("missing", %{"id" => "x"})
    assert {:error, :not_found} = ConversationTranscriptStore.replace_all("missing", [])
  end
end
