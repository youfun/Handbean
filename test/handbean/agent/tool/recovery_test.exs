defmodule Handbean.Agent.Tool.RecoveryTest do
  @moduledoc """
  Recovery boundary failures that cannot be exercised inside one Agent run:
  operation IDs must not collide across VM restarts, and retry_of must
  retain the original body while rejecting unavailable artifacts.
  """

  use Handbean.DataCase, async: false

  alias Handbean.Agent.OperationReceipt
  alias Handbean.Agent.Tool.{FileCommit, Result, ResultContract}
  alias Handbean.Platform.ProcessRunner.Invocation
  alias Handbean.Tool.Builtin.{Edit, Grep, Write}

  setup do
    root = Path.join(System.tmp_dir!(), "handbean-recovery-#{Ecto.UUID.generate()}")
    home = Path.join(root, "home")
    File.mkdir_p!(home)
    previous_home = System.get_env("HOME")
    previous_root = Application.get_env(:handbean, :conversation_artifact_root)
    System.put_env("HOME", home)
    Application.put_env(:handbean, :conversation_artifact_root, root)

    on_exit(fn ->
      if previous_home,
        do: System.put_env("HOME", previous_home),
        else: System.delete_env("HOME")

      if previous_root,
        do: Application.put_env(:handbean, :conversation_artifact_root, previous_root),
        else: Application.delete_env(:handbean, :conversation_artifact_root)

      File.rm_rf(root)
    end)

    %{root: root, workspace: Path.join(root, "workspace")}
  end

  test "saved input operation IDs stay distinct across VM restarts", %{root: root} do
    script = """
    [root, body] = System.argv()
    Application.put_env(:handbean, :conversation_artifact_root, root)
    context = %{}
    {:ok, _, id} = Handbean.Agent.Tool.SavedInput.prepare(
      "write", %{"file_path" => "note.txt", "content" => body}, context, ["file_path"]
    )
    IO.puts(id)
    """

    paths = Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin"))
    args = ["--erl", "+S 1:1"] ++ Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", script]

    ids =
      for body <- ["before restart", "after restart"] do
        {output, status} =
          System.cmd(System.find_executable("elixir"), args ++ [root, body],
            stderr_to_stdout: true
          )

        assert status == 0, output
        String.trim(output)
      end

    assert [before_id, after_id] = ids
    refute before_id == after_id
    assert Enum.all?(ids, &String.starts_with?(&1, "op_"))
  end

  test "retry_of reuses a large write without sending the body again", %{workspace: workspace} do
    File.mkdir_p!(workspace)
    body = String.duplicate("saved-body\n", 2_000)
    context = %{working_directory: workspace, conversation_id: "conv-retry"}

    File.mkdir_p!(Path.join(workspace, "blocked"))

    assert {:error, reason, details} =
             Write.execute(%{"file_path" => "blocked", "content" => body}, context)

    assert reason =~ "directory"
    assert details.operation_id
    retry = %{"retry_of" => details.operation_id, "file_path" => "inside.txt"}
    assert byte_size(Handbean.JSON.encode!(retry)) < 500
    assert {:ok, _text, meta} = Write.execute(retry, context)
    assert File.read!(Path.join(workspace, "inside.txt")) == body
    assert meta.side_effect == :committed
  end

  test "missing saved input artifact fails without writing empty content", %{
    root: root,
    workspace: workspace
  } do
    File.mkdir_p!(workspace)
    body = String.duplicate("saved-body\n", 2_000)
    context = %{working_directory: workspace, conversation_id: "conv-missing-artifact"}
    File.mkdir_p!(Path.join(workspace, "blocked"))

    assert {:error, _reason, details} =
             Write.execute(%{"file_path" => "blocked", "content" => body}, context)

    artifact_dir =
      Path.join([
        root,
        "items",
        "conv-missing-artifact",
        "tool-inputs",
        "write",
        details.operation_id
      ])

    assert [artifact] = Path.wildcard(Path.join(artifact_dir, "artifact_*"))
    File.rm!(artifact)

    assert {:error, reason, retry_details} =
             Write.execute(
               %{"retry_of" => details.operation_id, "file_path" => "recovered.txt"},
               context
             )

    assert reason =~ "artifact is unavailable"
    assert retry_details.code == :artifact_unavailable
    refute File.exists?(Path.join(workspace, "recovered.txt"))
  end

  test "edit retry reuses a large replacement and only overrides stale old text", %{
    workspace: workspace
  } do
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "edit.txt"), "current text\n")
    replacement = String.duplicate("replacement line\n", 1_000)
    context = %{working_directory: workspace, conversation_id: "conv-edit-retry"}

    assert {:error, reason, details} =
             Edit.execute(
               %{
                 "file_path" => "edit.txt",
                 "old_string" => "stale text",
                 "new_string" => replacement
               },
               context
             )

    assert reason =~ "Could not find text"

    retry = %{
      "retry_of" => details.operation_id,
      "file_path" => "edit.txt",
      "old_string" => "current text"
    }

    assert byte_size(Handbean.JSON.encode!(retry)) < 500
    assert {:ok, _text, meta} = Edit.execute(retry, context)
    assert meta.side_effect == :committed
    assert File.read!(Path.join(workspace, "edit.txt")) == replacement <> "\n"
  end

  test "declared large fields use opaque recovery artifacts", %{root: root, workspace: workspace} do
    File.mkdir_p!(workspace)
    artifact_root = Path.join(root, "field-artifacts")
    body = String.duplicate("saved-body\n", 2_000)

    context = %{
      working_directory: workspace,
      conversation_id: "conv-artifact-fields",
      tool_input_root: artifact_root
    }

    assert {:ok, _text, _details} =
             Write.execute(%{"file_path" => "inside.txt", "content" => body}, context)

    artifact_files =
      artifact_root
      |> Path.join("**/*")
      |> Path.wildcard(match_dot: true)
      |> Enum.filter(&File.regular?/1)

    assert [artifact] = artifact_files
    assert String.starts_with?(Path.basename(artifact), "artifact_")
    refute Path.basename(artifact) =~ "content"
    assert File.read!(artifact) == body
    assert {:ok, stat} = File.stat(artifact)
    assert Bitwise.band(stat.mode, 0o777) == 0o600
  end

  test "unknown large fields are rejected before artifact or receipt writes", %{
    root: root,
    workspace: workspace
  } do
    File.mkdir_p!(workspace)
    artifact_root = Path.join(root, "unknown-field-artifacts")
    body = String.duplicate("saved-body\n", 2_000)
    injected = String.duplicate("attacker-controlled\n", 1_000)
    malicious_key = "../../../../../escaped"

    context = %{
      working_directory: workspace,
      conversation_id: "conv-unknown-field",
      tool_input_root: artifact_root
    }

    assert {:error, reason, details} =
             Write.execute(
               %{"file_path" => "inside.txt", "content" => body, malicious_key => injected},
               context
             )

    assert reason =~ "unknown tool input fields"
    assert details.code == :input_rejected
    refute File.exists?(artifact_root)
    refute File.exists?(Path.join(workspace, "inside.txt"))
  end

  test "saved input rejects a symlinked artifact ancestor", %{root: root, workspace: workspace} do
    File.mkdir_p!(workspace)
    artifact_root = Path.join(root, "symlinked-artifacts")
    outside = Path.join(root, "artifact-escape")
    File.mkdir_p!(artifact_root)
    File.mkdir_p!(outside)
    File.ln_s!(outside, Path.join(artifact_root, "items"))
    body = String.duplicate("saved-body\n", 2_000)

    context = %{
      working_directory: workspace,
      conversation_id: "conv-artifact-symlink",
      tool_input_root: artifact_root
    }

    assert {:error, _reason, details} =
             Write.execute(%{"file_path" => "inside.txt", "content" => body}, context)

    assert details.code == :artifact_unavailable
    assert File.ls!(outside) == []
    refute File.exists?(Path.join(workspace, "inside.txt"))
  end

  test "file commit ignores a predictable retry temp symlink", %{root: root, workspace: workspace} do
    File.mkdir_p!(workspace)
    path = Path.join(workspace, "committed.txt")
    outside = Path.join(root, "outside.txt")
    operation_id = "known-operation"
    predictable_temp = path <> ".#{operation_id}.tmp"
    File.write!(outside, "outside")
    File.ln_s!(outside, predictable_temp)

    assert {:ok, commit} =
             FileCommit.commit(path, "expected", %{}, operation_id: operation_id)

    assert commit.side_effect == :committed
    assert File.read!(path) == "expected"
    assert File.read!(outside) == "outside"
    assert {:ok, ^outside} = File.read_link(predictable_temp)
  end

  test "file commit reconciles a matching target and refuses a mismatch", %{workspace: workspace} do
    File.mkdir_p!(workspace)
    path = Path.join(workspace, "committed.txt")
    assert {:ok, commit} = FileCommit.commit(path, "expected", %{conversation_id: "conv-commit"})

    assert {:ok, reconciled} =
             FileCommit.reconcile(path, commit.after_sha256, commit.operation_id)

    assert reconciled.side_effect == :committed
    File.write!(path, "changed-later")

    assert {:error, _reason, details} =
             FileCommit.reconcile(path, commit.after_sha256, commit.operation_id)

    assert details.side_effect == :unknown
  end

  test "bounded details never retain original content" do
    body = String.duplicate("x", 20_000)

    projected =
      ResultContract.project(Result.new(body, %{original_content: body, exit_code: 0}), [])

    encoded = Handbean.JSON.encode!(projected.details)
    refute encoded =~ body
    assert projected.details.exit_code == 0
  end

  test "invocation tail stays bounded while forwarding", %{workspace: workspace} do
    File.mkdir_p!(workspace)

    task =
      Task.async(fn ->
        Invocation.run(
          command: "printf '%1000000s' x",
          cwd: workspace,
          reply_to: self(),
          business_owner: self()
        )

        receive do
          {:invocation_result, _pid, result} -> result
        after
          5_000 -> :timeout
        end
      end)

    assert {:ok, output, _meta} = Task.await(task, 6_000)
    assert byte_size(output) < 80_000
  end

  test "invalid grep cursor does not restart at the first page", %{workspace: workspace} do
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "a.txt"), "marker\n")

    assert {:error, reason, details} =
             Grep.execute(
               %{"pattern" => "marker", "path" => ".", "cursor" => "not-a-cursor"},
               %{working_directory: workspace}
             )

    assert reason =~ "Omit cursor for a new query"
    assert reason =~ "next_cursor returned by the same query"
    assert details.code == :cursor_invalid
  end

  test "delegated usage records do not replace an existing child", %{root: _root} do
    conversation = "parent-usage"

    assert {:ok, _} =
             Handbean.ConversationStore.create("workspace", id: conversation, title: "parent")

    assert :ok =
             Handbean.ConversationStore.record_delegated_usage(conversation, "child-a", %{
               "input_tokens" => 3
             })

    assert :ok =
             Handbean.ConversationStore.record_delegated_usage(conversation, "child-b", %{
               "input_tokens" => 5
             })

    usage = Handbean.ConversationStore.delegated_usage(conversation)
    assert usage["child-a"]["input_tokens"] == 3
    assert usage["child-b"]["input_tokens"] == 5

    assert :ok =
             Handbean.ConversationStore.record_delegated_usage(conversation, "child-a", %{
               "input_tokens" => 99
             })

    assert Handbean.ConversationStore.delegated_usage(conversation)["child-a"]["input_tokens"] ==
             3

    assert OperationReceipt.fingerprint("same") == OperationReceipt.fingerprint("same")
  end
end
