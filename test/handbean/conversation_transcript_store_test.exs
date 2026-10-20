defmodule Handbean.ConversationTranscriptStoreTest do
  use Handbean.DataCase, async: false

  alias Handbean.{ConversationStore, ConversationTranscriptStore}

  setup do
    id = "transcript-#{System.unique_integer([:positive])}"
    {:ok, conversation} = ConversationStore.create("default", id: id)
    %{id: conversation["id"]}
  end

  test "public list and page use one existence read plus the entry query", %{id: id} do
    assert_queries(2, fn -> assert {:ok, []} = ConversationTranscriptStore.list(id) end)

    assert_queries(2, fn ->
      assert {:ok, %{entries: [], before: nil, has_more?: false}} =
               ConversationTranscriptStore.page(id)
    end)

    for entry <- ["first", "second"] do
      assert {:ok, _} = ConversationTranscriptStore.append(id, %{"id" => entry})
    end

    assert_queries(2, fn ->
      assert {:ok, [%{"id" => "first"}, %{"id" => "second"}]} =
               ConversationTranscriptStore.list(id)
    end)

    assert_queries(2, fn ->
      assert {:ok, %{entries: [%{"id" => "second"}], before: "second", has_more?: true}} =
               ConversationTranscriptStore.page(id, limit: 1)
    end)

    assert_queries(3, fn ->
      assert {:ok, %{entries: [%{"id" => "first"}], before: nil, has_more?: false}} =
               ConversationTranscriptStore.page(id, before: "second")
    end)
  end

  test "public transcript reads preserve persisted IDs outside metadata ID syntax" do
    for id <- ["n1:transcript", String.duplicate("t", 256)] do
      assert {:ok, _} = ConversationStore.create_free(id: id)

      assert {:ok, _} =
               ConversationTranscriptStore.append(id, %{"id" => "saved", "content" => id})

      assert_queries(2, fn ->
        assert {:ok, [%{"id" => "saved", "content" => ^id}]} =
                 ConversationTranscriptStore.list(id)
      end)

      assert_queries(2, fn ->
        assert {:ok,
                %{entries: [%{"id" => "saved", "content" => ^id}], before: nil, has_more?: false}} =
                 ConversationTranscriptStore.page(id)
      end)
    end
  end

  test "registered internal runtime reads preserve persisted IDs outside metadata ID syntax" do
    id = "n1:internal-transcript"
    assert {:ok, _} = ConversationStore.create_free(id: id, visibility: "internal")
    assert {:ok, _} = ConversationTranscriptStore.append(id, %{"id" => "private"})
    {:ok, _} = Registry.register(Handbean.AgentRunRegistry, id, %{run_id: "internal-run"})
    opts = [run_id: "internal-run", runner_pid: self()]

    assert_queries(2, fn ->
      assert {:ok, [%{"id" => "private"}]} = ConversationTranscriptStore.list(id, opts)
    end)

    assert_queries(2, fn ->
      assert {:ok, %{entries: [%{"id" => "private"}], before: nil, has_more?: false}} =
               ConversationTranscriptStore.page(id, opts)
    end)

    assert {:error, :not_found} = ConversationTranscriptStore.list(id)
    assert {:error, :not_found} = ConversationTranscriptStore.page(id)
  end

  test "missing and pending deletion reads stop after the existence query", %{id: id} do
    assert {:ok, _} = ConversationTranscriptStore.append(id, %{"id" => "hidden"})

    Handbean.Repo.get!(Handbean.Storage.Conversation, id)
    |> Ecto.Changeset.change(status: "pending_delete")
    |> Handbean.Repo.update!()

    for target <- [id, "missing-transcript"] do
      for operation <- [:list, :page] do
        assert_queries(1, fn ->
          assert {:error, :not_found} = apply(ConversationTranscriptStore, operation, [target])
        end)
      end
    end
  end

  test "internal reads require a live parent or the registered runtime reader", %{id: parent_id} do
    child_id = parent_id <> "-child"
    run_id = "parent-run"

    assert {:ok, _} =
             ConversationStore.create("default",
               id: child_id,
               visibility: "internal",
               parent_conversation_id: parent_id,
               parent_run_id: run_id
             )

    assert {:ok, _} = ConversationTranscriptStore.append(child_id, %{"id" => "private"})

    context = %{
      conversation_id: parent_id,
      run_id: run_id,
      runner_pid: self(),
      workspace_id: "default"
    }

    for operation <- [:list, :page] do
      assert_queries(2, fn ->
        assert {:error, :not_found} =
                 apply(ConversationTranscriptStore, operation, [
                   child_id,
                   [access_context: context]
                 ])
      end)
    end

    {:ok, _} =
      Registry.register(Handbean.AgentRunRegistry, parent_id, %{run_id: run_id, active?: true})

    on_exit(fn -> Registry.unregister(Handbean.AgentRunRegistry, parent_id) end)

    for operation <- [:list, :page] do
      assert_queries(3, fn ->
        assert {:ok, result} =
                 apply(ConversationTranscriptStore, operation, [
                   child_id,
                   [access_context: context]
                 ])

        entries = if operation == :list, do: result, else: result.entries
        assert [%{"id" => "private"}] = entries
      end)

      for invalid <- [
            %{context | workspace_id: "other"},
            %{context | run_id: "stale"},
            %{context | conversation_id: "other"}
          ] do
        assert {:error, :not_found} =
                 apply(ConversationTranscriptStore, operation, [
                   child_id,
                   [access_context: invalid]
                 ])
      end
    end

    Registry.unregister(Handbean.AgentRunRegistry, parent_id)
    {:ok, _} = Registry.register(Handbean.AgentRunRegistry, child_id, %{run_id: "child-run"})
    on_exit(fn -> Registry.unregister(Handbean.AgentRunRegistry, child_id) end)

    for operation <- [:list, :page] do
      assert_queries(2, fn ->
        assert {:ok, result} =
                 apply(ConversationTranscriptStore, operation, [
                   child_id,
                   [run_id: "child-run", runner_pid: self()]
                 ])

        entries = if operation == :list, do: result, else: result.entries
        assert [%{"id" => "private"}] = entries
      end)

      assert {:error, :not_found} =
               apply(ConversationTranscriptStore, operation, [
                 child_id,
                 [run_id: "wrong-run", runner_pid: self()]
               ])
    end

    runner_pid = self()

    Task.async(fn ->
      for operation <- [:list, :page] do
        assert {:error, :not_found} =
                 apply(ConversationTranscriptStore, operation, [
                   child_id,
                   [run_id: "child-run", runner_pid: runner_pid]
                 ])
      end
    end)
    |> Task.await()

    Handbean.Repo.get!(Handbean.Storage.Conversation, child_id)
    |> Ecto.Changeset.change(status: "pending_delete")
    |> Handbean.Repo.update!()

    for operation <- [:list, :page] do
      assert_queries(1, fn ->
        assert {:error, :not_found} =
                 apply(ConversationTranscriptStore, operation, [
                   child_id,
                   [run_id: "child-run", runner_pid: self()]
                 ])
      end)
    end
  end

  defp assert_queries(expected, operation) do
    ref = make_ref()
    handler = {__MODULE__, ref}

    :ok =
      :telemetry.attach(
        handler,
        [:handbean, :repo, :query],
        &__MODULE__.record_query/4,
        {self(), ref}
      )

    try do
      operation.()
      queries = collect_queries(ref, [])

      assert length(queries) == expected,
             "expected #{expected} queries, got #{length(queries)}: #{inspect(queries)}"
    after
      :telemetry.detach(handler)
    end
  end

  @doc false
  def record_query(_event, _measurements, metadata, {owner, ref}) do
    if self() == owner, do: send(owner, {ref, metadata.query})
  end

  defp collect_queries(ref, queries) do
    receive do
      {^ref, query} -> collect_queries(ref, [query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end

  test "append, list, and deep patch preserve envelope and payload fields", %{id: id} do
    assert {:ok, first} =
             ConversationTranscriptStore.append(id, %{
               "id" => "user",
               "role" => "user",
               "content" => "hello",
               "created_at" => "2026-10-15T12:57:08Z",
               "raw_content" => [%{"type" => "text", "text" => "hello"}]
             })

    assert first["sequence"] == 1
    assert first["revision"] == 1
    assert first["created_at"] == "2026-10-15T12:57:08Z"

    assert {:ok, _} =
             ConversationTranscriptStore.append(id, %{
               "id" => "assistant",
               "role" => "assistant",
               "content" => "hi",
               "status" => "streaming",
               "details" => %{"a" => 1}
             })

    assert {:ok, updated} =
             ConversationTranscriptStore.update(id, "assistant", %{
               "content" => %{"$append" => " there"},
               "status" => "final",
               "details" => %{"b" => 2}
             })

    assert updated["content"] == "hi there"
    assert updated["status"] == "final"
    assert updated["details"] == %{"a" => 1, "b" => 2}
    assert updated["revision"] == 2

    assert {:ok, entries} = ConversationTranscriptStore.list(id)
    assert Enum.map(entries, & &1["id"]) == ["user", "assistant"]
  end

  test "explicit canonical nil clears a legacy tool error", %{id: id} do
    assert {:ok, _} =
             ConversationTranscriptStore.append(id, %{
               "id" => "tool",
               "content_type" => "tool",
               "status" => "error",
               "error" => "legacy",
               "tool_status" => "running"
             })

    assert {:ok, updated} = ConversationTranscriptStore.update(id, "tool", %{"tool_error" => nil})
    assert Map.has_key?(updated, "tool_error")
    assert updated["tool_error"] == nil
    assert Handbean.TranscriptEntry.error(updated) == nil
  end

  test "duplicate ids fail without consuming a sequence", %{id: id} do
    assert {:ok, %{"sequence" => 1}} = ConversationTranscriptStore.append(id, %{"id" => "same"})
    assert {:error, :duplicate_id} = ConversationTranscriptStore.append(id, %{"id" => "same"})
    assert {:ok, %{"sequence" => 2}} = ConversationTranscriptStore.append(id, %{"id" => "next"})
  end

  test "pagination is bounded, chronological, and rejects a deleted cursor", %{id: id} do
    for index <- 1..6 do
      assert {:ok, _} = ConversationTranscriptStore.append(id, %{"id" => "entry-#{index}"})
    end

    assert {:ok, %{entries: newest, before: "entry-4", has_more?: true}} =
             ConversationTranscriptStore.page(id, limit: 3)

    assert Enum.map(newest, & &1["id"]) == ~w(entry-4 entry-5 entry-6)

    assert {:ok, %{entries: oldest, before: nil, has_more?: false}} =
             ConversationTranscriptStore.page(id, limit: 3, before: "entry-4")

    assert Enum.map(oldest, & &1["id"]) == ~w(entry-1 entry-2 entry-3)
    assert :ok = ConversationTranscriptStore.delete(id, "entry-4")
    assert {:error, :invalid_cursor} = ConversationTranscriptStore.page(id, before: "entry-4")
  end

  test "replace_all rebuilds sequence and next append position", %{id: id} do
    assert {:ok, _} = ConversationTranscriptStore.append(id, %{"id" => "old"})

    assert :ok =
             ConversationTranscriptStore.replace_all(id, [
               %{"id" => "new-a", "sequence" => 99},
               %{"id" => "new-b", "sequence" => 100}
             ])

    assert {:ok, [%{"id" => "new-a", "sequence" => 1}, %{"id" => "new-b", "sequence" => 2}]} =
             ConversationTranscriptStore.list(id)

    assert {:ok, %{"sequence" => 3}} = ConversationTranscriptStore.append(id, %{"id" => "new-c"})
  end

  test "concurrent appends allocate unique monotonic sequences", %{id: id} do
    tasks =
      for index <- 1..40 do
        Task.async(fn ->
          ConversationTranscriptStore.append(id, %{"id" => "entry-#{index}", "content" => index})
        end)
      end

    assert Enum.all?(Enum.map(tasks, &Task.await(&1, 5_000)), &match?({:ok, _}, &1))
    assert {:ok, entries} = ConversationTranscriptStore.list(id)
    assert Enum.map(entries, & &1["sequence"]) == Enum.to_list(1..40)
    assert MapSet.size(MapSet.new(entries, & &1["id"])) == 40
  end

  test "concurrent CAS append patches do not lose bytes", %{id: id} do
    assert {:ok, _} = ConversationTranscriptStore.append(id, %{"id" => "stream", "content" => ""})

    tasks =
      for _ <- 1..20 do
        Task.async(fn ->
          ConversationTranscriptStore.update(id, "stream", %{"content" => %{"$append" => "x"}})
        end)
      end

    assert Enum.all?(Enum.map(tasks, &Task.await(&1, 5_000)), &match?({:ok, _}, &1))

    assert {:ok, [%{"content" => content, "revision" => 21}]} =
             ConversationTranscriptStore.list(id)

    assert content == String.duplicate("x", 20)
  end

  test "consume patches inbound entries and moves them to the end in id order", %{id: id} do
    assert {:ok, _} = ConversationTranscriptStore.append(id, %{"id" => "queued"})
    assert {:ok, _} = ConversationTranscriptStore.append(id, %{"id" => "later"})
    assert {:ok, _} = ConversationTranscriptStore.append(id, %{"id" => "queued-2"})
    assert {:ok, _} = ConversationTranscriptStore.append(id, %{"id" => "tail"})

    assert :ok =
             ConversationTranscriptStore.consume(id, ["queued-2", "queued"], %{
               "consumption" => "consumed",
               "consumed_run_id" => "run-1"
             })

    assert {:ok, entries} = ConversationTranscriptStore.list(id)

    assert Enum.map(entries, & &1["id"]) == ["later", "tail", "queued-2", "queued"]
    assert Enum.map(entries, & &1["sequence"]) == [2, 4, 5, 6]

    queued = Enum.find(entries, &(&1["id"] == "queued"))
    assert queued["consumption"] == "consumed"
    assert queued["consumed_run_id"] == "run-1"
  end

  test "consume rolls back the batch when an id is missing", %{id: id} do
    assert {:ok, _} = ConversationTranscriptStore.append(id, %{"id" => "queued"})
    assert {:ok, _} = ConversationTranscriptStore.append(id, %{"id" => "later"})

    assert {:error, :not_found} =
             ConversationTranscriptStore.consume(id, ["queued", "missing"], %{
               "consumption" => "consumed"
             })

    assert {:ok, entries} = ConversationTranscriptStore.list(id)
    assert Enum.map(entries, & &1["id"]) == ["queued", "later"]
    assert Enum.map(entries, & &1["sequence"]) == [1, 2]
    refute Enum.any?(entries, &(&1["consumption"] == "consumed"))
  end

  test "delete is idempotent and missing conversations map to not_found", %{id: id} do
    assert {:ok, _} = ConversationTranscriptStore.append(id, %{"id" => "remove"})
    assert :ok = ConversationTranscriptStore.delete(id, "remove")
    assert :ok = ConversationTranscriptStore.delete(id, "remove")
    assert {:ok, []} = ConversationTranscriptStore.list(id)

    assert {:error, :not_found} = ConversationTranscriptStore.list("missing")
    assert {:error, :not_found} = ConversationTranscriptStore.append("missing", %{"id" => "x"})
    assert {:error, :not_found} = ConversationTranscriptStore.replace_all("missing", [])
  end
end
