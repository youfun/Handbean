defmodule Handbean.ConversationTranscriptAroundTest do
  use Handbean.DataCase, async: false

  alias Handbean.{ConversationStore, ConversationTranscriptStore}

  test "reads bounded context around a stable entry and continues in both directions" do
    {:ok, conversation} = ConversationStore.create_free(id: "around-window")

    for index <- 1..11 do
      assert {:ok, _entry} =
               ConversationTranscriptStore.append(conversation["id"], %{
                 "id" => "entry-#{index}",
                 "role" => "user",
                 "content_type" => "user_msg",
                 "content" => "message #{index}"
               })
    end

    assert {:ok, page} =
             ConversationTranscriptStore.page(conversation["id"],
               around: "entry-6",
               before_limit: 2,
               after_limit: 2
             )

    assert Enum.map(page.entries, & &1["id"]) == ~w(entry-4 entry-5 entry-6 entry-7 entry-8)
    assert page.anchor == "entry-6"
    assert page.before == "entry-4"
    assert page.after == "entry-8"
    assert page.has_more_before?
    assert page.has_more_after?

    assert {:ok, older} =
             ConversationTranscriptStore.page(conversation["id"], limit: 3, before: page.before)

    assert Enum.map(older.entries, & &1["id"]) == ~w(entry-1 entry-2 entry-3)
    refute older.has_more?

    assert {:ok, newer} =
             ConversationTranscriptStore.page(conversation["id"], limit: 2, after: page.after)

    assert Enum.map(newer.entries, & &1["id"]) == ~w(entry-9 entry-10)
    assert newer.after == "entry-10"
    assert newer.has_more?

    assert {:ok, final} =
             ConversationTranscriptStore.page(conversation["id"], limit: 2, after: newer.after)

    assert Enum.map(final.entries, & &1["id"]) == ["entry-11"]
    assert final.after == "entry-11"
    refute final.has_more?

    assert {:ok, _entry} =
             ConversationTranscriptStore.append(conversation["id"], %{
               "id" => "entry-12",
               "role" => "assistant",
               "content_type" => "assistant_msg",
               "content" => "new tail"
             })

    assert {:ok, appended} =
             ConversationTranscriptStore.page(conversation["id"], limit: 2, after: final.after)

    assert Enum.map(appended.entries, & &1["id"]) == ["entry-12"]
    assert appended.after == "entry-12"
    refute appended.has_more?
  end

  test "deleted or cross-conversation anchors fail accurately" do
    {:ok, first} = ConversationStore.create_free(id: "around-first")
    {:ok, second} = ConversationStore.create_free(id: "around-second")

    assert {:ok, _entry} =
             ConversationTranscriptStore.append(first["id"], %{
               "id" => "anchor",
               "role" => "assistant",
               "content_type" => "assistant_msg",
               "content" => "answer"
             })

    assert {:error, :entry_unavailable} =
             ConversationTranscriptStore.page(second["id"], around: "anchor")

    assert :ok = ConversationTranscriptStore.delete(first["id"], "anchor")

    assert {:error, :entry_unavailable} =
             ConversationTranscriptStore.page(first["id"], around: "anchor")
  end
end
