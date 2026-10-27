defmodule HandbeanProbe.ConversationResetTest do
  @moduledoc """
  Host screen tests start from an empty conversation store. Two conversation
  foreign keys are ON DELETE RESTRICT — `conversations.parent_conversation_id`
  and `conversation_media.conversation_id` — so the reset must clear both
  before deleting conversations. Without it `setup` raises
  `Exqlite.Error FOREIGN KEY constraint failed` and every test in the file
  fails for a reason unrelated to its subject.
  """

  use ExUnit.Case, async: false

  alias Handbean.Storage.{Conversation, ConversationMedia}

  test "clears delegated children and media instead of relaxing foreign keys" do
    {:ok, parent} = Handbean.ConversationStore.create_free(title: "Parent chat")

    {:ok, child} =
      Handbean.ConversationStore.create_free(
        title: "Delegated chat",
        parent_conversation_id: parent["id"]
      )

    media = insert_media!(child["id"])

    # The reset runs with foreign keys enforced, so a child pointing at its
    # parent or a media row still pointing at its conversation fails here.
    assert :ok = HandbeanProbe.TestDB.reset_conversations!()

    assert Handbean.Repo.all(Conversation) == []
    assert Handbean.Repo.all(ConversationMedia) == []
    assert Handbean.Repo.get(ConversationMedia, media.id) == nil
  end

  defp insert_media!(conversation_id) do
    %ConversationMedia{}
    |> ConversationMedia.create_changeset(%{
      id: Ecto.UUID.generate(),
      conversation_id: conversation_id,
      producer_tool_call_id: "reset-test-tool-call",
      purpose: "published",
      backend: "workspace",
      storage_key: "media/reset-test.png",
      mime_type: "image/png",
      filename: "reset-test.png",
      size_bytes: 12,
      sha256: String.duplicate("a", 64),
      status: "staged"
    })
    |> Handbean.Repo.insert!()
  end
end
