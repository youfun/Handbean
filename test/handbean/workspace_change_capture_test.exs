defmodule Handbean.WorkspaceChangeCaptureTest do
  use ExUnit.Case, async: false

  alias Handbean.ChangeSnapshot
  alias Handbean.WorkspaceChangeCapture

  setup do
    root =
      Path.join([
        File.cwd!(),
        "tmp",
        "handbean_workspace_capture_#{System.unique_integer([:positive])}"
      ])

    artifacts = Path.join(root, "artifacts")
    repo = Path.join(root, "repo")
    File.mkdir_p!(repo)

    previous = Application.fetch_env(:handbean, :conversation_artifact_root)
    Application.put_env(:handbean, :conversation_artifact_root, artifacts)

    git!(repo, ["init"])
    git!(repo, ["config", "user.email", "test@example.com"])
    git!(repo, ["config", "user.name", "Handbean Test"])
    File.write!(Path.join(repo, "tracked.txt"), "committed\n")
    File.write!(Path.join(repo, "untouched.txt"), "committed\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "fixture"])

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:handbean, :conversation_artifact_root, value)
        :error -> Application.delete_env(:handbean, :conversation_artifact_root)
      end

      File.rm_rf!(root)
    end)

    %{repo: repo}
  end

  test "records only files changed during the current tool execution", %{repo: repo} do
    tracked = Path.join(repo, "tracked.txt")
    untouched = Path.join(repo, "untouched.txt")
    created = Path.join(repo, "created.txt")

    File.write!(untouched, "dirty before\n")
    capture = WorkspaceChangeCapture.start(repo)

    File.write!(tracked, "changed by tool\n")
    File.write!(created, "created by tool\n")

    changes = WorkspaceChangeCapture.finish(capture, %{conversation_id: "capture-test"})

    assert Enum.sort(Enum.map(changes, &Path.basename(&1.file_path))) == [
             "created.txt",
             "tracked.txt"
           ]

    snapshots =
      Enum.map(changes, fn change ->
        assert {:ok, snapshot} = ChangeSnapshot.load(change.change_snapshot_ref)
        snapshot
      end)

    tracked_snapshot = Enum.find(snapshots, &String.ends_with?(&1["file_path"], "tracked.txt"))
    created_snapshot = Enum.find(snapshots, &String.ends_with?(&1["file_path"], "created.txt"))

    assert tracked_snapshot["before_content"] == "committed\n"
    assert tracked_snapshot["after_content"] == "changed by tool\n"
    assert created_snapshot["existed_before"] == false
    assert created_snapshot["after_content"] == "created by tool\n"
  end

  defp git!(cwd, args) do
    {output, status} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    assert status == 0, output
    output
  end
end
