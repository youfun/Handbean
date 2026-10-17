defmodule HandbeanProbe.ShareCopyTest do
  use ExUnit.Case, async: false

  alias HandbeanProbe.{ShareCopy, ShareIntake}

  setup do
    root = Path.join(System.tmp_dir!(), "share_copy_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous = Application.get_env(:handbean_probe, :share_intake_root)
    Application.put_env(:handbean_probe, :share_intake_root, root)
    :ok = HandbeanProbe.ShareIntake.Lock.ensure_started()
    :ok = ShareCopy.ensure_started()

    on_exit(fn ->
      if previous,
        do: Application.put_env(:handbean_probe, :share_intake_root, previous),
        else: Application.delete_env(:handbean_probe, :share_intake_root)

      File.rm_rf!(root)
    end)

    workspace = %{
      "id" => "ws-1",
      "path" => Path.join(root, "workspace")
    }

    File.mkdir_p!(workspace["path"])
    %{root: root, workspace: workspace}
  end

  test "worker crash returns confirming to review and rolls back dest", %{workspace: workspace} do
    id = write_confirming!(workspace)
    dest = Path.join([workspace["path"], ".handbean", "shared", id])
    File.mkdir_p!(dest)
    File.write!(Path.join(dest, "partial.md"), "x")

    copy = fn _rec, _ws ->
      Process.exit(self(), :kill)
      {:ok, []}
    end

    assert {:ok, _} =
             ShareCopy.begin(id, rec!(id), workspace, self(), copy: copy, notify: self())

    assert_receive {:share_workspace_result,
                    %{intake_id: ^id, result: {:error, {:worker_down, _}}}},
                   1_000

    assert_receive {:share_rollback, ^id, :ok}, 1_000
    assert {:ok, %{"state" => "pending_review"}} = ShareIntake.get(id)
    refute File.exists?(dest)
  end

  test "owner death after success rolls back original dest not current draft", %{
    workspace: workspace
  } do
    id = write_confirming!(workspace)
    dest = Path.join([workspace["path"], ".handbean", "shared", id])
    parent = self()
    owner = spawn(fn -> receive do: (_ -> :ok) end)

    copy = fn _rec, ws ->
      send(parent, {:copy_waiting, self()})

      receive do
        :proceed ->
          File.mkdir_p!(Path.join([ws["path"], ".handbean", "shared", id]))
          File.write!(Path.join([ws["path"], ".handbean", "shared", id, "notes.md"]), "copied")
          {:ok, [".handbean/shared/#{id}/notes.md"]}
      end
    end

    assert {:ok, _} =
             ShareCopy.begin(id, rec!(id), workspace, owner, copy: copy, notify: self())

    assert_receive {:copy_waiting, copier}, 1_000
    Process.exit(owner, :kill)
    send(copier, :proceed)

    assert_receive {:share_copy_abandoned, %{intake_id: ^id, result: {:ok, _}}, _how}, 1_000
    assert_receive {:share_rollback, ^id, :ok}, 1_000
    refute File.exists?(dest)
    assert {:ok, %{"state" => "pending_review"}} = ShareIntake.get(id)
  end

  test "reconcile abandons confirming with no live worker", %{workspace: workspace} do
    id = write_confirming!(workspace)
    dest = Path.join([workspace["path"], ".handbean", "shared", id])
    File.mkdir_p!(dest)
    File.write!(Path.join(dest, "leftover.md"), "x")

    assert :ok = ShareCopy.reconcile(notify: self())
    assert_receive {:share_rollback, ^id, :ok}, 1_000
    assert {:ok, %{"state" => "pending_review"}} = ShareIntake.get(id)
    refute File.exists?(dest)
  end

  test "rollback stays unconfirmable until dest is gone so a new copy cannot share the dir", %{
    workspace: workspace
  } do
    id = write_confirming!(workspace)
    dest = Path.join([workspace["path"], ".handbean", "shared", id])
    parent = self()

    copy = fn _rec, ws ->
      File.mkdir_p!(Path.join([ws["path"], ".handbean", "shared", id]))
      File.write!(Path.join([ws["path"], ".handbean", "shared", id, "notes.md"]), "first")
      {:ok, [".handbean/shared/#{id}/notes.md"]}
    end

    rollback = fn ws, intake_id ->
      send(parent, {:rb_wait, self()})

      receive do
        :go -> HandbeanProbe.ShareWorkspaceImport.rollback(ws, intake_id)
      end
    end

    assert {:ok, _} =
             ShareCopy.begin(id, rec!(id), workspace, self(),
               copy: copy,
               rollback: rollback,
               notify: self()
             )

    assert_receive {:share_workspace_result, %{intake_id: ^id, result: {:ok, _}}}, 1_000
    assert {:error, :busy} = ShareCopy.begin(id, rec!(id), workspace, self(), copy: copy)
    assert {:error, :not_reviewable} = ShareIntake.confirm(id)

    assert {:ok, _} =
             ShareCopy.request_rollback(id, workspace, rollback: rollback, notify: self())

    assert_receive {:rb_wait, roller}, 1_000
    assert {:error, :busy} = ShareCopy.begin(id, rec!(id), workspace, self(), copy: copy)
    assert {:error, :not_reviewable} = ShareIntake.confirm(id)
    assert File.exists?(dest)

    send(roller, :go)
    assert_receive {:share_rollback, ^id, :ok}, 1_000
    refute File.exists?(dest)
    assert {:ok, %{"state" => "pending_review"}} = ShareIntake.get(id)
    assert {:ok, _} = ShareIntake.confirm(id)
  end

  test "reconcile does not turn a queued copy-done into worker_missing", %{workspace: workspace} do
    id = write_confirming!(workspace)
    dest = Path.join([workspace["path"], ".handbean", "shared", id])
    parent = self()

    copy = fn _rec, ws ->
      send(parent, {:copy_waiting, self()})

      receive do
        :proceed ->
          File.mkdir_p!(Path.join([ws["path"], ".handbean", "shared", id]))
          File.write!(Path.join([ws["path"], ".handbean", "shared", id, "notes.md"]), "copied")
          {:ok, [".handbean/shared/#{id}/notes.md"]}
      end
    end

    assert {:ok, task} =
             ShareCopy.begin(id, rec!(id), workspace, self(), copy: copy, notify: self())

    assert_receive {:copy_waiting, copier}, 1_000
    :sys.suspend(ShareCopy)

    on_exit(fn ->
      try do
        :sys.resume(ShareCopy)
      catch
        _, _ -> :ok
      end
    end)

    recon = spawn(fn -> send(parent, {:recon_done, ShareCopy.reconcile()}) end)
    send(copier, :proceed)
    ref = Process.monitor(task)
    assert_receive {:DOWN, ^ref, :process, _, _}, 1_000
    :sys.resume(ShareCopy)
    assert_receive {:recon_done, :ok}, 1_000

    assert_receive {:share_workspace_result, %{intake_id: ^id, result: {:ok, _}}}, 1_000
    assert {:ok, %{"copy_status" => "ok", "state" => "confirming"}} = ShareIntake.get(id)
    assert File.exists?(dest)
    _ = Process.exit(recon, :kill)
    _ = ShareCopy.ack(id)
  end

  test "owner death while awaiting ack rolls back instead of leaving copy_status ok", %{
    workspace: workspace
  } do
    id = write_confirming!(workspace)
    dest = Path.join([workspace["path"], ".handbean", "shared", id])
    owner = spawn(fn -> receive do: (_ -> :ok) end)

    copy = fn _rec, ws ->
      File.mkdir_p!(Path.join([ws["path"], ".handbean", "shared", id]))
      File.write!(Path.join([ws["path"], ".handbean", "shared", id, "notes.md"]), "copied")
      {:ok, [".handbean/shared/#{id}/notes.md"]}
    end

    assert {:ok, _} =
             ShareCopy.begin(id, rec!(id), workspace, owner, copy: copy, notify: self())

    assert_receive {:share_workspace_result, %{intake_id: ^id, result: {:ok, _}}}, 1_000
    assert {:ok, %{"copy_status" => "ok", "awaiting_ack" => true}} = ShareIntake.get(id)
    Process.exit(owner, :kill)
    assert_receive {:share_rollback, ^id, :ok}, 1_000
    refute File.exists?(dest)
    assert {:ok, %{"state" => "pending_review"}} = ShareIntake.get(id)
  end

  defp write_confirming!(workspace) do
    id = Ecto.UUID.generate()
    dir = Path.join(ShareIntake.root(), id)
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "manifest.json"),
      Jason.encode!(%{
        "intake_id" => id,
        "state" => "confirming",
        "consumption" => "workspace_copy",
        "workspace_path" => workspace["path"],
        "workspace_id" => workspace["id"],
        "text" => "x",
        "files" => []
      })
    )

    id
  end

  defp rec!(id) do
    {:ok, rec} = ShareIntake.get(id)
    rec
  end
end
