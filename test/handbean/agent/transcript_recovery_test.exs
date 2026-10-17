defmodule Handbean.Agent.TranscriptRecoveryTest do
  use Handbean.DataCase, async: false

  alias Handbean.Agent.{TranscriptPersistence, TranscriptRecovery}
  alias Handbean.{ConversationStore, ConversationTranscriptStore}

  setup do
    {:ok, conversation} = ConversationStore.create("default", timeline: [])
    %{id: conversation["id"]}
  end

  test "indexed startup recovery seals every orphan once", %{id: first_id} do
    {:ok, second} = ConversationStore.create("default", timeline: [])

    for {id, run_id} <- [{first_id, "first-run"}, {second["id"], "second-run"}] do
      assert {:ok, _} =
               ConversationTranscriptStore.append(id, %{
                 "id" => "tool-#{run_id}",
                 "run_id" => run_id,
                 "role" => "tool",
                 "content_type" => "tool",
                 "tool_status" => "running"
               })

      assert {:ok, _} =
               ConversationTranscriptStore.append(id, %{
                 "id" => "reply-#{run_id}",
                 "run_id" => run_id,
                 "role" => "assistant",
                 "status" => "streaming",
                 "content" => "durable partial"
               })
    end

    assert :ok = TranscriptRecovery.run()
    assert :ok = TranscriptRecovery.run()

    for {id, run_id} <- [{first_id, "first-run"}, {second["id"], "second-run"}] do
      assert {:ok, [tool, assistant, error]} = ConversationTranscriptStore.list(id)
      assert tool["tool_status"] == "error"
      assert assistant["status"] == "error"
      assert assistant["content"] == "durable partial"
      assert error["id"] == "msg-run-error-#{run_id}"
    end
  end

  test "recovery can seal an internal orphan without granting public read access" do
    {:ok, child} = ConversationStore.create("default", visibility: "internal")
    id = child["id"]

    assert {:ok, _} =
             ConversationTranscriptStore.append(id, %{
               "id" => "reply",
               "run_id" => "orphan",
               "role" => "assistant",
               "status" => "streaming",
               "content" => "saved"
             })

    assert {:error, :not_found} = ConversationTranscriptStore.list(id)
    assert :ok = TranscriptRecovery.recover(id)

    rows =
      Handbean.Storage.ConversationEntry
      |> where([entry], entry.conversation_id == ^id)
      |> order_by([entry], asc: entry.sequence)
      |> Handbean.Repo.all()

    assert [assistant, error] = rows
    assert assistant.status == "error"
    assert error.entry_id == "msg-run-error-orphan"
    assert {:error, :not_found} = ConversationTranscriptStore.list(id)
  end

  test "terminal closure affects only the selected run and unfinished entries", %{id: id} do
    for {entry_id, run_id, status} <- [
          {"other", "other-run", "running"},
          {"done", "broken", "done"},
          {"pending", "broken", "running"}
        ] do
      assert {:ok, _} =
               ConversationTranscriptStore.append(id, %{
                 "id" => entry_id,
                 "run_id" => run_id,
                 "role" => "tool",
                 "content_type" => "tool",
                 "tool_status" => status
               })
    end

    task =
      Task.async(fn ->
        TranscriptPersistence.handle_event(
          id,
          {:run_end, %{status: "error", error: "provider died"}},
          run_id: "broken"
        )
      end)

    assert :ok = Task.await(task)
    assert {:ok, [other, done, failed, error]} = ConversationTranscriptStore.list(id)
    assert other["tool_status"] == "running"
    assert done["tool_status"] == "done"
    assert failed["tool_status"] == "error"
    assert failed["tool_error"] == "provider died"
    assert error["run_id"] == "broken"
  end

  test "a live runner remains the lifecycle owner", %{id: id} do
    assert {:ok, _} =
             ConversationTranscriptStore.append(id, %{
               "id" => "reply",
               "run_id" => "live-run",
               "role" => "assistant",
               "status" => "streaming"
             })

    Registry.register(Handbean.AgentRunRegistry, id, %{run_id: "live-run"})
    assert :ok = TranscriptRecovery.recover(id)
    assert {:ok, [%{"status" => "streaming"}]} = ConversationTranscriptStore.list(id)
  end
end
