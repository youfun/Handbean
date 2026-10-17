defmodule Handbean.ConversationStoreTest do
  use Handbean.DataCase, async: false

  alias Handbean.{ConversationStore, ConversationTranscriptStore}

  test "creates one conversation with editor state and transcript in a transaction" do
    assert {:ok, conversation} =
             ConversationStore.create("workspace-a",
               id: "conversation-create",
               title: "Stored chat",
               editor_files: [%{"path" => "notes.md", "content" => "hello"}],
               active_file: "notes.md",
               timeline: [%{"id" => "first", "role" => "user", "content" => "hello"}]
             )

    assert conversation["id"] == "conversation-create"
    assert conversation["scope"] == "workspace"
    assert conversation["workspace_id"] == "workspace-a"
    assert conversation["title"] == "Stored chat"
    assert conversation["active_file"] == "notes.md"
    assert [%{"path" => "notes.md"}] = conversation["editor_files"]
    assert [%{"id" => "first", "sequence" => 1}] = conversation["timeline"]
    assert {:ok, _, 0} = DateTime.from_iso8601(conversation["created_at"])
    assert {:ok, _, 0} = DateTime.from_iso8601(conversation["updated_at"])
  end

  test "creation rolls back when an initial entry violates the transcript contract" do
    assert {:error, _reason} =
             ConversationStore.create("workspace-a",
               id: "conversation-rollback",
               timeline: [%{"id" => "duplicate"}, %{"id" => "duplicate"}]
             )

    refute ConversationStore.exists?("conversation-rollback")
  end

  test "lists active user conversations by recency without exposing internal conversations" do
    {:ok, older} = ConversationStore.create("workspace-a", id: "older")
    {:ok, newer} = ConversationStore.create("workspace-a", id: "newer")
    {:ok, archived} = ConversationStore.create("workspace-a", id: "archived")

    {:ok, internal} =
      ConversationStore.create("workspace-a", id: "internal", visibility: "internal")

    {:ok, _} =
      ConversationStore.update_meta(older["id"], updated_at: "2000-01-01T00:00:00Z", touch: false)

    {:ok, _} =
      ConversationStore.update_meta(newer["id"], updated_at: "2001-01-01T00:00:00Z", touch: false)

    {:ok, _} = ConversationStore.archive(archived["id"])

    assert Enum.map(ConversationStore.list_for_workspace("workspace-a"), & &1["id"]) == [
             "newer",
             "older"
           ]

    assert Enum.sort(
             Enum.map(
               ConversationStore.list_for_workspace("workspace-a",
                 include_archived?: true,
                 include_internal?: true
               ),
               & &1["id"]
             )
           ) == Enum.sort([older["id"], newer["id"], archived["id"], internal["id"]])
  end

  test "legacy collaboration parents are ignored" do
    {:ok, _parent} = ConversationStore.create("workspace-a", id: "legacy-parent")

    {:ok, child} =
      ConversationStore.create("workspace-a",
        id: "legacy-child",
        collaboration: %{"parent" => "legacy-parent", "read_only" => true}
      )

    assert child["parent_conversation_id"] == nil

    assert Enum.find(ConversationStore.list_summaries("workspace-a"), &(&1["id"] == child["id"]))[
             "parent_conversation_id"
           ] == nil

    assert %Handbean.Storage.Conversation{parent_conversation_id: nil} =
             Handbean.Repo.get(Handbean.Storage.Conversation, child["id"])
  end

  test "touch false and assistant writes do not reorder the sidebar; user append does" do
    {:ok, conversation} = ConversationStore.create("workspace-a", id: "recency")
    original = conversation["updated_at"]

    assert {:ok, _} =
             ConversationStore.update_meta(conversation["id"],
               selected_model: "fake",
               touch: false
             )

    assert {:ok, _} =
             ConversationTranscriptStore.append(conversation["id"], %{
               "id" => "assistant",
               "role" => "assistant",
               "content" => "answer"
             })

    assert {:ok, unchanged} = ConversationStore.get(conversation["id"], include_timeline?: false)
    assert unchanged["updated_at"] == original

    assert {:ok, _} =
             ConversationTranscriptStore.append(conversation["id"], %{
               "id" => "user",
               "role" => "user",
               "content" => "question"
             })

    assert {:ok, touched} = ConversationStore.get(conversation["id"], include_timeline?: false)
    assert touched["updated_at"] > original
  end

  test "upsert preserves owned metadata and does not erase an existing transcript with an omitted timeline" do
    {:ok, _parent} = ConversationStore.create("workspace-a", id: "parent")

    {:ok, conversation} =
      ConversationStore.create("workspace-a",
        id: "upsert-owned",
        parent_conversation_id: "parent",
        parent_run_id: "run",
        timeline: [%{"id" => "kept", "content" => "persisted"}]
      )

    assert {:ok, updated} =
             ConversationStore.upsert(%{
               "id" => conversation["id"],
               "scope" => "workspace",
               "workspace_id" => "workspace-a",
               "title" => "Updated",
               "visibility" => "internal",
               "parent_conversation_id" => nil,
               "timeline" => []
             })

    assert updated["title"] == "Updated"
    assert updated["visibility"] == "user"
    assert updated["parent_conversation_id"] == "parent"
    assert updated["parent_run_id"] == "run"
    assert [%{"id" => "kept", "content" => "persisted"}] = updated["timeline"]
  end

  test "editor state round-trips independently and rejects a missing conversation" do
    {:ok, conversation} = ConversationStore.create_free(id: "editor-state")

    assert :ok =
             ConversationStore.save_files(conversation["id"], %{
               "editor_files" => [%{"path" => "a.txt", "content" => "A"}],
               "active_file" => "a.txt",
               "file_preview_error" => %{"code" => "binary"}
             })

    assert %{
             "active_file" => "a.txt",
             "editor_files" => [%{"path" => "a.txt", "content" => "A"}],
             "file_preview_error" => %{"code" => "binary"}
           } = ConversationStore.load_files(conversation["id"])

    assert {:error, :not_found} = ConversationStore.save_files("missing", %{})
  end

  test "run usage is idempotent by source and run while unkeyed usage accumulates" do
    {:ok, conversation} = ConversationStore.create("workspace-a", id: "usage")
    usage = %{"input_tokens" => 10, "output_tokens" => 2, "cache_read_tokens" => 3}

    assert :ok = ConversationStore.record_run_usage(conversation["id"], "run-1", usage)

    assert :ok =
             ConversationStore.record_run_usage(conversation["id"], "run-1", %{
               "input_tokens" => 999
             })

    assert :ok =
             ConversationStore.record_delegated_usage(conversation["id"], "child-1", %{
               "input_tokens" => 7
             })

    assert :ok = ConversationStore.add_token_usage(conversation["id"], %{"input_tokens" => 4})
    assert :ok = ConversationStore.add_token_usage(conversation["id"], %{"input_tokens" => 6})

    assert {:ok, totals} = ConversationStore.get_token_usage(conversation["id"])
    assert totals.input_tokens == 20
    assert totals.output_tokens == 2
    assert totals.cache_read_tokens == 3
    refute totals.usage_incomplete
    assert ConversationStore.delegated_usage(conversation["id"])["child-1"]["input_tokens"] == 7
  end

  test "usage rebuild atomically replaces parent and unkeyed usage but preserves delegated usage" do
    {:ok, conversation} = ConversationStore.create("workspace-a", id: "usage-rebuild")
    assert :ok = ConversationStore.add_token_usage(conversation["id"], %{"input_tokens" => 40})

    assert :ok =
             ConversationStore.record_delegated_usage(conversation["id"], "child", %{
               "input_tokens" => 9
             })

    events = [
      %{
        kind: :run_end,
        payload: %{run_id: "run-a", status: :completed, usage: %{input_tokens: 3}}
      },
      %{
        kind: :run_end,
        payload: %{run_id: "ignored", status: :interrupted, usage: %{input_tokens: 100}}
      }
    ]

    assert :ok = ConversationStore.rebuild_token_usage_from_events(conversation["id"], events)
    assert {:ok, %{input_tokens: 3}} = ConversationStore.get_token_usage(conversation["id"])
    assert ConversationStore.delegated_usage(conversation["id"])["child"]["input_tokens"] == 9
  end

  test "missing conversations return stable not_found results" do
    assert {:error, :not_found} = ConversationStore.get("missing")
    assert {:error, :not_found} = ConversationStore.update_meta("missing", title: "No")
    assert {:error, :not_found} = ConversationStore.append_message("missing", %{"id" => "entry"})
    assert {:error, :not_found} = ConversationStore.replace_messages("missing", [])
  end

  test "workspace creation fails without a resolvable checkout outside the test escape hatch" do
    previous = Application.fetch_env(:handbean, :allow_unbound_test_conversations)
    Application.delete_env(:handbean, :allow_unbound_test_conversations)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:handbean, :allow_unbound_test_conversations, value)
        :error -> Application.delete_env(:handbean, :allow_unbound_test_conversations)
      end
    end)

    assert {:error, {:invalid_checkout_path, :not_found}} =
             ConversationStore.create("unknown-workspace", id: "strict-checkout")

    refute ConversationStore.exists?("strict-checkout")
  end

  test "workspace checkout is canonical, exposed in summaries, and immutable" do
    root =
      Path.join(System.tmp_dir!(), "conversation-checkout-#{System.unique_integer([:positive])}")

    other = root <> "-other"
    File.mkdir_p!(root)
    File.mkdir_p!(other)

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(other)
    end)

    assert {:ok, conversation} =
             ConversationStore.create("workspace-a", id: "checkout", checkout_path: root)

    expected = Handbean.Security.PathValidator.resolve_symlink(root)
    assert conversation["checkout_path"] == expected
    assert {:ok, ^expected} = ConversationStore.effective_checkout_path(conversation)

    assert Enum.find(ConversationStore.list_summaries("workspace-a"), &(&1["id"] == "checkout"))[
             "checkout_path"
           ] == conversation["checkout_path"]

    assert {:ok, _metadata} =
             ConversationStore.update_meta("checkout", checkout_path: other, title: "Still here")

    assert {:ok, unchanged} = ConversationStore.get_metadata("checkout")
    assert unchanged["checkout_path"] == conversation["checkout_path"]

    assert {:ok, upserted} =
             ConversationStore.upsert(%{
               "id" => "checkout",
               "scope" => "workspace",
               "workspace_id" => "workspace-a",
               "checkout_path" => other,
               "title" => "Upserted"
             })

    assert upserted["checkout_path"] == conversation["checkout_path"]
  end

  test "free chats have no checkout and missing checkouts never fall back" do
    assert {:ok, free} = ConversationStore.create_free(id: "free-checkout")
    assert free["checkout_path"] == nil
    assert {:error, :checkout_path_missing} = ConversationStore.effective_checkout_path(free)

    root = Path.join(System.tmp_dir!(), "deleted-checkout-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    assert {:ok, conversation} =
             ConversationStore.create("workspace-a", id: "deleted-checkout", checkout_path: root)

    File.rm_rf!(root)

    assert {:error, :checkout_unavailable} =
             ConversationStore.effective_checkout_path(conversation)
  end

  test "ensure_for_workspaces creates only missing conversations" do
    {:ok, existing} = ConversationStore.create("workspace-a", id: "existing")
    workspaces = [%{"id" => "workspace-a"}, %{"id" => "workspace-b"}]

    result = ConversationStore.ensure_for_workspaces(workspaces)
    assert Enum.map(result["workspace-a"], & &1["id"]) == [existing["id"]]
    assert [%{"workspace_id" => "workspace-b"}] = result["workspace-b"]
    assert length(ConversationStore.list_for_workspace("workspace-b")) == 1
  end
end
