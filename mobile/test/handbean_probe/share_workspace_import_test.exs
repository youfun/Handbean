defmodule HandbeanProbe.ShareWorkspaceImportTest do
  use ExUnit.Case, async: false

  alias HandbeanProbe.{ShareConfirm, ShareIntake, ShareWorkspaceImport}

  setup do
    dir = Path.join(System.tmp_dir!(), "share_ws_#{System.unique_integer([:positive])}")
    workspace_path = Path.join(dir, "workspace")
    intake_root = Path.join(dir, "share_intake")
    File.mkdir_p!(workspace_path)
    File.mkdir_p!(intake_root)
    previous_host = Application.get_env(:handbean, :host)
    previous_root = Application.get_env(:handbean_probe, :share_intake_root)
    Handbean.Host.put!(%{data_dir: dir, shell: false, mcp: false})
    Application.put_env(:handbean_probe, :share_intake_root, intake_root)

    on_exit(fn ->
      if previous_host,
        do: Application.put_env(:handbean, :host, previous_host),
        else: Application.delete_env(:handbean, :host)

      if previous_root,
        do: Application.put_env(:handbean_probe, :share_intake_root, previous_root),
        else: Application.delete_env(:handbean_probe, :share_intake_root)

      File.rm_rf!(dir)
    end)

    %{dir: dir, workspace: %{"path" => workspace_path}, intake_root: intake_root}
  end

  test "confirmation copies staged files and merges rather than sending", %{
    workspace: workspace,
    intake_root: intake_root
  } do
    id = Ecto.UUID.generate()
    source_dir = Path.join(intake_root, id)
    File.mkdir_p!(source_dir)
    source = Path.join(source_dir, "notes.md")
    File.write!(source, "shared notes")

    rec = %{
      "intake_id" => id,
      "subject" => "",
      "text" => "请总结",
      "files" => [
        %{
          "status" => "ready",
          "name" => "notes.md",
          "path" => source,
          "size" => 12
        }
      ]
    }

    assert {:ok, paths} = ShareWorkspaceImport.accept(rec, workspace)
    assert paths == [".handbean/shared/#{id}/notes.md"]

    assert File.read!(Path.join(workspace["path"], ".handbean/shared/#{id}/notes.md")) ==
             "shared notes"

    draft = ShareWorkspaceImport.merge_draft("已有草稿", rec, paths)
    assert draft =~ "已有草稿\n\n请总结"
    assert draft =~ ".handbean/shared/#{id}/notes.md"
  end

  test "confirmation refuses a source path outside its staging request", %{
    dir: dir,
    workspace: workspace
  } do
    id = Ecto.UUID.generate()
    outside = Path.join(dir, "outside.txt")
    File.write!(outside, "do not import")

    rec = %{
      "intake_id" => id,
      "text" => "",
      "files" => [%{"status" => "ready", "name" => "outside.txt", "path" => outside}]
    }

    assert {:error, :copy_failed} = ShareWorkspaceImport.accept(rec, workspace)
    assert File.exists?(outside)
    refute File.exists?(Path.join(workspace["path"], ".handbean/shared/#{id}"))
  end

  test "confirmation refuses a shared-directory symlink outside the real workspace", %{
    dir: dir,
    workspace: workspace,
    intake_root: intake_root
  } do
    id = Ecto.UUID.generate()
    source_dir = Path.join(intake_root, id)
    File.mkdir_p!(source_dir)
    source = Path.join(source_dir, "notes.md")
    File.write!(source, "do not escape")

    outside = Path.join(dir, "other-workspace")
    File.mkdir_p!(outside)
    File.mkdir_p!(Path.join(workspace["path"], ".handbean"))
    File.ln_s!(outside, Path.join(workspace["path"], ".handbean/shared"))

    rec = %{
      "intake_id" => id,
      "text" => "",
      "files" => [%{"status" => "ready", "name" => "notes.md", "path" => source}]
    }

    assert {:error, _reason} = ShareWorkspaceImport.accept(rec, workspace)
    refute File.exists?(Path.join(outside, "#{id}/notes.md"))
  end

  test "confirmation does not claim or delete a pre-existing destination", %{
    workspace: workspace,
    intake_root: intake_root
  } do
    id = Ecto.UUID.generate()
    source_dir = Path.join(intake_root, id)
    File.mkdir_p!(source_dir)
    source = Path.join(source_dir, "notes.md")
    File.write!(source, "new")

    destination = ShareWorkspaceImport.destination(workspace, id)
    File.mkdir_p!(destination)
    sentinel = Path.join(destination, "keep.txt")
    File.write!(sentinel, "existing")

    rec = %{
      "intake_id" => id,
      "files" => [%{"status" => "ready", "name" => "notes.md", "path" => source}]
    }

    assert {:error, :copy_failed} = ShareWorkspaceImport.accept(rec, workspace)
    assert File.read!(sentinel) == "existing"
    refute File.exists?(Path.join(destination, "notes.md"))
  end

  test "duplicate target names fail without overwriting", %{
    workspace: workspace,
    intake_root: intake_root
  } do
    id = Ecto.UUID.generate()
    first_dir = Path.join([intake_root, id, "one"])
    second_dir = Path.join([intake_root, id, "two"])
    File.mkdir_p!(first_dir)
    File.mkdir_p!(second_dir)
    first = Path.join(first_dir, "same.txt")
    second = Path.join(second_dir, "same.txt")
    File.write!(first, "first")
    File.write!(second, "second")

    rec = %{
      "intake_id" => id,
      "files" => [
        %{"status" => "ready", "name" => "same.txt", "path" => first},
        %{"status" => "ready", "name" => "same.txt", "path" => second}
      ]
    }

    assert {:error, :copy_failed} = ShareWorkspaceImport.accept(rec, workspace)
    refute File.exists?(ShareWorkspaceImport.destination(workspace, id))
  end

  test "invalid intake id cannot widen rollback ownership", %{
    workspace: workspace
  } do
    shared = Path.join(workspace["path"], ".handbean/shared")
    File.mkdir_p!(shared)
    sentinel = Path.join(shared, "keep.txt")
    File.write!(sentinel, "keep")

    rec = %{"intake_id" => "..", "files" => []}

    assert {:error, :outside_workspace} = ShareWorkspaceImport.accept(rec, workspace)
    assert {:error, :outside_workspace} = ShareWorkspaceImport.rollback(workspace, "..")
    assert File.read!(sentinel) == "keep"
  end

  test "late success after cancel rolls back only owned dest", %{
    workspace: workspace,
    intake_root: intake_root
  } do
    id = Ecto.UUID.generate()
    user_file = Path.join(workspace["path"], "keep.txt")
    File.write!(user_file, "user")
    source_dir = Path.join(intake_root, id)
    File.mkdir_p!(source_dir)
    source = Path.join(source_dir, "notes.md")
    File.write!(source, "shared")

    write_fixture!(id, %{
      "state" => "cancelled",
      "consumption" => "workspace_copy",
      "text" => "x",
      "files" => [
        %{"status" => "ready", "name" => "notes.md", "path" => source, "size" => 6}
      ]
    })

    rec = elem(ShareIntake.get(id), 1)
    assert {:ok, _paths} = ShareWorkspaceImport.accept(rec, workspace)

    assert {:rollback, ^workspace, ^id, _} =
             ShareConfirm.finish_workspace(
               id,
               workspace,
               {:ok, [".handbean/shared/#{id}/notes.md"]}
             )

    assert {:ok, _} = ShareWorkspaceImport.schedule_rollback(workspace, id, notify: self())
    assert_receive {:share_rollback, ^id, :ok}, 1_000
    refute File.exists?(Path.join(workspace["path"], ".handbean/shared/#{id}"))
    assert File.read!(user_file) == "user"
  end

  test "failed copy returns intake to review", %{workspace: workspace} do
    id = Ecto.UUID.generate()

    write_fixture!(id, %{
      "state" => "confirming",
      "consumption" => "workspace_copy",
      "workspace_path" => workspace["path"],
      "text" => "x",
      "files" => []
    })

    assert {:failed, _rec, ^workspace, ^id} =
             ShareConfirm.finish_workspace(id, workspace, {:error, :copy_failed})

    assert {:ok, _} = ShareConfirm.schedule_rollback(workspace, id, notify: self())
    assert_receive {:share_rollback, ^id, :ok}, 1_000
    assert {:ok, %{"state" => "pending_review"}} = ShareIntake.get(id)
  end

  defp write_fixture!(id, rec) do
    dir = Path.join(ShareIntake.root(), id)
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "manifest.json"),
      Jason.encode!(Map.merge(%{"intake_id" => id}, rec))
    )
  end
end
