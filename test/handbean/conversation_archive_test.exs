defmodule Handbean.ConversationArchiveTest do
  use Handbean.DataCase, async: false

  alias Handbean.ConversationStore

  test "archiving a parent atomically archives its active descendants" do
    {:ok, parent} =
      ConversationStore.create("archive-workspace", id: "archive-parent", title: "Parent")

    {:ok, child} =
      ConversationStore.create("archive-workspace",
        id: "archive-child",
        title: "Child",
        parent_conversation_id: parent["id"]
      )

    {:ok, grandchild} =
      ConversationStore.create("archive-workspace",
        id: "archive-grandchild",
        title: "Grandchild",
        parent_conversation_id: child["id"]
      )

    {:ok, sibling} =
      ConversationStore.create("archive-workspace", id: "archive-sibling", title: "Sibling")

    assert {:ok, %{descendant_count: 2}} = ConversationStore.archive_preview(parent["id"])

    assert {:ok, archived_parent, archived_ids} =
             ConversationStore.archive_subtree(parent["id"])

    assert archived_parent["id"] == parent["id"]

    assert MapSet.new(archived_ids) ==
             MapSet.new([parent["id"], child["id"], grandchild["id"]])

    for id <- archived_ids do
      assert {:ok, %{"archived_at" => archived_at}} = ConversationStore.get_metadata(id)
      assert is_binary(archived_at)
    end

    assert {:ok, %{"archived_at" => nil}} = ConversationStore.get_metadata(sibling["id"])

    assert {:ok, _parent} = ConversationStore.unarchive(parent["id"])
    assert {:ok, %{"archived_at" => nil}} = ConversationStore.get_metadata(parent["id"])

    for id <- [child["id"], grandchild["id"]] do
      assert {:ok, %{"archived_at" => archived_at}} = ConversationStore.get_metadata(id)
      assert is_binary(archived_at)
    end
  end

  test "leaf-only archive refuses a descendant created after preview" do
    {:ok, parent} = ConversationStore.create_free(id: "leaf-race-parent")
    assert {:ok, %{descendant_count: 0}} = ConversationStore.archive_preview(parent["id"])

    {:ok, child} =
      ConversationStore.create_free(
        id: "leaf-race-child",
        parent_conversation_id: parent["id"]
      )

    assert {:error, :confirmation_required} =
             ConversationStore.archive_subtree_if_leaf(parent["id"])

    for id <- [parent["id"], child["id"]] do
      assert {:ok, %{"archived_at" => nil}} = ConversationStore.get_metadata(id)
    end
  end

  test "internal descendants do not require confirmation but are archived with their parent" do
    {:ok, parent} = ConversationStore.create_free(id: "internal-descendant-parent")

    {:ok, internal} =
      ConversationStore.create_free(
        id: "internal-descendant-child",
        visibility: "internal",
        parent_conversation_id: parent["id"]
      )

    assert {:ok, %{descendant_count: 0}} = ConversationStore.archive_preview(parent["id"])

    assert {:ok, _parent, archived_ids} =
             ConversationStore.archive_subtree_if_leaf(parent["id"])

    assert MapSet.new(archived_ids) == MapSet.new([parent["id"], internal["id"]])

    for id <- archived_ids do
      assert {:ok, %{"archived_at" => archived_at}} = ConversationStore.get_metadata(id)
      assert is_binary(archived_at)
    end
  end

  test "a user descendant below an internal node still requires confirmation" do
    {:ok, parent} = ConversationStore.create_free(id: "nested-visible-parent")

    {:ok, internal} =
      ConversationStore.create_free(
        id: "nested-visible-internal",
        visibility: "internal",
        parent_conversation_id: parent["id"]
      )

    {:ok, grandchild} =
      ConversationStore.create_free(
        id: "nested-visible-grandchild",
        parent_conversation_id: internal["id"]
      )

    assert {:ok, %{descendant_count: 1}} = ConversationStore.archive_preview(parent["id"])

    assert {:error, :confirmation_required} =
             ConversationStore.archive_subtree_if_leaf(parent["id"])

    for id <- [parent["id"], internal["id"], grandchild["id"]] do
      assert {:ok, %{"archived_at" => nil}} = ConversationStore.get_metadata(id)
    end
  end

  test "archive preview excludes descendants that are already archived" do
    {:ok, parent} = ConversationStore.create_free(id: "preview-parent")

    {:ok, child} =
      ConversationStore.create_free(
        id: "preview-child",
        parent_conversation_id: parent["id"]
      )

    assert {:ok, _child} = ConversationStore.archive(child["id"])
    assert {:ok, %{descendant_count: 0}} = ConversationStore.archive_preview(parent["id"])
  end
end
