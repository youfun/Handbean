defmodule Handbean.Permissions.ConversationModeTest do
  use Handbean.DataCase, async: false

  import Ecto.Query

  alias Handbean.ConversationStore
  alias Handbean.Permissions.ConversationMode
  alias Handbean.Repo
  alias Handbean.Storage.{ConversationPermissionChange, ConversationRun}

  test "workspace conversations default to smart approval and remain isolated" do
    {:ok, first} = ConversationStore.create("permission-workspace", id: "permission-first")
    {:ok, second} = ConversationStore.create("permission-workspace", id: "permission-second")

    assert ConversationMode.get(first) == :auto_review
    assert ConversationMode.get(second) == :auto_review

    assert {:ok, updated} = ConversationMode.update(first["id"], :yolo, source: :test)
    assert updated["permission_mode"] == "yolo"
    assert updated["permission_revision"] == 1
    assert ConversationMode.get(first["id"]) == :yolo
    assert ConversationMode.get(second["id"]) == :auto_review
  end

  test "new workspace conversations inherit the previous conversation mode" do
    {:ok, first} = ConversationStore.create("permission-workspace", id: "inherit-first")
    assert ConversationMode.get(first) == :auto_review

    assert {:ok, _} = ConversationMode.update(first["id"], :yolo, source: :test)

    {:ok, second} = ConversationStore.create("permission-workspace", id: "inherit-second")
    assert ConversationMode.get(second) == :yolo

    {:ok, explicit} =
      ConversationStore.create("permission-workspace",
        id: "inherit-explicit",
        permission_mode: "prompt"
      )

    assert ConversationMode.get(explicit) == :prompt

    {:ok, other_workspace} = ConversationStore.create("other-workspace", id: "inherit-other")
    assert ConversationMode.get(other_workspace) == :auto_review
  end

  test "inherit_from copies that conversation even when a later one changed" do
    {:ok, first} =
      ConversationStore.create("permission-workspace",
        id: "inherit-source",
        permission_mode: "prompt"
      )

    {:ok, later} = ConversationStore.create("permission-workspace", id: "inherit-later")
    assert ConversationMode.get(later) == :prompt
    assert {:ok, _} = ConversationMode.update(later["id"], :yolo, source: :test)

    {:ok, copied} =
      ConversationStore.create("permission-workspace",
        id: "inherit-copied",
        inherit_from: first["id"]
      )

    assert ConversationMode.get(copied) == :prompt
  end

  test "a live change atomically updates the preference, run projection, and audit event" do
    {:ok, conversation} =
      ConversationStore.create("permission-workspace",
        id: "permission-audit",
        permission_mode: "prompt"
      )

    assert :ok =
             ConversationStore.record_run_start(conversation["id"], %{
               run_id: "run-1",
               permission_mode: :prompt,
               permission_revision: 0,
               approval_mode: :prompt,
               approvals_reviewer: :user,
               permission_source: :conversation
             })

    assert {:ok, _metadata} =
             ConversationMode.update(conversation["id"], :yolo,
               run_id: "run-1",
               source: :test
             )

    assert %ConversationRun{} =
             run =
             Repo.get_by(ConversationRun,
               conversation_id: conversation["id"],
               run_id: "run-1"
             )

    assert run.initial_permission_mode == "prompt"
    assert run.initial_permission_revision == 0
    assert run.initial_approval_mode == "prompt"
    assert run.initial_approvals_reviewer == "user"
    assert run.permission_source == "conversation"
    assert run.current_permission_mode == "yolo"
    assert run.current_permission_revision == 1
    assert %DateTime{} = run.permission_changed_at

    assert [%ConversationPermissionChange{} = change] = Repo.all(ConversationPermissionChange)

    assert change.run_id == "run-1"
    assert change.from_mode == "prompt"
    assert change.to_mode == "yolo"
    assert change.source == "test"
    assert change.revision == 1

    assert {:ok, snapshot} =
             ConversationStore.trajectory_snapshot(conversation["id"], limit: 50)

    assert [captured] = snapshot.runs
    assert captured.initial_permission_mode == "prompt"
    assert captured.initial_permission_revision == 0
    assert captured.current_permission_mode == "yolo"
    assert captured.current_permission_revision == 1

    assert captured.permission_changes == [
             %{
               from: "prompt",
               to: "yolo",
               source: "test",
               revision: 1,
               changed_at: DateTime.to_iso8601(change.changed_at)
             }
           ]
  end

  test "a run claims committed revisions when it actually observes them" do
    {:ok, conversation} =
      ConversationStore.create("permission-workspace",
        id: "permission-observed",
        permission_mode: "prompt"
      )

    assert :ok =
             ConversationStore.record_run_start(conversation["id"], %{
               run_id: "run-observed",
               permission_mode: :prompt,
               permission_revision: 0,
               approval_mode: :prompt,
               approvals_reviewer: :user,
               permission_source: :conversation
             })

    assert {:ok, _metadata} = ConversationMode.update(conversation["id"], :yolo, source: :test)

    assert [%ConversationPermissionChange{run_id: nil, revision: 1}] =
             Repo.all(ConversationPermissionChange)

    assert :ok = ConversationMode.observe_run(conversation["id"], "run-observed")

    assert [%ConversationPermissionChange{run_id: "run-observed", revision: 1}] =
             Repo.all(ConversationPermissionChange)

    run =
      Repo.get_by!(ConversationRun,
        conversation_id: conversation["id"],
        run_id: "run-observed"
      )

    assert run.current_permission_mode == "yolo"
    assert run.current_permission_revision == 1
  end

  test "normal run end claims an unobserved committed change before closing" do
    {:ok, conversation} =
      ConversationStore.create("permission-workspace",
        id: "permission-end-claim",
        permission_mode: "prompt"
      )

    assert :ok =
             ConversationStore.record_run_start(conversation["id"], %{
               run_id: "run-end-claim",
               permission_source: :conversation
             })

    assert {:ok, _metadata} = ConversationMode.update(conversation["id"], :yolo, source: :test)

    assert [%ConversationPermissionChange{run_id: nil}] = Repo.all(ConversationPermissionChange)

    assert :ok =
             ConversationStore.record_run_end(conversation["id"], %{
               run_id: "run-end-claim",
               status: :completed,
               source: :test
             })

    assert [%ConversationPermissionChange{run_id: "run-end-claim"}] =
             Repo.all(ConversationPermissionChange)

    run =
      Repo.get_by!(ConversationRun,
        conversation_id: conversation["id"],
        run_id: "run-end-claim"
      )

    assert run.status == "completed"
    assert run.current_permission_mode == "yolo"
    assert run.current_permission_revision == 1
  end

  test "a recovery-sourced live run still settles its final observation" do
    {:ok, conversation} =
      ConversationStore.create("permission-workspace",
        id: "permission-live-recovery-run",
        permission_mode: "prompt"
      )

    assert :ok =
             ConversationStore.record_run_start(conversation["id"], %{
               run_id: "live-recovery-run",
               permission_source: :conversation
             })

    assert {:ok, _metadata} = ConversationMode.update(conversation["id"], :yolo, source: :test)

    assert :ok =
             ConversationStore.record_run_end(conversation["id"], %{
               run_id: "live-recovery-run",
               status: :completed,
               source: :recovery
             })

    assert [%ConversationPermissionChange{run_id: "live-recovery-run"}] =
             Repo.all(ConversationPermissionChange)

    run =
      Repo.get_by!(ConversationRun,
        conversation_id: conversation["id"],
        run_id: "live-recovery-run"
      )

    assert run.current_permission_mode == "yolo"
    assert run.current_permission_revision == 1
  end

  test "orphan recovery does not attach a post-restart change to a stale open run" do
    {:ok, conversation} =
      ConversationStore.create("permission-workspace",
        id: "permission-stale-run",
        permission_mode: "prompt"
      )

    assert :ok =
             ConversationStore.record_run_start(conversation["id"], %{
               run_id: "stale-run",
               permission_source: :conversation
             })

    assert {:ok, _metadata} = ConversationMode.update(conversation["id"], :yolo, source: :test)

    assert :ok =
             ConversationStore.record_run_end(conversation["id"], %{
               run_id: "stale-run",
               status: :error,
               source: :recovery,
               orphan_recovery?: true
             })

    assert [%ConversationPermissionChange{run_id: nil}] = Repo.all(ConversationPermissionChange)

    run =
      Repo.get_by!(ConversationRun,
        conversation_id: conversation["id"],
        run_id: "stale-run"
      )

    assert run.status == "error"
    assert run.current_permission_mode == "prompt"
    assert run.current_permission_revision == 0
  end

  test "delegated approval remains the run effective mode when preference changes" do
    {:ok, conversation} =
      ConversationStore.create("permission-workspace",
        id: "permission-delegated",
        permission_mode: "auto_review"
      )

    assert :ok =
             ConversationStore.record_run_start(conversation["id"], %{
               run_id: "run-delegated",
               permission_source: :conversation,
               delegated_approval: :yolo
             })

    assert :ok =
             ConversationStore.record_run_start(conversation["id"], %{
               run_id: "run-delegated",
               permission_source: :conversation,
               delegated_approval: :prompt
             })

    replayed =
      Repo.get_by!(ConversationRun,
        conversation_id: conversation["id"],
        run_id: "run-delegated"
      )

    assert replayed.delegated_approval == "yolo"
    assert replayed.current_permission_mode == "yolo"

    assert {:ok, _metadata} =
             ConversationMode.update(conversation["id"], :prompt,
               run_id: "run-delegated",
               source: :test
             )

    run =
      Repo.get_by!(ConversationRun,
        conversation_id: conversation["id"],
        run_id: "run-delegated"
      )

    assert run.initial_permission_mode == "yolo"
    assert run.delegated_approval == "yolo"
    assert run.current_permission_mode == "yolo"
    assert run.current_permission_revision == 1

    assert [%ConversationPermissionChange{from_mode: "auto_review", to_mode: "prompt"}] =
             Repo.all(ConversationPermissionChange)
  end

  test "run start linearizes its initial snapshot after an earlier coordinator read" do
    {:ok, conversation} =
      ConversationStore.create("permission-workspace",
        id: "permission-start-race",
        permission_mode: "prompt"
      )

    stale_start = %{
      run_id: "run-start-race",
      permission_mode: :prompt,
      permission_revision: 0,
      approval_mode: :prompt,
      approvals_reviewer: :user,
      permission_source: :conversation
    }

    assert {:ok, _metadata} =
             ConversationMode.update(conversation["id"], :yolo, source: :test)

    assert :ok = ConversationStore.record_run_start(conversation["id"], stale_start)

    run =
      Repo.get_by!(ConversationRun,
        conversation_id: conversation["id"],
        run_id: "run-start-race"
      )

    assert run.initial_permission_mode == "yolo"
    assert run.initial_permission_revision == 1
    assert run.initial_approval_mode == "yolo"
    assert run.initial_approvals_reviewer == "user"
    assert run.current_permission_mode == "yolo"
    assert run.current_permission_revision == 1

    assert [%ConversationPermissionChange{run_id: nil, revision: 1}] =
             Repo.all(ConversationPermissionChange)
  end

  test "revisions order changes and generic metadata writes cannot bypass the owner" do
    {:ok, conversation} =
      ConversationStore.create("permission-workspace",
        id: "permission-revisions",
        permission_mode: "prompt"
      )

    assert {:ok, _} = ConversationMode.update(conversation["id"], :auto_review, source: :test)
    assert {:ok, _} = ConversationMode.update(conversation["id"], :yolo, source: :test)

    assert Repo.all(
             from change in ConversationPermissionChange,
               order_by: [asc: change.revision],
               select: change.revision
           ) == [1, 2]

    assert {:error, :permission_mode_owned} =
             ConversationStore.update_meta(conversation["id"], permission_mode: "prompt")

    assert {:error, :permission_mode_owned} =
             ConversationStore.upsert(Map.put(conversation, "permission_mode", "prompt"))

    assert ConversationMode.get(conversation["id"]) == :yolo

    assert {:error, :invalid_mode} =
             ConversationStore.create("permission-workspace", permission_mode: "invalid")

    assert {:error, :invalid_mode} = ConversationStore.create_free(permission_mode: "yolo")
  end

  test "run start replay cannot inject delegation into a persisted nil fact" do
    {:ok, conversation} =
      ConversationStore.create("permission-workspace", permission_mode: "prompt")

    assert :ok =
             ConversationStore.record_run_start(conversation["id"], %{
               run_id: "run-nil-delegation",
               permission_source: :conversation
             })

    assert :ok =
             ConversationStore.record_run_start(conversation["id"], %{
               run_id: "run-nil-delegation",
               permission_source: :conversation,
               delegated_approval: :yolo
             })

    run =
      Repo.get_by!(ConversationRun,
        conversation_id: conversation["id"],
        run_id: "run-nil-delegation"
      )

    assert run.initial_permission_mode == "prompt"
    assert run.delegated_approval == nil
    assert run.current_permission_mode == "prompt"
    assert run.current_permission_revision == 0
  end

  test "run start replay does not overwrite its initial permission snapshot" do
    {:ok, conversation} =
      ConversationStore.create("permission-workspace", permission_mode: "prompt")

    assert :ok =
             ConversationStore.record_run_start(conversation["id"], %{
               run_id: "run-replay",
               permission_mode: :prompt,
               permission_revision: 0,
               approval_mode: :prompt,
               approvals_reviewer: :user,
               permission_source: :conversation
             })

    assert {:ok, _metadata} =
             ConversationMode.update(conversation["id"], :yolo,
               run_id: "run-replay",
               source: :test
             )

    assert :ok =
             ConversationStore.record_run_start(conversation["id"], %{
               run_id: "run-replay",
               permission_mode: :auto_review,
               permission_revision: 99,
               approval_mode: :auto,
               approvals_reviewer: :auto_review,
               permission_source: :conversation
             })

    run =
      Repo.get_by!(ConversationRun,
        conversation_id: conversation["id"],
        run_id: "run-replay"
      )

    assert run.initial_permission_mode == "prompt"
    assert run.initial_permission_revision == 0
    assert run.initial_approval_mode == "prompt"
    assert run.current_permission_mode == "yolo"
    assert run.current_permission_revision == 1
  end
end
