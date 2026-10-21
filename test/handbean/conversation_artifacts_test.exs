defmodule Handbean.ConversationArtifactsTest do
  use ExUnit.Case, async: false

  alias Handbean.ConversationArtifacts

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "handbean_conversation_artifacts_#{System.unique_integer([:positive])}"
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

  test "tool-result references are scoped to their conversation", %{root: root} do
    context = %{conversation_id: "conversation-a", conversation_artifact_root: root}
    content = "complete tool output"

    assert {:ok, ref} = persist_tool_result(content, context)
    assert ConversationArtifacts.tool_result_ref?(ref)
    assert {:ok, path} = tool_result_path(ref, context)
    assert File.read!(path) == content

    assert {:error, :enoent} =
             tool_result_path(ref, %{
               context
               | conversation_id: "conversation-b"
             })

    assert {:error, :invalid_artifact_ref} =
             tool_result_path(
               "conversation_artifact:tool-results/../secret",
               context
             )
  end

  test "concurrent identical spills publish one complete private artifact", %{root: root} do
    context = %{conversation_id: "concurrent", conversation_artifact_root: root}
    content = String.duplicate("concurrent output\n", 1_000)

    refs =
      1..20
      |> Task.async_stream(
        fn _ -> persist_tool_result(content, context) end,
        max_concurrency: 20,
        ordered: false
      )
      |> Enum.map(fn {:ok, {:ok, ref}} -> ref end)
      |> Enum.uniq()

    assert [ref] = refs
    assert {:ok, path} = tool_result_path(ref, context)
    assert File.read!(path) == content
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600

    for directory <- [
          root,
          Path.join(root, "items"),
          Path.join([root, "items", "concurrent"]),
          Path.dirname(path)
        ] do
      assert Bitwise.band(File.stat!(directory).mode, 0o777) == 0o700
    end

    assert Path.wildcard(Path.join(Path.dirname(path), "*.tmp")) == []
  end

  test "dot ids and symlinked conversation directories cannot escape ownership", %{root: root} do
    owner = %{conversation_id: "owner", conversation_artifact_root: root}
    attacker = %{conversation_id: "attacker", conversation_artifact_root: root}

    assert {:ok, ref} = persist_tool_result("owner output", owner)
    assert {:ok, owner_path} = tool_result_path(ref, owner)

    assert {:error, [{".", :invalid_conversation_id}]} =
             ConversationArtifacts.delete_items(["."])

    assert File.read!(owner_path) == "owner output"

    target = Path.join(Path.dirname(owner_path), "same-content-target.txt")
    File.write!(target, "owner output")
    File.rm!(owner_path)
    File.ln_s!(target, owner_path)

    assert {:error, :invalid_artifact_type} = persist_tool_result("owner output", owner)
    assert {:error, :invalid_artifact_type} = tool_result_path(ref, owner)

    attacker_root = Path.join([root, "items", "attacker"])
    File.ln_s!(Path.join([root, "items", "owner"]), attacker_root)

    assert {:error, :invalid_artifact_directory} = tool_result_path(ref, attacker)

    assert {:error, [{"attacker", :invalid_artifact_directory}]} =
             ConversationArtifacts.delete_items(["attacker"])

    assert File.read!(owner_path) == "owner output"
  end

  test "cleanup removes stale temporary files and never exposes partial spill content", %{
    root: root
  } do
    context = %{conversation_id: "cleanup-race", conversation_artifact_root: root}
    content = String.duplicate("complete\n", 1_000)
    now = System.os_time(:second)

    assert {:ok, ref} = persist_tool_result(content, context)
    assert {:ok, path} = tool_result_path(ref, context)

    temporary = path <> ".0123456789abcdef.tmp"
    File.write!(temporary, "abandoned")
    touch_posix(temporary, now - 3_600)

    assert %{deleted: 1, failed: 0} =
             ConversationArtifacts.prune_tool_results(
               root: root,
               now: now,
               retention_seconds: 10_000,
               temporary_retention_seconds: 60,
               max_bytes: 1_000_000,
               protect_active?: false
             )

    refute File.exists?(temporary)

    operations =
      Enum.flat_map(1..20, fn _iteration ->
        [
          {:write, fn -> persist_tool_result(content, context) end},
          {:prune,
           fn ->
             ConversationArtifacts.prune_tool_results(
               root: root,
               now: now + 20_000,
               retention_seconds: 1,
               temporary_retention_seconds: 1,
               max_bytes: 0,
               min_retention_seconds: 0,
               protect_active?: false
             )
           end},
          {:read, fn -> read_tool_result(ref, context) end}
        ]
      end)

    results =
      operations
      |> Task.async_stream(
        fn {kind, operation} -> {kind, operation.()} end,
        max_concurrency: 20,
        ordered: false,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    Enum.each(results, fn
      {:write, {:ok, ^ref}} -> :ok
      {:prune, %{failed: 0}} -> :ok
      {:read, {:ok, ^content}} -> :ok
      {:read, {:error, :enoent}} -> :ok
    end)

    case read_tool_result(ref, context) do
      {:ok, ^content} -> :ok
      {:error, :enoent} -> :ok
    end

    assert {:ok, ^ref} = persist_tool_result(content, context)
    parent = self()

    reader =
      Task.async(fn ->
        ConversationArtifacts.with_tool_result(ref, context, fn locked_path ->
          send(parent, {:artifact_read_locked, self()})

          receive do
            :release_artifact_read -> File.read(locked_path)
          after
            5_000 -> {:error, :barrier_timeout}
          end
        end)
      end)

    assert_receive {:artifact_read_locked, reader_pid}

    pruner =
      Task.async(fn ->
        ConversationArtifacts.prune_tool_results(
          root: root,
          now: now + 20_000,
          retention_seconds: 1,
          max_bytes: 0,
          min_retention_seconds: 0,
          protect_active?: false
        )
      end)

    assert Task.yield(pruner, 50) == nil
    send(reader_pid, :release_artifact_read)
    assert {:ok, ^content} = Task.await(reader)
    assert %{failed: 0} = Task.await(pruner)

    writer =
      Task.async(fn ->
        ConversationArtifacts.persist_tool_result(content, context,
          conversation_exists?: fn _conversation_id ->
            send(parent, {:artifact_write_locked, self()})

            receive do
              :release_artifact_write -> true
            after
              5_000 -> false
            end
          end
        )
      end)

    assert_receive {:artifact_write_locked, writer_pid}
    deleter = Task.async(fn -> ConversationArtifacts.delete_items(["cleanup-race"]) end)
    assert Task.yield(deleter, 50) == nil
    send(writer_pid, :release_artifact_write)
    assert {:ok, ^ref} = Task.await(writer)
    assert :ok = Task.await(deleter)
    assert {:error, :enoent} = read_tool_result(ref, context)
  end

  test "cleanup protects artifacts for an active conversation", %{root: root} do
    conversation_id = "active-cleanup"
    context = %{conversation_id: conversation_id, conversation_artifact_root: root}
    now = System.os_time(:second)

    assert {:ok, _value} = Registry.register(Handbean.AgentRunRegistry, conversation_id, %{})
    assert {:ok, ref} = persist_tool_result("active output", context)
    assert {:ok, path} = tool_result_path(ref, context)
    touch_posix(path, now - 10_000)

    assert %{deleted: 0, failed: 0, retained_bytes: 13} =
             ConversationArtifacts.prune_tool_results(
               root: root,
               now: now,
               retention_seconds: 1,
               max_bytes: 0,
               min_retention_seconds: 0
             )

    assert File.read!(path) == "active output"
  end

  test "an idle resident session does not exempt expired artifacts", %{root: root} do
    conversation_id = "idle-session-cleanup"
    context = %{conversation_id: conversation_id, conversation_artifact_root: root}
    now = System.os_time(:second)

    assert {:ok, _value} = Registry.register(Handbean.SessionRegistry, conversation_id, %{})
    assert {:ok, ref} = persist_tool_result("idle output", context)
    assert {:ok, path} = tool_result_path(ref, context)
    touch_posix(path, now - 10_000)

    assert %{deleted: 1, failed: 0, retained_bytes: 0} =
             ConversationArtifacts.prune_tool_results(
               root: root,
               now: now,
               retention_seconds: 1,
               max_bytes: 0,
               min_retention_seconds: 0
             )

    refute File.exists?(path)
  end

  test "retention removes expired spills and keeps recent spills", %{root: root} do
    now = System.os_time(:second)
    old_context = %{conversation_id: "old", conversation_artifact_root: root}
    recent_context = %{conversation_id: "recent", conversation_artifact_root: root}

    assert {:ok, old_ref} = persist_tool_result("old output", old_context)

    assert {:ok, recent_ref} =
             persist_tool_result("recent output", recent_context)

    assert {:ok, old_path} = tool_result_path(old_ref, old_context)

    assert {:ok, recent_path} =
             tool_result_path(recent_ref, recent_context)

    touch_posix(old_path, now - 31 * 24 * 60 * 60)
    touch_posix(recent_path, now - 29 * 24 * 60 * 60)

    assert %{deleted: 1, failed: 0, freed_bytes: 10, retained_bytes: 13} =
             ConversationArtifacts.prune_tool_results(
               root: root,
               now: now,
               retention_seconds: 30 * 24 * 60 * 60,
               max_bytes: 1_000,
               min_retention_seconds: 0
             )

    refute File.exists?(old_path)
    assert File.exists?(recent_path)
  end

  test "capacity cleanup removes oldest eligible spills but protects recent output", %{root: root} do
    now = System.os_time(:second)

    paths =
      Map.new(
        for {conversation_id, content, age} <- [
              {"oldest", "11111", 300},
              {"older", "22222", 200},
              {"recent", "33333", 10}
            ] do
          context = %{conversation_id: conversation_id, conversation_artifact_root: root}
          assert {:ok, ref} = persist_tool_result(content, context)
          assert {:ok, path} = tool_result_path(ref, context)
          touch_posix(path, now - age)
          {conversation_id, path}
        end
      )

    assert %{deleted: 1, failed: 0, freed_bytes: 5, retained_bytes: 10} =
             ConversationArtifacts.prune_tool_results(
               root: root,
               now: now,
               retention_seconds: 10_000,
               max_bytes: 10,
               min_retention_seconds: 100
             )

    refute File.exists?(Map.fetch!(paths, "oldest"))
    assert File.exists?(Map.fetch!(paths, "older"))
    assert File.exists?(Map.fetch!(paths, "recent"))
  end

  test "deleting conversations removes all of their artifacts", %{root: root} do
    first = %{conversation_id: "delete-a", conversation_artifact_root: root}
    second = %{conversation_id: "keep-b", conversation_artifact_root: root}

    assert {:ok, first_ref} = persist_tool_result("first", first)
    assert {:ok, second_ref} = persist_tool_result("second", second)
    assert {:ok, first_path} = tool_result_path(first_ref, first)
    assert {:ok, second_path} = tool_result_path(second_ref, second)

    assert :ok = ConversationArtifacts.delete_items(["delete-a"])
    refute File.exists?(first_path)
    assert File.exists?(second_path)
  end

  defp persist_tool_result(content, context) do
    ConversationArtifacts.persist_tool_result(content, context,
      conversation_exists?: fn _conversation_id -> true end
    )
  end

  defp tool_result_path(ref, context) do
    ConversationArtifacts.with_tool_result(ref, context, fn path -> {:ok, path} end)
  end

  defp read_tool_result(ref, context) do
    ConversationArtifacts.with_tool_result(ref, context, &File.read/1)
  end

  defp touch_posix(path, seconds) do
    datetime = seconds |> DateTime.from_unix!() |> DateTime.to_naive() |> NaiveDateTime.to_erl()
    File.touch!(path, datetime)
  end
end
