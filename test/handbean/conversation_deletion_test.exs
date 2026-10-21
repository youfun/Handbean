defmodule Handbean.ConversationDeletionTest do
  use Handbean.DataCase, async: false

  import Ecto.Query

  alias Handbean.{ConversationStore, ConversationTranscriptStore, Media, Repo}
  alias Handbean.Storage.{Conversation, ConversationMedia}

  defmodule FailingDeleteBackend do
    @behaviour Handbean.Media.Backend

    @impl true
    def put(_storage_key, _bytes, _metadata), do: :ok

    @impl true
    def delivery(_storage_key, _metadata), do: {:error, :not_available}

    @impl true
    def delete(_storage_key, _metadata), do: {:error, :backend_unavailable}
  end

  setup do
    data_dir =
      Path.join(System.tmp_dir!(), "handbean_delete_#{System.unique_integer([:positive])}")

    File.mkdir_p!(data_dir)
    previous_host = Application.get_env(:handbean, :host)
    Handbean.Host.put!(Map.put(previous_host || %{}, :data_dir, data_dir))

    on_exit(fn ->
      if previous_host,
        do: Application.put_env(:handbean, :host, previous_host),
        else: Application.delete_env(:handbean, :host)

      File.rm_rf!(data_dir)
    end)

    :ok
  end

  test "request atomically hides a thread subtree and blocks late writes" do
    {:ok, parent} = ConversationStore.create("workspace", id: "delete-parent", title: "Parent")

    {:ok, child} =
      ConversationStore.create("workspace",
        id: "delete-child",
        title: "Child",
        visibility: "internal",
        parent_conversation_id: parent["id"]
      )

    {:ok, media} =
      Media.stage(png(),
        conversation_id: child["id"],
        producer_tool_call_id: "delete-tool",
        filename: "result.png"
      )

    assert {:ok, %{descendant_count: 1}} = ConversationStore.delete_preview(parent["id"])
    assert {:ok, ids} = ConversationStore.request_delete(parent["id"])
    assert MapSet.new(ids) == MapSet.new([parent["id"], child["id"]])

    refute ConversationStore.exists?(parent["id"])
    refute ConversationStore.exists?(child["id"])
    assert {:error, :not_found} = ConversationStore.get_metadata(parent["id"])

    refute Enum.any?(
             ConversationStore.list(include_internal?: true),
             &(&1["id"] in [parent["id"], child["id"]])
           )

    assert Repo.get!(Conversation, parent["id"]).status == "pending_delete"
    assert Repo.get!(Conversation, child["id"]).status == "pending_delete"
    assert Repo.get!(ConversationMedia, media.id).status == "pending_delete"

    assert {:error, :invalid_or_inactive_conversation} =
             Handbean.ConversationArtifacts.persist_tool_result("late output", %{
               conversation_id: parent["id"]
             })

    assert {:error, :not_found} =
             ConversationTranscriptStore.append(parent["id"], %{
               "id" => "late-entry",
               "role" => "user",
               "content" => "too late"
             })

    assert {:error, :not_found} =
             Handbean.Agent.Coordinator.start_run(parent["id"], "late run", [])

    assert {:error, :not_found} =
             Handbean.Agent.Coordinator.enqueue_candidate(parent["id"], "late message")

    assert {:error, :conversation_pending_delete} =
             Media.mark_ready(
               child["id"],
               "delete-tool",
               "late-media-entry",
               [media.id]
             )

    assert {:error, :conversation_pending_delete} =
             Media.stage(png(),
               conversation_id: parent["id"],
               producer_tool_call_id: "late-tool",
               filename: "late.png"
             )

    assert {:error, _reason} =
             ConversationStore.create("workspace",
               id: "late-child",
               parent_conversation_id: parent["id"]
             )

    pending_delete_at = Repo.get!(Conversation, parent["id"]).pending_delete_at
    assert {:ok, replayed_ids} = ConversationStore.request_delete(parent["id"])
    assert MapSet.new(replayed_ids) == MapSet.new(ids)
    assert Repo.get!(Conversation, parent["id"]).pending_delete_at == pending_delete_at
  end

  test "cleaner removes managed objects before deleting media rows and conversations" do
    {:ok, conversation} =
      ConversationStore.create("workspace", id: "delete-cleaner", title: "Cleanup")

    {:ok, media} =
      Media.stage(png(),
        conversation_id: conversation["id"],
        producer_tool_call_id: "cleaner-tool",
        filename: "cleaner.png"
      )

    artifact_path =
      Path.join([
        Handbean.ConversationArtifacts.root(),
        "items",
        conversation["id"],
        "tool-results",
        "spill-test.txt"
      ])

    File.mkdir_p!(Path.dirname(artifact_path))
    File.write!(artifact_path, "artifact")

    assert {:ok, {:send_file, path}} = Media.delivery(%{media | status: "ready"})
    assert File.exists?(path)
    conversation_id = conversation["id"]
    assert {:ok, [^conversation_id]} = ConversationStore.request_delete(conversation_id)

    age_pending_delete(conversation_id)
    assert %{failed: 0} = Handbean.Media.Cleaner.run_now()

    refute File.exists?(path)
    refute File.exists?(artifact_path)
    refute Repo.get(ConversationMedia, media.id)
    refute Repo.get(Conversation, conversation["id"])
  end

  test "cleaner keeps every locator and conversation when any backend delete fails" do
    {:ok, conversation} =
      ConversationStore.create("workspace", id: "delete-retry", title: "Retry")

    registry = %{"failing" => FailingDeleteBackend}

    {:ok, local_media} =
      Media.stage(png(),
        conversation_id: conversation["id"],
        producer_tool_call_id: "local-retry-tool",
        filename: "local-retry.png"
      )

    assert {:ok, {:send_file, local_path}} = Media.delivery(%{local_media | status: "ready"})

    {:ok, media} =
      Media.stage(png(),
        conversation_id: conversation["id"],
        producer_tool_call_id: "retry-tool",
        filename: "retry.png",
        backend: "failing",
        backend_registry: registry
      )

    assert {:ok, [_]} = ConversationStore.request_delete(conversation["id"])
    age_pending_delete(conversation["id"])
    assert %{failed: failed} = Handbean.Media.Cleaner.run_now()
    assert failed > 0

    assert %Conversation{status: "pending_delete"} = Repo.get(Conversation, conversation["id"])
    refute File.exists?(local_path)

    assert %ConversationMedia{status: "pending_delete"} =
             Repo.get(ConversationMedia, local_media.id)

    assert %ConversationMedia{
             status: "pending_delete",
             backend: "failing",
             storage_key: storage_key
           } = Repo.get(ConversationMedia, media.id)

    assert storage_key == "#{conversation["id"]}/#{media.id}.png"
  end

  test "artifact cleanup failure keeps deletion pending and retries", do: artifact_cleanup_retry()

  defp artifact_cleanup_retry do
    {:ok, conversation} =
      ConversationStore.create("workspace", id: "delete-artifact-retry", title: "Retry artifacts")

    root = Handbean.ConversationArtifacts.root()
    items = Path.join(root, "items")
    outside = Path.join(Path.dirname(root), "outside-artifacts")
    item = Path.join(items, conversation["id"])

    File.mkdir_p!(items)
    File.mkdir_p!(outside)
    File.ln_s!(outside, item)

    assert {:ok, [_]} = ConversationStore.request_delete(conversation["id"])
    age_pending_delete(conversation["id"])

    assert %{failed: failed} = Handbean.Media.Cleaner.run_now()
    assert failed > 0
    assert %Conversation{status: "pending_delete"} = Repo.get(Conversation, conversation["id"])

    File.rm!(item)

    assert %{failed: 0} = Handbean.Media.Cleaner.run_now()
    refute Repo.get(Conversation, conversation["id"])
  end

  defp age_pending_delete(conversation_id) do
    old = DateTime.add(DateTime.utc_now(), -120, :second)

    Repo.update_all(
      from(conversation in Conversation, where: conversation.id == ^conversation_id),
      set: [pending_delete_at: old]
    )

    Repo.update_all(
      from(media in ConversationMedia, where: media.conversation_id == ^conversation_id),
      set: [updated_at: old]
    )
  end

  defp png, do: <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 0>>
end
