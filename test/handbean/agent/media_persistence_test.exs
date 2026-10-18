defmodule Handbean.Agent.MediaPersistenceTest do
  use Handbean.DataCase, async: false

  alias Handbean.Agent.TranscriptPersistence
  alias Handbean.Storage.ConversationMedia

  @png <<137, 80, 78, 71, 13, 10, 26, 10>>

  setup do
    root = Path.join(System.tmp_dir!(), "media-persistence-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous_host = Application.get_env(:handbean, :host)
    Handbean.Host.put!(%{data_dir: root})
    {:ok, conversation} = Handbean.ConversationStore.create_free()

    on_exit(fn ->
      if previous_host,
        do: Application.put_env(:handbean, :host, previous_host),
        else: Application.delete_env(:handbean, :host)

      File.rm_rf!(root)
    end)

    %{conversation_id: conversation["id"]}
  end

  test "tool_end atomically makes staged media ready and appends one assistant media entry",
       context do
    id = context.conversation_id
    tool_use_id = "publish-atomic"
    opts = [run_id: "run-media", source: :web]

    assert :ok =
             TranscriptPersistence.handle_event(
               id,
               {:tool_start,
                %{
                  tool: "publish_media",
                  tool_use_id: tool_use_id,
                  input: %{"path" => "generated.png"}
                }},
               opts
             )

    assert {:ok, media} =
             Handbean.Media.stage(@png,
               conversation_id: id,
               producer_tool_call_id: tool_use_id,
               filename: "generated.png"
             )

    descriptor = Handbean.Media.project(media)

    assert :ok =
             TranscriptPersistence.handle_event(
               id,
               {:tool_end,
                %{
                  tool: "publish_media",
                  tool_use_id: tool_use_id,
                  output: "published",
                  published_media: [descriptor]
                }},
               opts
             )

    ready = Repo.get!(ConversationMedia, media.id)
    assert ready.status == "ready"
    assert ready.producing_entry_id == "msg-media-#{tool_use_id}"

    assert {:ok, entries} = Handbean.ConversationTranscriptStore.list(id)
    assert [tool, assistant] = entries
    assert tool["tool_status"] == "done"
    assert assistant["id"] == "msg-media-#{tool_use_id}"
    assert assistant["role"] == "assistant"
    assert assistant["content"] in [nil, ""]
    assert [persisted] = assistant["attachments"]
    assert persisted["media_id"] == media.id
    refute Map.has_key?(persisted, "url")
    refute Map.has_key?(persisted, "storage_key")

    assert :ok =
             TranscriptPersistence.handle_event(
               id,
               {:tool_end,
                %{
                  tool: "publish_media",
                  tool_use_id: tool_use_id,
                  output: "published",
                  published_media: [descriptor]
                }},
               opts
             )

    assert {:ok, repeated} = Handbean.ConversationTranscriptStore.list(id)
    assert Enum.count(repeated, &(&1["id"] == "msg-media-#{tool_use_id}")) == 1
  end

  test "descriptor mismatch rolls back tool completion and leaves media staged", context do
    id = context.conversation_id
    tool_use_id = "publish-mismatch"

    assert :ok =
             TranscriptPersistence.handle_event(
               id,
               {:tool_start,
                %{tool: "publish_media", tool_use_id: tool_use_id, input: %{"path" => "x.png"}}}
             )

    assert {:ok, media} =
             Handbean.Media.stage(@png,
               conversation_id: id,
               producer_tool_call_id: tool_use_id,
               filename: "x.png"
             )

    forged = %{Handbean.Media.project(media) | media_id: Ecto.UUID.generate()}

    assert {:error, :media_set_mismatch} =
             TranscriptPersistence.handle_event(
               id,
               {:tool_end,
                %{
                  tool: "publish_media",
                  tool_use_id: tool_use_id,
                  published_media: [forged]
                }}
             )

    assert Repo.get!(ConversationMedia, media.id).status == "staged"
    assert {:ok, [tool]} = Handbean.ConversationTranscriptStore.list(id)
    assert tool["tool_status"] == "running"
    refute Enum.any?([tool], &(&1["role"] == "assistant"))
  end
end
