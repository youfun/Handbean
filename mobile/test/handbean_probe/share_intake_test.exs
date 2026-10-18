defmodule HandbeanProbe.ShareIntakeTest do
  use ExUnit.Case, async: false

  alias HandbeanProbe.ShareIntake

  setup do
    root = Path.join(System.tmp_dir!(), "share_intake_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous = Application.get_env(:handbean_probe, :share_intake_root)
    Application.put_env(:handbean_probe, :share_intake_root, root)

    dir = Path.join(System.tmp_dir!(), "share_host_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    host = Application.get_env(:handbean, :host)
    Handbean.Host.put!(%{data_dir: dir, shell: false, mcp: false})

    vars = %{
      "HANDBEAN_WORKSPACE" => Path.join(dir, "workspace"),
      "HANDBEAN_MODELS_FILE" => Path.join(dir, "models.json"),
      "HANDBEAN_WORKSPACES_FILE" => Path.join(dir, "workspaces.json"),
      "HANDBEAN_GLOBAL_SETTINGS_FILE" => Path.join(dir, "settings.json")
    }

    previous_env = Map.new(vars, fn {key, _} -> {key, System.get_env(key)} end)
    Enum.each(vars, fn {key, value} -> System.put_env(key, value) end)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:handbean_probe, :share_intake_root, previous),
        else: Application.delete_env(:handbean_probe, :share_intake_root)

      if host,
        do: Application.put_env(:handbean, :host, host),
        else: Application.delete_env(:handbean, :host)

      Enum.each(previous_env, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)

      File.rm_rf!(root)
      File.rm_rf!(dir)
    end)

    %{root: root}
  end

  test "list_review is bounded and ordered by created_at FIFO after seq reset" do
    older = Ecto.UUID.generate()
    newer = Ecto.UUID.generate()

    write_fixture!(older, %{
      "state" => "pending_review",
      "text" => "old",
      "created_seq" => 99,
      "created_at" => 10
    })

    write_fixture!(newer, %{
      "state" => "pending_review",
      "text" => "new",
      "created_seq" => 1,
      "created_at" => 20
    })

    assert [first, second] = ShareIntake.list_review()
    assert first["intake_id"] == older
    assert second["intake_id"] == newer

    ids =
      for i <- 1..10 do
        id = Ecto.UUID.generate()

        write_fixture!(id, %{
          "state" => "pending_review",
          "text" => "t#{i}",
          "attachments" => [],
          "created_seq" => i,
          "created_at" => 100 + i
        })

        id
      end

    listed = ShareIntake.list_review()
    assert length(listed) == ShareIntake.max_pending()
    assert hd(listed)["intake_id"] == older
    assert List.last(listed)["intake_id"] == Enum.at(ids, 5)
  end

  test "confirm does not send and second confirm of merged is rejected" do
    id = Ecto.UUID.generate()

    write_fixture!(id, %{
      "state" => "pending_review",
      "text" => "hello",
      "attachments" => [%{"attachment_id" => "a1", "source" => "share"}]
    })

    assert {:ok, rec} = ShareIntake.confirm(id)
    assert rec["text"] == "hello"
    assert :ok = ShareIntake.mark_merged(id)
    assert {:error, :not_reviewable} = ShareIntake.confirm(id)
  end

  test "confirm is a read-only reviewability guard; ShareConfirm.begin owns the transition" do
    id = Ecto.UUID.generate()

    write_fixture!(id, %{
      "state" => "pending_review",
      "consumption" => "structured_attachments",
      "text" => "guard",
      "attachments" => []
    })

    {:ok, before} = ShareIntake.get(id)
    assert {:ok, _} = ShareIntake.confirm(id)
    assert {:ok, _} = ShareIntake.confirm(id)
    assert {:ok, ^before} = ShareIntake.get(id)
    assert [%{"intake_id" => ^id}] = ShareIntake.list_review()

    assert {:ok, :structured, _} = HandbeanProbe.ShareConfirm.begin(id)
    assert {:ok, %{"state" => "merged_current_process"}} = ShareIntake.get(id)
    assert {:error, :not_reviewable} = ShareIntake.confirm(id)
    assert {:error, :not_reviewable} = HandbeanProbe.ShareConfirm.begin(id)
  end

  test "confirm rejects importing and received" do
    importing = Ecto.UUID.generate()
    received = Ecto.UUID.generate()
    write_fixture!(importing, %{"state" => "importing", "text" => "x", "attachments" => []})
    write_fixture!(received, %{"state" => "received", "text" => "y", "attachments" => []})
    assert {:error, :not_reviewable} = ShareIntake.confirm(importing)
    assert {:error, :not_reviewable} = ShareIntake.confirm(received)
  end

  test "discard removes files and UUID gate rejects traversal" do
    id = Ecto.UUID.generate()
    write_fixture!(id, %{"state" => "pending_review", "text" => "x"})
    root = ShareIntake.root()
    file = Path.join([root, id, "draft", "file"])
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, "bytes")
    assert :ok = ShareIntake.discard(id)
    refute File.exists?(Path.join(root, id))
    assert {:error, :invalid_intake_id} = ShareIntake.discard("../escape")
    assert {:error, :invalid_intake_id} = ShareIntake.get("not-a-uuid")

    assert {:error, :invalid_intake_id} =
             ShareIntake.write("once", %{"state" => "pending_review"})
  end

  test "mark_send_pending failure does not leave a half-written send" do
    ok = Ecto.UUID.generate()
    write_fixture!(ok, %{"state" => "merged_current_process", "text" => "ok"})
    missing = Ecto.UUID.generate()
    assert :ok = ShareIntake.mark_send_pending(ok, "inb-1", "conv-1")
    assert {:error, :not_found} = ShareIntake.mark_send_pending(missing, "inb-1", "conv-1")
    assert :ok = ShareIntake.revert_send(ok)
    assert {:ok, %{"state" => "merged_current_process"}} = ShareIntake.get(ok)
  end

  test "write returns mkdir and rename failures as tuples" do
    blocker = Path.join(System.tmp_dir!(), "share_block_#{System.unique_integer([:positive])}")
    File.write!(blocker, "not-a-dir")
    previous = Application.get_env(:handbean_probe, :share_intake_root)
    Application.put_env(:handbean_probe, :share_intake_root, blocker)
    id = Ecto.UUID.generate()
    assert {:error, _reason} = ShareIntake.write(id, %{"state" => "pending_review"})
    Application.put_env(:handbean_probe, :share_intake_root, previous)
    File.rm!(blocker)
  end

  test "lost send ack is outcome_unknown and does not acknowledge" do
    {:ok, workspace} = Handbean.WorkspaceStore.ensure_default!()
    {:ok, conv} = Handbean.ConversationStore.create(workspace["id"])
    id = Ecto.UUID.generate()

    write_fixture!(id, %{
      "state" => "send_pending",
      "send_attempt_id" => "inbound-missing",
      "conversation_id" => conv["id"],
      "text" => "ping"
    })

    assert ShareIntake.reconcile_send(%{
             "intake_id" => id,
             "state" => "send_pending",
             "send_attempt_id" => "inbound-missing",
             "conversation_id" => conv["id"]
           }) == :outcome_unknown

    assert {:ok, %{"state" => "outcome_unknown"}} = ShareIntake.get(id)
    refute ShareIntake.reconcile_send(%{"state" => "pending_review"}) == :acknowledged
  end

  test "explicit inbound ack cleans intake" do
    {:ok, workspace} = Handbean.WorkspaceStore.ensure_default!()
    {:ok, conv} = Handbean.ConversationStore.create(workspace["id"])

    {:ok, _} =
      Handbean.Agent.TranscriptPersistence.append_inbound(conv["id"], "shared", inbound_id: "ack-1")

    id = Ecto.UUID.generate()

    write_fixture!(id, %{
      "state" => "send_pending",
      "send_attempt_id" => "ack-1",
      "conversation_id" => conv["id"]
    })

    assert ShareIntake.reconcile_send(%{
             "intake_id" => id,
             "state" => "send_pending",
             "send_attempt_id" => "ack-1",
             "conversation_id" => conv["id"]
           }) == :acknowledged

    assert ShareIntake.terminal?(id)
    assert {:ok, %{"state" => "acknowledged"}} = ShareIntake.receipt(id)
    assert :ok = ShareIntake.cleanup_retry(id)
    assert {:error, :not_found} = ShareIntake.get(id)
    assert ShareIntake.terminal?(id)
  end

  test "cancel is not confirmable and cleanup retry is deterministic" do
    id = Ecto.UUID.generate()
    write_fixture!(id, %{"state" => "pending_review", "text" => "x"})
    assert :ok = ShareIntake.cancel(id)
    assert {:error, :not_reviewable} = ShareIntake.confirm(id)

    {:ok, agent} = Agent.start_link(fn -> 0 end)

    rm = fn dir ->
      n = Agent.get_and_update(agent, fn c -> {c + 1, c + 1} end)

      if n == 1 do
        {:error, :eacces}
      else
        File.rm_rf(dir)
      end
    end

    assert :ok = ShareIntake.cleanup_retry(id, rm: rm, attempts: 3)
    assert Agent.get(agent, & &1) == 2
    refute File.exists?(Path.join(ShareIntake.root(), id))
  end

  test "async cleanup notifies without sleep" do
    id = Ecto.UUID.generate()
    write_fixture!(id, %{"state" => "cancelled", "text" => "x"})
    assert {:ok, _} = ShareIntake.schedule_cleanup(id, notify: self())
    assert_receive {:share_cleanup, ^id, :ok}, 1_000
    refute File.exists?(Path.join(ShareIntake.root(), id))
    assert ShareIntake.terminal?(id)
  end

  test "cleanup after cancel leaves receipt so missing manifest is not unimported" do
    id = Ecto.UUID.generate()
    write_fixture!(id, %{"state" => "pending_review", "text" => "x"})
    assert :ok = ShareIntake.cancel(id)
    assert :ok = ShareIntake.cleanup_retry(id)
    refute File.exists?(Path.join(ShareIntake.root(), id))
    assert {:ok, %{"state" => "cancelled"}} = ShareIntake.receipt(id)
    assert {:error, :terminal} = ShareIntake.return_to_review(id)
    assert {:error, :terminal} = ShareIntake.write(id, %{"state" => "pending_review"})
  end

  test "restore_visible finds review without a ready notify" do
    id = Ecto.UUID.generate()

    write_fixture!(id, %{
      "state" => "pending_review",
      "text" => "dropped notify",
      "created_at" => 1,
      "created_seq" => 1
    })

    assert [%{"intake_id" => ^id}] = ShareIntake.restore_visible()
  end

  test "confirming recovery rolls back owned dest and returns to review" do
    {:ok, workspace} = Handbean.WorkspaceStore.ensure_default!()
    id = Ecto.UUID.generate()
    dest = Path.join([workspace["path"], ".handbean", "shared", id])
    File.mkdir_p!(dest)
    File.write!(Path.join(dest, "partial.md"), "tmp")
    user = Path.join(workspace["path"], "keep.txt")
    File.write!(user, "keep")

    write_fixture!(id, %{
      "state" => "confirming",
      "consumption" => "workspace_copy",
      "workspace_path" => workspace["path"],
      "text" => "x"
    })

    assert :ok = HandbeanProbe.ShareCopy.reconcile(notify: self(), abandon_all: true)
    assert_receive {:share_rollback, ^id, :ok}, 1_000
    assert {:ok, %{"state" => "pending_review"}} = ShareIntake.get(id)
    refute File.exists?(dest)
    assert File.read!(user) == "keep"
  end

  test "A confirming does not block B review" do
    a = Ecto.UUID.generate()
    b = Ecto.UUID.generate()

    write_fixture!(a, %{
      "state" => "confirming",
      "consumption" => "workspace_copy",
      "created_seq" => 1,
      "text" => "A"
    })

    write_fixture!(b, %{
      "state" => "pending_review",
      "consumption" => "workspace_copy",
      "created_seq" => 2,
      "text" => "B"
    })

    assert {:error, :not_reviewable} = ShareIntake.confirm(a)
    assert {:ok, rec} = ShareIntake.confirm(b)
    assert rec["text"] == "B"
    assert [%{"intake_id" => ^b}] = ShareIntake.list_review()
  end

  test "receipt write failure does not delete manifest and does not resurrect" do
    id = Ecto.UUID.generate()
    write_fixture!(id, %{"state" => "pending_review", "text" => "x"})
    Application.put_env(:handbean_probe, :share_receipt_write, fn _id, _state -> {:error, :eio} end)

    on_exit(fn -> Application.delete_env(:handbean_probe, :share_receipt_write) end)

    assert {:error, :eio} = ShareIntake.cancel(id)
    assert {:ok, %{"state" => "cancelled"}} = ShareIntake.get(id)
    assert {:error, :not_found} = ShareIntake.receipt(id)
    assert {:error, :eio} = ShareIntake.discard(id)
    assert {:ok, %{"state" => "cancelled"}} = ShareIntake.get(id)
    assert {:error, :terminal} = ShareIntake.write(id, %{"state" => "pending_review"})
    assert {:error, :not_reviewable} = ShareIntake.confirm(id)
  end

  test "ack receipt failure leaves manifest and skips cleanup" do
    id = Ecto.UUID.generate()
    write_fixture!(id, %{"state" => "merged_current_process", "text" => "x"})
    Application.put_env(:handbean_probe, :share_receipt_write, fn _id, _state -> {:error, :eio} end)

    on_exit(fn -> Application.delete_env(:handbean_probe, :share_receipt_write) end)

    assert {:error, :eio} = ShareIntake.acknowledge(id)
    assert {:ok, %{"state" => "acknowledged"}} = ShareIntake.get(id)
    assert {:error, :not_found} = ShareIntake.receipt(id)
    assert File.exists?(Path.join(ShareIntake.root(), id))
  end

  test "concurrent cancel and mark_merged never leave merged plus cancelled receipt" do
    id = Ecto.UUID.generate()
    write_fixture!(id, %{"state" => "pending_review", "text" => "x"})
    parent = self()

    t1 =
      Task.async(fn ->
        send(parent, {:started, :cancel})
        ShareIntake.cancel(id)
      end)

    t2 =
      Task.async(fn ->
        send(parent, {:started, :merge})
        ShareIntake.mark_merged(id)
      end)

    assert_receive {:started, :cancel}, 1_000
    assert_receive {:started, :merge}, 1_000
    r1 = Task.await(t1)
    r2 = Task.await(t2)
    {:ok, rec} = ShareIntake.get(id)
    receipt = ShareIntake.receipt(id)

    refute rec["state"] == "merged_current_process" and
             match?({:ok, %{"state" => "cancelled"}}, receipt)

    if rec["state"] == "cancelled" do
      assert {:ok, %{"state" => "cancelled"}} = receipt
      assert r1 == :ok or r2 == :ok
    end
  end

  test "root uses Host.data_dir when share_intake_root is unset" do
    Application.delete_env(:handbean_probe, :share_intake_root)
    assert ShareIntake.root() == Path.join(Handbean.Host.data_dir(), "share_intake")
  end

  defp write_fixture!(id, rec) do
    dir = Path.join(ShareIntake.root(), id)
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "manifest.json"),
      Jason.encode!(
        Map.merge(%{"intake_id" => id, "updated_at" => System.system_time(:millisecond)}, rec)
      )
    )
  end
end
