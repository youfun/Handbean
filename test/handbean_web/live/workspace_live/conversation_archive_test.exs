defmodule HandbeanWeb.WorkspaceLive.ConversationArchiveTest do
  use HandbeanWeb.WorkspaceLiveCase

  test "archiving a parent asks for confirmation and archives its child threads", %{conn: conn} do
    {:ok, workspace} = Handbean.WorkspaceStore.ensure_default!()

    {:ok, parent} =
      Handbean.ConversationStore.create(workspace["id"],
        id: "archive-thread-parent",
        title: "Archive family"
      )

    {:ok, child} =
      Handbean.ConversationStore.create(workspace["id"],
        id: "archive-thread-child",
        title: "Archive child",
        parent_conversation_id: parent["id"]
      )

    {:ok, grandchild} =
      Handbean.ConversationStore.create(workspace["id"],
        id: "archive-thread-grandchild",
        title: "Archive grandchild",
        parent_conversation_id: child["id"]
      )

    {:ok, internal} =
      Handbean.ConversationStore.create(workspace["id"],
        id: "archive-thread-internal",
        title: "Hidden subagent",
        visibility: "internal",
        parent_conversation_id: parent["id"]
      )

    {:ok, view, _html} = live(conn, "/w/#{workspace["id"]}/c/#{child["id"]}")
    render_async(view, 5_000)

    render_click(view, "archive_conversation", %{
      "id" => parent["id"],
      "ws_id" => workspace["id"]
    })

    assert has_element?(view, "#archive-conversation-dialog[role='alertdialog']")
    assert has_element?(view, "#archive-conversation-descendants", "2 child threads")

    view |> element("#cancel-archive-conversation") |> render_click()
    refute has_element?(view, "#archive-conversation-dialog")
    assert {:ok, %{"archived_at" => nil}} = Handbean.ConversationStore.get_metadata(parent["id"])

    render_click(view, "archive_conversation", %{
      "id" => parent["id"],
      "ws_id" => workspace["id"]
    })

    view |> element("#confirm-archive-conversation") |> render_click()

    refute has_element?(view, "#archive-conversation-dialog")
    refute has_element?(view, "#conversation-#{parent["id"]}")
    refute has_element?(view, "#conversation-#{child["id"]}")
    refute has_element?(view, "#conversation-#{grandchild["id"]}")

    for conversation <- [parent, child, grandchild, internal] do
      assert {:ok, %{"archived_at" => archived_at}} =
               Handbean.ConversationStore.get_metadata(conversation["id"])

      assert is_binary(archived_at)
    end

    current_id = view |> render() |> session_id_from_html()
    refute current_id in [parent["id"], child["id"], grandchild["id"]]
  end
end
