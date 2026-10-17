defmodule Handbean.E2E.TranscriptDurabilityTest do
  @moduledoc "SQLite transcript durability checks that exercise public stores."

  use Handbean.DataCase, async: false

  alias Handbean.ConversationStore
  alias Handbean.ConversationTranscriptStore

  @moduletag :e2e
  @error_text "Run error: Host stopped before the run completed"

  test "the running VM's database ownership is visible to another OS process" do
    lock_path = Handbean.StorageLock.lock_path(Handbean.Repo.database_path())

    script = """
    import fcntl, sys
    handle = open(sys.argv[1], "a+")
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("BUSY")
        raise SystemExit(3)
    print("LOCKED")
    """

    {output, 3} =
      System.cmd(python3!(), ["-c", script, lock_path], stderr_to_stdout: true)

    assert output =~ "BUSY"
  end

  test "indexed recovery seals orphaned entries once and leaves completed runs unchanged" do
    orphan_id = unique_id("recovery-orphan")
    done_id = unique_id("recovery-done")
    assert {:ok, _} = ConversationStore.create("default", id: orphan_id)
    assert {:ok, _} = ConversationStore.create("default", id: done_id)

    assert {:ok, _} =
             ConversationTranscriptStore.append(orphan_id, %{
               "id" => "msg-assistant-orphan",
               "content_type" => "assistant_msg",
               "role" => "assistant",
               "status" => "streaming",
               "run_id" => "run-orphan",
               "content" => "partial tail"
             })

    assert {:ok, _} =
             ConversationTranscriptStore.append(done_id, %{
               "id" => "msg-assistant-done",
               "content_type" => "assistant_msg",
               "role" => "assistant",
               "status" => "completed",
               "run_id" => "run-done",
               "content" => "complete"
             })

    assert :ok = Handbean.Agent.TranscriptRecovery.recover(orphan_id)
    assert :ok = Handbean.Agent.TranscriptRecovery.recover(orphan_id)
    assert :ok = Handbean.Agent.TranscriptRecovery.recover(done_id)

    assert {:ok, orphan_entries} = ConversationTranscriptStore.list(orphan_id)
    assert Enum.count(orphan_entries, &(&1["id"] == "msg-run-error-run-orphan")) == 1

    sealed = Enum.find(orphan_entries, &(&1["id"] == "msg-assistant-orphan"))
    assert sealed["content"] == "partial tail"
    assert sealed["status"] == "error"
    assert Enum.any?(orphan_entries, &(&1["content"] == @error_text))

    assert {:ok, [completed]} = ConversationTranscriptStore.list(done_id)
    assert completed["status"] == "completed"
    assert completed["content"] == "complete"
  end

  test "a long streaming reply keeps all bytes, revision, cursor, and sequence state" do
    id = unique_id("long-stream")
    assert {:ok, _} = ConversationStore.create("default", id: id)

    assert {:ok, _} =
             ConversationTranscriptStore.append(id, %{
               "id" => "stream",
               "role" => "assistant",
               "status" => "streaming",
               "content" => "0"
             })

    for _ <- 1..300 do
      assert {:ok, _} =
               ConversationTranscriptStore.update(id, "stream", %{
                 "content" => %{"$append" => "x"}
               })
    end

    assert {:ok, [%{"content" => content, "revision" => 301}]} =
             ConversationTranscriptStore.list(id)

    assert content == "0" <> String.duplicate("x", 300)

    assert {:ok, %{entries: [%{"id" => "stream"}], has_more?: false}} =
             ConversationTranscriptStore.page(id, limit: 1)

    assert {:ok, %{"sequence" => 2}} =
             ConversationTranscriptStore.append(id, %{"id" => "after-stream"})
  end

  test "parallel writers allocate a complete unique timeline" do
    id = unique_id("parallel")
    assert {:ok, _} = ConversationStore.create("default", id: id)

    writers =
      for writer <- 1..6 do
        Task.async(fn ->
          for entry <- 1..10 do
            assert {:ok, _} =
                     ConversationTranscriptStore.append(id, %{
                       "id" => "msg-#{writer}-#{entry}",
                       "role" => "assistant",
                       "status" => "completed",
                       "content" => "writer #{writer} entry #{entry}"
                     })
          end
        end)
      end

    Task.await_many(writers, 30_000)
    assert {:ok, entries} = ConversationTranscriptStore.list(id)
    assert length(entries) == 60
    assert Enum.map(entries, & &1["sequence"]) == Enum.to_list(1..60)
    assert MapSet.size(MapSet.new(entries, & &1["id"])) == 60
  end

  defp python3! do
    System.find_executable("python3") ||
      raise "python3 is required for the transcript durability e2e"
  end

  defp unique_id(prefix),
    do: prefix <> "-" <> Integer.to_string(System.unique_integer([:positive]))
end
