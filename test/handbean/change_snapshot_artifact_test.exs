defmodule Handbean.ChangeSnapshotArtifactTest do
  use Handbean.DataCase, async: false

  alias Handbean.{
    ChangeSnapshot,
    ConversationArtifacts,
    ConversationStore,
    ConversationTranscriptStore
  }

  alias Handbean.SessionStore.SQLite

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "handbean_snapshot_artifacts_#{System.unique_integer([:positive])}"
      )

    previous_root = Application.get_env(:handbean, :conversation_artifact_root)
    Application.put_env(:handbean, :conversation_artifact_root, root)

    on_exit(fn ->
      if previous_root,
        do: Application.put_env(:handbean, :conversation_artifact_root, previous_root),
        else: Application.delete_env(:handbean, :conversation_artifact_root)

      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "snapshots use private exclusive storage and reject unsafe ids and symlinks", %{root: root} do
    snapshot = snapshot("change-1")
    assert {:ok, ref} = ChangeSnapshot.persist(snapshot, %{conversation_id: "owner"})
    path = snapshot_path(root, "owner", "change-1")
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    assert Bitwise.band(File.stat!(Path.dirname(path)).mode, 0o777) == 0o700

    assert {:error, :eexist} =
             ChangeSnapshot.persist(snapshot("change-1"), %{conversation_id: "owner"})

    assert {:ok, %{"after_content" => "after"}} = ChangeSnapshot.load(ref)

    for id <- [".", "..", "../escape"] do
      assert {:error, :invalid_snapshot_id} =
               ChangeSnapshot.persist(snapshot, %{conversation_id: id})

      assert {:error, :invalid_snapshot_id} =
               ChangeSnapshot.persist(snapshot(id), %{conversation_id: "owner"})
    end

    target = Path.join(root, "target")
    File.write!(target, "secret")
    File.rm!(path)
    File.ln_s!(target, path)
    assert {:error, _} = ChangeSnapshot.load(ref)
    assert {:error, _} = ChangeSnapshot.delete_uncommitted(ref)
    assert File.read!(target) == "secret"

    File.ln_s!(Path.join([root, "items", "owner"]), Path.join([root, "items", "other"]))
    assert {:error, _} = ChangeSnapshot.persist(snapshot("another"), %{conversation_id: "other"})
  end

  test "snapshot writes share the artifact root lifecycle lock", %{root: root} do
    parent = self()

    holder =
      Task.async(fn ->
        ConversationArtifacts.persist_tool_result("content", %{conversation_id: "owner"},
          conversation_exists?: fn _ ->
            send(parent, {:artifact_lock_held, self()})

            receive do
              :release -> true
            after
              5_000 -> false
            end
          end
        )
      end)

    assert_receive {:artifact_lock_held, pid}

    writer =
      Task.async(fn ->
        ChangeSnapshot.persist(snapshot("locked"), %{conversation_id: "owner"})
      end)

    assert Task.yield(writer, 50) == nil
    send(pid, :release)
    assert {:ok, _} = Task.await(holder)
    assert {:ok, ref} = Task.await(writer)
    assert {:ok, _} = ChangeSnapshot.load(ref)
    assert File.exists?(snapshot_path(root, "owner", "locked"))
  end

  test "retention and capacity protect durable transcript and session references across conversations",
       %{root: root} do
    owner = "snapshot-owner"
    assert {:ok, _} = ConversationStore.create_free(id: "reference-holder")

    assert {:ok, transcript_ref} =
             ChangeSnapshot.persist(snapshot("transcript"), %{conversation_id: owner})

    assert {:ok, session_ref} =
             ChangeSnapshot.persist(snapshot("session"), %{conversation_id: owner})

    assert {:ok, orphan_ref} =
             ChangeSnapshot.persist(snapshot("orphan"), %{conversation_id: owner})

    assert {:ok, _} =
             ConversationTranscriptStore.append("reference-holder", %{
               "id" => "entry-1",
               "role" => "tool",
               "content_type" => "tool",
               "output" => %{
                 "nested" => [%{"change_snapshot_ref" => "prefix#{transcript_ref}suffix"}]
               }
             })

    assert :ok =
             SQLite.save("reference-holder", %{"extension_state" => %{"snapshot" => session_ref}})

    now = System.os_time(:second)

    for id <- ["transcript", "session", "orphan"] do
      touch(snapshot_path(root, owner, id), now - 10_000)
    end

    assert %{deleted: 0, failed: 0} =
             ConversationArtifacts.prune_change_snapshots(
               now: now,
               retention_seconds: 1,
               max_bytes: 0,
               min_retention_seconds: 0
             )

    assert {:ok, _} = ChangeSnapshot.load(orphan_ref)

    assert %{deleted: 1, failed: 0} =
             ConversationArtifacts.prune_change_snapshots(
               now: now,
               retention_seconds: 1,
               max_bytes: 0,
               min_retention_seconds: 0,
               no_pending_snapshot_publishers: true
             )

    assert {:ok, _} = ChangeSnapshot.load(transcript_ref)
    assert {:ok, _} = ChangeSnapshot.load(session_ref)
    assert {:error, :enoent} = ChangeSnapshot.load(orphan_ref)
    assert {:error, :snapshot_referenced} = ChangeSnapshot.delete_uncommitted(transcript_ref)
    assert {:error, :snapshot_referenced} = ChangeSnapshot.delete_uncommitted(session_ref)
  end

  test "cleanup retains active runs, removes old temporary files and enforces capacity", %{
    root: root
  } do
    now = System.os_time(:second)
    assert {:ok, _} = Registry.register(Handbean.AgentRunRegistry, "active", %{})

    assert {:ok, active} =
             ChangeSnapshot.persist(snapshot("active"), %{conversation_id: "active"})

    assert {:ok, oldest} = ChangeSnapshot.persist(snapshot("oldest"), %{conversation_id: "idle"})
    assert {:ok, recent} = ChangeSnapshot.persist(snapshot("recent"), %{conversation_id: "idle"})

    for {conversation, id, age} <- [
          {"active", "active", 500},
          {"idle", "oldest", 300},
          {"idle", "recent", 10}
        ] do
      touch(snapshot_path(root, conversation, id), now - age)
    end

    temp = snapshot_path(root, "idle", "recent") <> ".tmp-12345"
    File.write!(temp, "partial")
    touch(temp, now - 300)

    assert %{deleted: 1, failed: 0} =
             ConversationArtifacts.prune_change_snapshots(
               now: now,
               retention_seconds: 1,
               temporary_retention_seconds: 60,
               max_bytes: 0,
               min_retention_seconds: 0
             )

    assert {:ok, _} = ChangeSnapshot.load(oldest)
    refute File.exists?(temp)

    assert %{deleted: 1, failed: 0} =
             ConversationArtifacts.prune_change_snapshots(
               now: now,
               retention_seconds: 10_000,
               temporary_retention_seconds: 60,
               max_bytes: 0,
               min_retention_seconds: 100,
               no_pending_snapshot_publishers: true
             )

    assert {:ok, _} = ChangeSnapshot.load(active)
    assert {:ok, _} = ChangeSnapshot.load(recent)
    assert {:error, :enoent} = ChangeSnapshot.load(oldest)
    refute File.exists?(temp)
  end

  test "batch deletes once while protecting referenced and unsafe snapshots", %{root: root} do
    assert {:ok, _} = ConversationStore.create_free(id: "batch-reference-holder")
    assert {:ok, unused} = ChangeSnapshot.persist(snapshot("unused"), %{conversation_id: "owner"})
    assert {:ok, second} = ChangeSnapshot.persist(snapshot("second"), %{conversation_id: "owner"})

    assert {:ok, referenced} =
             ChangeSnapshot.persist(snapshot("referenced"), %{conversation_id: "owner"})

    assert {:ok, missing} =
             ChangeSnapshot.persist(snapshot("missing"), %{conversation_id: "owner"})

    assert {:ok, unsafe} = ChangeSnapshot.persist(snapshot("unsafe"), %{conversation_id: "owner"})
    assert :ok = File.rm(snapshot_path(root, "owner", "missing"))
    unsafe_path = snapshot_path(root, "owner", "unsafe")
    target = Path.join(root, "target")
    File.write!(target, "safe")
    File.rm!(unsafe_path)
    File.ln_s!(target, unsafe_path)

    assert {:ok, _} =
             ConversationTranscriptStore.append("batch-reference-holder", %{
               "id" => "batch-entry",
               "role" => "tool",
               "content_type" => "tool",
               "output" => %{"change_snapshot_ref" => referenced}
             })

    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:handbean, :repo, :query],
        &__MODULE__.record_batch_query/4,
        self()
      )

    try do
      assert [
               {^unused, :ok},
               {^referenced, {:error, :snapshot_referenced}},
               {^missing, {:error, :enoent}},
               {"invalid", {:error, :invalid_snapshot_ref}},
               {^second, :ok},
               {^unused, :ok},
               {^unsafe, {:error, _reason}}
             ] =
               ChangeSnapshot.delete_uncommitted_batch([
                 unused,
                 referenced,
                 missing,
                 "invalid",
                 second,
                 unused,
                 unsafe
               ])

      assert_receive {:batch_scan, :transcript}
      assert_receive {:batch_scan, :session}
      refute_receive {:batch_scan, _}, 0
    after
      :telemetry.detach(handler)
    end

    assert {:error, :enoent} = ChangeSnapshot.load(unused)
    assert {:error, :enoent} = ChangeSnapshot.load(second)
    assert {:ok, _} = ChangeSnapshot.load(referenced)
    assert File.read!(target) == "safe"
    assert [] == ChangeSnapshot.delete_uncommitted_batch([])
  end

  @doc false
  def record_batch_query(_event, _measurements, metadata, caller) do
    if self() == caller do
      query = Map.get(metadata, :query, "")

      cond do
        String.contains?(query, "FROM conversation_entries") ->
          send(caller, {:batch_scan, :transcript})

        String.contains?(query, "FROM session_snapshots") ->
          send(caller, {:batch_scan, :session})

        true ->
          :ok
      end
    end
  end

  test "scan failure prevents orphan cleanup and batch deletion but not temporary cleanup", %{
    root: root
  } do
    assert {:ok, ref} = ChangeSnapshot.persist(snapshot("keep"), %{conversation_id: "owner"})

    assert {:ok, second} =
             ChangeSnapshot.persist(snapshot("keep-two"), %{conversation_id: "owner"})

    path = snapshot_path(root, "owner", "keep")
    temp = path <> ".tmp-12345"
    File.write!(temp, "partial")
    touch(path, System.os_time(:second) - 100)
    touch(temp, System.os_time(:second) - 100)
    assert {:ok, _} = Handbean.Repo.query("DROP TABLE session_snapshots")

    assert %{deleted: 1, failed: 0} =
             ConversationArtifacts.prune_change_snapshots(
               retention_seconds: 0,
               temporary_retention_seconds: 0,
               max_bytes: 0,
               min_retention_seconds: 0
             )

    refute File.exists?(temp)

    assert %{deleted: 0, failed: 1} =
             ConversationArtifacts.prune_change_snapshots(
               retention_seconds: 0,
               max_bytes: 0,
               min_retention_seconds: 0,
               no_pending_snapshot_publishers: true
             )

    assert [{^ref, {:error, _}}, {^second, {:error, _}}] =
             ChangeSnapshot.delete_uncommitted_batch([ref, second])

    assert {:error, _} = ChangeSnapshot.delete_uncommitted(ref)
    assert {:ok, _} = ChangeSnapshot.load(ref)
    assert {:ok, _} = ChangeSnapshot.load(second)
  end

  test "explicit deletion removes only a newly created unreferenced snapshot" do
    assert {:ok, ref} = ChangeSnapshot.persist(snapshot("unused"), %{conversation_id: "owner"})
    assert :ok = ChangeSnapshot.delete_uncommitted(ref)
    assert {:error, :enoent} = ChangeSnapshot.load(ref)

    assert {:error, :invalid_snapshot_ref} =
             ChangeSnapshot.delete_uncommitted("change_snapshot:bad")
  end

  defp snapshot(id),
    do: ChangeSnapshot.build_write_snapshot("example.txt", "before", "after", change_id: id)

  defp snapshot_path(root, conversation, id),
    do: Path.join([root, "items", conversation, "change-snapshots", id <> ".json"])

  defp touch(path, seconds),
    do:
      File.touch!(
        path,
        seconds |> DateTime.from_unix!() |> DateTime.to_naive() |> NaiveDateTime.to_erl()
      )
end
