defmodule Handbean.WorkspaceChangeCaptureTest do
  use Handbean.DataCase, async: false

  alias Handbean.ChangeSnapshot
  alias Handbean.WorkspaceChangeCapture

  defmodule UncertainStore do
    def append(_conversation_id, _entry, _opts), do: exit(:timeout)
  end

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

    assert %{changes: changes, truncated: false, omitted_paths: 0} =
             WorkspaceChangeCapture.finish(capture, %{conversation_id: "capture-test"})

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

  test "bounds snapshots from a large concurrent untracked tree", %{repo: repo} do
    capture = WorkspaceChangeCapture.start(repo)
    stage = Path.join(repo, ".handbean-web-stage.fixture")
    File.mkdir_p!(stage)

    {output, status} =
      System.cmd("sh", [
        "-c",
        "i=1; while [ \"$i\" -le 1100 ]; do printf 'generated %s\\n' \"$i\" > \"$1/$i.txt\"; i=$((i+1)); done",
        "external-writer",
        stage
      ])

    assert status == 0, output

    result = WorkspaceChangeCapture.finish(capture, %{conversation_id: "capture-limit"})
    assert length(result.changes) == 32
    assert result.truncated
    assert result.omitted_paths == 1_068
    assert result.snapshot_bytes <= 8_000_000

    assert length(
             Path.wildcard(
               Path.join([
                 Application.fetch_env!(:handbean, :conversation_artifact_root),
                 "items",
                 "capture-limit",
                 "change-snapshots",
                 "*.json"
               ])
             )
           ) == 32
  end

  test "limits aggregate serialized snapshots and reports omitted paths", %{repo: repo} do
    capture = WorkspaceChangeCapture.start(repo)
    content = String.duplicate("0123456789", 35_000)

    for index <- 1..20 do
      File.write!(Path.join(repo, "large-#{index}.txt"), content)
    end

    result = WorkspaceChangeCapture.finish(capture, %{conversation_id: "capture-bytes"})
    assert result.truncated
    assert result.omitted_paths > 0
    assert result.snapshot_bytes <= 8_000_000
    assert length(result.changes) < 20

    assert Enum.all?(
             result.changes,
             &match?({:ok, _}, ChangeSnapshot.load(&1.change_snapshot_ref))
           )
  end

  test "does not treat omitted dirty baseline files as newly created", %{repo: repo} do
    for index <- 1..150 do
      File.write!(Path.join(repo, "dirty-#{index}.txt"), "before")
    end

    capture = WorkspaceChangeCapture.start(repo)
    File.write!(Path.join(repo, "dirty-99.txt"), "after")
    result = WorkspaceChangeCapture.finish(capture, %{conversation_id: "capture-baseline"})

    assert result.truncated
    assert result.omitted_paths > 0
    refute Enum.any?(result.changes, &String.ends_with?(&1.file_path, "dirty-99.txt"))
  end

  test "known failed transcript append removes newly created snapshots", %{repo: repo} do
    capture = WorkspaceChangeCapture.start(repo)
    File.write!(Path.join(repo, "append.txt"), "contents")
    context = %{conversation_id: "missing-capture-conversation", tool_call_id: "call"}
    result = WorkspaceChangeCapture.finish(capture, context)
    assert [%{change_snapshot_ref: ref}] = result.changes
    assert {:ok, _} = ChangeSnapshot.load(ref)

    result = WorkspaceChangeCapture.persist(result, context)
    assert [%{reversible: false, revert_status: "unavailable"}] = result.changes
    assert {:error, :enoent} = ChangeSnapshot.load(ref)
  end

  test "duplicate durable batch retains its original snapshots and discards retry snapshots", %{
    repo: repo
  } do
    conversation_id = "capture-real-#{System.unique_integer([:positive])}"
    assert {:ok, _} = Handbean.ConversationStore.create("default", id: conversation_id)
    context = %{conversation_id: conversation_id, tool_call_id: "same-call"}
    path = Path.join(repo, "duplicate.txt")

    capture = WorkspaceChangeCapture.start(repo)
    File.write!(path, "first")
    original = WorkspaceChangeCapture.finish(capture, context)
    assert [%{change_snapshot_ref: original_ref}] = original.changes

    assert %{changes: [%{change_snapshot_ref: ^original_ref}]} =
             WorkspaceChangeCapture.persist(original, context)

    capture = WorkspaceChangeCapture.start(repo)
    File.write!(path, "second")
    retry_result = WorkspaceChangeCapture.finish(capture, context)
    assert [%{change_snapshot_ref: retry_ref}] = retry_result.changes

    assert %{changes: [%{reversible: false}]} =
             WorkspaceChangeCapture.persist(retry_result, context)

    assert {:ok, _} = ChangeSnapshot.load(original_ref)
    assert {:error, :enoent} = ChangeSnapshot.load(retry_ref)
    assert {:ok, entries} = Handbean.ConversationTranscriptStore.list(conversation_id)
    assert length(entries) == 1
  end

  test "uncertain transcript append retains snapshots for later reconciliation", %{repo: repo} do
    capture = WorkspaceChangeCapture.start(repo)
    File.write!(Path.join(repo, "uncertain.txt"), "contents")
    context = %{conversation_id: "capture-uncertain", tool_call_id: "call"}
    result = WorkspaceChangeCapture.finish(capture, context)
    assert [%{change_snapshot_ref: ref}] = result.changes

    assert %{changes: [%{change_snapshot_ref: ^ref}]} =
             WorkspaceChangeCapture.persist(result, context, transcript_store: UncertainStore)

    assert {:ok, _} = ChangeSnapshot.load(ref)
  end

  defp git!(cwd, args) do
    {output, status} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    assert status == 0, output
    output
  end
end
