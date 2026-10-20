defmodule Handbean.Memory.ProvenanceTest do
  use Handbean.DataCase

  import Ecto.Query

  alias Handbean.Memory.{Engram, EngramEvent, EngramProvenance, MemoryStore}
  alias Handbean.Repo
  alias Handbean.Storage.{Conversation, ConversationEntry}

  @workspace_id "memory-provenance-workspace"
  @scope_opts [memory_scope: :workspace, workspace_id: @workspace_id]

  describe "transactional event history" do
    test "create, semantic update, no-op update, and reinforce record the right revisions" do
      assert {:ok, engram} = MemoryStore.learn("Original", :fact, @scope_opts)
      assert engram.revision == 1
      assert [%EngramEvent{kind: :created, actor: :system, engram_revision: 1}] = events(engram)

      assert {:ok, unchanged} =
               MemoryStore.update(engram.id, %{content: "Original"}, @scope_opts)

      assert unchanged.revision == 1
      assert length(events(engram)) == 1

      assert {:ok, updated} =
               MemoryStore.update(engram.id, %{content: "Corrected", kind: :rule}, @scope_opts)

      assert updated.revision == 2
      assert updated.content == "Corrected"
      assert updated.kind == :rule

      assert {:ok, reinforced} = MemoryStore.reinforce(engram.id, @scope_opts)
      assert reinforced.revision == 2

      assert Enum.map(events(engram), &{&1.kind, &1.engram_revision}) == [
               {:created, 1},
               {:updated, 2},
               {:reinforced, 2}
             ]
    end

    test "idempotency keys make create and reinforce retries no-ops" do
      create_opts =
        Keyword.put(@scope_opts, :provenance, %{
          actor: :agent_tool,
          idempotency_key: "memory-create-once"
        })

      assert {:ok, first} = MemoryStore.learn("Only once", :fact, create_opts)
      assert {:ok, retried} = MemoryStore.learn("Only once", :fact, create_opts)
      assert retried.id == first.id
      assert Repo.aggregate(Engram, :count) == 1

      reinforce_opts =
        Keyword.put(@scope_opts, :provenance, %{
          actor: :agent_tool,
          idempotency_key: "memory-reinforce-once"
        })

      assert {:ok, once} = MemoryStore.reinforce(first.id, reinforce_opts)
      assert {:ok, twice} = MemoryStore.reinforce(first.id, reinforce_opts)
      assert once.reinforced_count == 1
      assert twice.reinforced_count == 1
      assert Repo.get!(Engram, first.id).reinforced_count == 1
    end

    test "idempotency fingerprints normalize atom and string map representations" do
      atom_opts =
        Keyword.put(@scope_opts, :provenance, %{
          actor: :agent_tool,
          idempotency_key: "normalized-create"
        })

      string_opts =
        Keyword.put(@scope_opts, :provenance, %{
          "actor" => "agent_tool",
          "idempotency_key" => "normalized-create"
        })

      assert {:ok, created} = MemoryStore.learn("Normalized create", :fact, atom_opts)
      assert {:ok, retried} = MemoryStore.learn("Normalized create", :fact, string_opts)
      assert retried.id == created.id

      atom_update_opts =
        Keyword.put(@scope_opts, :provenance, %{
          actor: :agent_tool,
          idempotency_key: "normalized-update"
        })

      string_update_opts =
        Keyword.put(@scope_opts, :provenance, %{
          "actor" => "agent_tool",
          "idempotency_key" => "normalized-update"
        })

      assert {:ok, updated} =
               MemoryStore.update(created.id, %{content: "Normalized update"}, atom_update_opts)

      assert {:ok, update_retry} =
               MemoryStore.update(
                 created.id,
                 %{"content" => "Normalized update"},
                 string_update_opts
               )

      assert update_retry.id == updated.id
      assert update_retry.revision == updated.revision
    end

    test "idempotency keys reject incompatible operation reuse" do
      opts =
        Keyword.put(@scope_opts, :provenance, %{
          actor: :agent_tool,
          idempotency_key: "operation-bound-key"
        })

      assert {:ok, engram} = MemoryStore.learn("Bound create", :fact, opts)
      assert {:error, :idempotency_conflict} = MemoryStore.reinforce(engram.id, opts)
      assert Repo.get!(Engram, engram.id).reinforced_count == 0

      assert {:error, :idempotency_conflict} =
               MemoryStore.learn("Different payload", :fact, opts)
    end

    test "a no-op update consumes its idempotency key without changing revision" do
      assert {:ok, engram} = MemoryStore.learn("Original", :fact, @scope_opts)

      no_op_opts =
        Keyword.put(@scope_opts, :provenance, %{
          actor: :agent_tool,
          idempotency_key: "no-op-update"
        })

      assert {:ok, unchanged} =
               MemoryStore.update(engram.id, %{content: "Original"}, no_op_opts)

      assert unchanged.revision == 1
      assert Enum.map(events(engram), & &1.kind) == [:created, :observed]

      assert {:ok, changed} =
               MemoryStore.update(engram.id, %{content: "Later change"}, @scope_opts)

      assert changed.revision == 2

      assert {:ok, retry} =
               MemoryStore.update(engram.id, %{content: "Original"}, no_op_opts)

      assert retry.content == "Later change"
      assert retry.revision == 2
      assert Repo.get!(Engram, engram.id).revision == 2
    end

    test "deleting an engram cascades its events and sources" do
      {conversation_id, [entry]} = conversation_with_entries([{"source", "source text"}])

      opts =
        provenance_opts(%{
          citations: [citation(conversation_id, entry)]
        })

      assert {:ok, engram} = MemoryStore.learn("With source", :fact, opts)
      [event] = events(engram)

      assert Repo.aggregate(from(p in EngramProvenance, where: p.event_id == ^event.id), :count) ==
               1

      assert {:ok, _} = MemoryStore.delete(engram.id, @scope_opts)
      assert Repo.aggregate(from(e in EngramEvent, where: e.engram_id == ^engram.id), :count) == 0
      assert Repo.aggregate(EngramProvenance, :count) == 0
    end

    test "source entry foreign keys are returned as changeset errors" do
      assert {:ok, engram} = MemoryStore.learn("Foreign key owner", :fact, @scope_opts)
      [event] = events(engram)

      attrs = %{
        event_id: event.id,
        relation: :citation,
        source_kind: :entry,
        source_workspace_id: @workspace_id,
        source_conversation_id: "missing-conversation",
        start_conversation_entry_id: 999_999_991,
        end_conversation_entry_id: 999_999_992,
        start_entry_id: "missing-start",
        start_sequence: 1,
        start_revision: 1,
        end_entry_id: "missing-end",
        end_sequence: 1,
        end_revision: 1,
        member_count: 1,
        anchor_digest: String.duplicate("0", 64),
        fidelity: :exact
      }

      changeset = EngramProvenance.changeset(%EngramProvenance{}, attrs)

      assert Enum.any?(
               changeset.constraints,
               &(&1.type == :foreign_key and &1.field == :start_conversation_entry_id)
             )

      assert Enum.any?(
               changeset.constraints,
               &(&1.type == :foreign_key and &1.field == :end_conversation_entry_id)
             )
    end

    test "source changesets reject a sequence range whose end precedes its start" do
      changeset =
        EngramProvenance.changeset(%EngramProvenance{}, %{
          event_id: 1,
          relation: :citation,
          source_kind: :entry_range,
          source_workspace_id: @workspace_id,
          source_conversation_id: "conversation",
          start_entry_id: "later",
          start_sequence: 2,
          start_revision: 1,
          end_entry_id: "earlier",
          end_sequence: 1,
          end_revision: 1,
          member_count: 2,
          anchor_digest: String.duplicate("0", 64),
          fidelity: :exact
        })

      refute changeset.valid?

      assert {"must be greater than or equal to start sequence", _opts} =
               changeset.errors[:end_sequence]
    end
  end

  describe "trigger compatibility and concurrent idempotency" do
    test "non-source trigger contexts do not block learn, update, or reinforce" do
      free_conversation_id = "free-trigger-#{Ecto.UUID.generate()}"

      assert {:ok, _conversation} =
               Handbean.ConversationStore.create_free(id: free_conversation_id)

      assert {:ok, free_entry} =
               Handbean.ConversationTranscriptStore.append(free_conversation_id, %{
                 "id" => "free-trigger",
                 "role" => "user",
                 "content" => "free chat trigger"
               })

      global_trigger_opts = [
        memory_scope: :global,
        provenance: %{
          actor: :agent_tool,
          operation_conversation_id: free_conversation_id,
          trigger_entry_id: free_entry["id"]
        }
      ]

      assert {:ok, global} =
               MemoryStore.learn("Global from free chat", :fact, global_trigger_opts)

      assert [created] = events(global)
      assert created.operation_conversation_id == free_conversation_id
      assert [] == Repo.all(from p in EngramProvenance, where: p.event_id == ^created.id)

      {internal_conversation_id, [internal_entry]} =
        conversation_with_entries([{"internal-trigger", "internal trigger"}])

      from(conversation in Conversation, where: conversation.id == ^internal_conversation_id)
      |> Repo.update_all(set: [visibility: "internal"])

      assert {:ok, workspace_memory} =
               MemoryStore.learn("Before internal update", :fact, @scope_opts)

      update_opts =
        Keyword.put(@scope_opts, :provenance, %{
          actor: :agent_tool,
          operation_conversation_id: internal_conversation_id,
          trigger_entry_id: internal_entry["id"]
        })

      assert {:ok, updated} =
               MemoryStore.update(
                 workspace_memory.id,
                 %{content: "After internal update"},
                 update_opts
               )

      assert updated.content == "After internal update"
      assert Enum.map(events(updated), & &1.kind) == [:created, :updated]

      workspace_conversation_id = "global-trigger-#{Ecto.UUID.generate()}"

      assert {:ok, _conversation} =
               Handbean.ConversationStore.create(@workspace_id, id: workspace_conversation_id)

      assert {:ok, workspace_entry} =
               Handbean.ConversationTranscriptStore.append(workspace_conversation_id, %{
                 "id" => "global-trigger",
                 "role" => "user",
                 "content" => "workspace trigger for a global operation"
               })

      reinforce_opts = [
        memory_scope: :global,
        provenance: %{
          actor: :agent_tool,
          operation_conversation_id: workspace_conversation_id,
          trigger_entry_id: workspace_entry["id"]
        }
      ]

      assert {:ok, reinforced} = MemoryStore.reinforce(global.id, reinforce_opts)
      refute reinforced.short_term
      assert Enum.map(events(global), & &1.kind) == [:created, :reinforced]
    end

    test "an invalid trigger in an eligible conversation remains a transactional error" do
      {conversation_id, [_entry]} = conversation_with_entries([{"valid", "source"}])

      opts =
        provenance_opts(%{
          operation_conversation_id: conversation_id,
          trigger_entry_id: "missing-entry"
        })

      assert {:error, :invalid_provenance} = MemoryStore.learn("Invalid trigger", :fact, opts)
      assert Repo.aggregate(Engram, :count) == 0
    end

    test "concurrent retries with one idempotency key converge on one memory" do
      opts =
        Keyword.put(@scope_opts, :provenance, %{
          actor: :agent_tool,
          idempotency_key: "concurrent-create-#{Ecto.UUID.generate()}"
        })

      parent = self()

      tasks =
        for _ <- 1..2 do
          Task.async(fn ->
            send(parent, {:ready, self()})
            receive do: (:go -> MemoryStore.learn("Concurrent memory", :fact, opts))
          end)
        end

      task_pids =
        for _ <- 1..2 do
          assert_receive {:ready, task_pid}
          task_pid
        end

      Enum.each(task_pids, &send(&1, :go))

      assert [{:ok, first}, {:ok, second}] = Enum.map(tasks, &Task.await/1)
      assert first.id == second.id
      assert Repo.aggregate(Engram, :count) == 1
      assert Repo.aggregate(EngramEvent, :count) == 1
    end
  end

  describe "exact source validation and projection" do
    test "stores exact trigger and citation anchors without copying source content" do
      {conversation_id, [trigger, cited]} =
        conversation_with_entries([
          {"trigger", "private trigger text"},
          {"cited", "private cited text"}
        ])

      opts =
        provenance_opts(%{
          operation_conversation_id: conversation_id,
          operation_run_id: "run-1",
          operation_tool_call_id: "tool-1",
          trigger_entry_id: trigger["id"],
          citations: [citation(conversation_id, cited)],
          idempotency_key: "exact-source-create"
        })

      assert {:ok, engram} = MemoryStore.learn("Derived memory", :fact, opts)
      [event] = events(engram)
      assert event.actor == :agent_tool
      assert event.operation_conversation_id == conversation_id
      refute inspect(event) =~ "private trigger text"
      refute inspect(event) =~ "private cited text"

      sources =
        Repo.all(from p in EngramProvenance, where: p.event_id == ^event.id, order_by: p.id)

      assert Enum.map(sources, & &1.relation) == [:trigger, :citation]
      assert Enum.all?(sources, &(&1.fidelity == :exact))

      assert {:ok, [projection]} = MemoryStore.provenance(engram.id, @scope_opts)
      assert Enum.map(projection.sources, & &1.status) == [:available, :available]
      refute inspect(projection) =~ "private trigger text"
      refute Map.has_key?(projection, :operation_conversation_id)
    end

    test "rejects stale, cross-workspace, unsettled, and excessive citations transactionally" do
      {conversation_id, [entry]} = conversation_with_entries([{"source", "source"}])

      stale = put_in(citation(conversation_id, entry)["revision"], entry["revision"] + 1)

      assert {:error, :invalid_provenance} =
               MemoryStore.learn("Stale", :fact, provenance_opts(%{citations: [stale]}))

      {other_conversation_id, [other_entry]} =
        conversation_with_entries([{"other", "other"}], workspace_id: "another-workspace")

      assert {:error, :invalid_provenance} =
               MemoryStore.learn(
                 "Cross workspace",
                 :fact,
                 provenance_opts(%{citations: [citation(other_conversation_id, other_entry)]})
               )

      {running_conversation_id, [running]} =
        conversation_with_entries([{"running", "running"}], status: "streaming")

      assert {:error, :invalid_provenance} =
               MemoryStore.learn(
                 "Unsettled",
                 :fact,
                 provenance_opts(%{
                   citations: [citation(running_conversation_id, running)]
                 })
               )

      assert {:error, :too_many_citations} =
               MemoryStore.learn(
                 "Too many",
                 :fact,
                 provenance_opts(%{
                   citations: List.duplicate(citation(conversation_id, entry), 11)
                 })
               )

      assert Repo.aggregate(Engram, :count) == 0
    end

    test "accepts a separately trusted, valid reflector checkpoint and derives its coverage" do
      {conversation_id, [first, last]} =
        conversation_with_entries([{"first", "first"}, {"last", "last"}])

      checkpoint_attrs = %{
        "id" => "checkpoint",
        "content_type" => "model_compaction",
        "message_type" => "internal",
        "role" => "internal",
        "direction" => "internal",
        "version" => 1,
        "summary" => "summary",
        "first_entry_id" => first["id"],
        "covered_through_id" => last["id"],
        "source_count" => 2,
        "source_digest" => Handbean.Agent.CompactionCheckpoint.digest([first, last])
      }

      assert {:ok, checkpoint} =
               Handbean.ConversationTranscriptStore.append(conversation_id, checkpoint_attrs)

      opts =
        Keyword.put(@scope_opts, :provenance, %{
          actor: :reflector,
          checkpoint: checkpoint,
          trusted_checkpoint: true
        })

      assert {:ok, engram} = MemoryStore.learn("Reflected memory", :fact, opts)
      [event] = events(engram)
      assert event.actor == :reflector

      assert [%EngramProvenance{} = coverage] =
               Repo.all(from p in EngramProvenance, where: p.event_id == ^event.id)

      assert coverage.relation == :coverage
      assert coverage.source_kind == :checkpoint
      assert coverage.start_entry_id == first["id"]
      assert coverage.end_entry_id == last["id"]
      assert coverage.member_count == 2
    end

    test "batch projection uses bounded queries and matches single-memory projection" do
      {conversation_id, entries} =
        conversation_with_entries([
          {"batch-1", "one"},
          {"batch-2", "two"},
          {"batch-3", "three"}
        ])

      memories =
        Enum.map(entries, fn entry ->
          assert {:ok, memory} =
                   MemoryStore.learn(
                     "Batch source #{entry["id"]}",
                     :fact,
                     provenance_opts(%{citations: [citation(conversation_id, entry)]})
                   )

          memory
        end)

      {query_count, {:ok, batch}} =
        count_repo_queries(fn ->
          MemoryStore.provenance_many(Enum.map(memories, & &1.id), @scope_opts)
        end)

      assert query_count <= 5
      assert Map.keys(batch) |> Enum.sort() == Enum.map(memories, & &1.id) |> Enum.sort()

      for memory <- memories do
        assert {:ok, single} = MemoryStore.provenance(memory.id, @scope_opts)
        assert batch[memory.id] == single
      end
    end

    test "range digest detects an interior revision change" do
      {conversation_id, [first, middle, last]} =
        conversation_with_entries([
          {"first", "first"},
          {"middle", "middle"},
          {"last", "last"}
        ])

      range =
        citation(conversation_id, first)
        |> Map.merge(%{
          "end_entry_id" => last["id"],
          "end_sequence" => last["sequence"],
          "end_revision" => last["revision"]
        })

      assert {:ok, engram} =
               MemoryStore.learn(
                 "Range-derived",
                 :fact,
                 provenance_opts(%{citations: [range]})
               )

      assert {:ok, [%{sources: [%{status: :available, member_count: 3}]}]} =
               MemoryStore.provenance(engram.id, @scope_opts)

      from(entry in ConversationEntry,
        where: entry.conversation_id == ^conversation_id and entry.entry_id == ^middle["id"]
      )
      |> Repo.update_all(inc: [revision: 1])

      assert {:ok, [%{sources: [changed]}]} =
               MemoryStore.provenance(engram.id, @scope_opts)

      assert changed.status == :changed
      assert changed.member_count == 3
      refute Map.has_key?(changed, :conversation_id)
      refute Map.has_key?(changed, :start)
    end

    test "authorization dominates tombstone state for callers outside the source workspace" do
      {conversation_id, [entry]} = conversation_with_entries([{"source", "source"}])

      global_opts = [
        memory_scope: :global,
        workspace_id: @workspace_id,
        provenance: %{
          actor: :agent_tool,
          citations: [citation(conversation_id, entry)]
        }
      ]

      assert {:ok, engram} = MemoryStore.learn("Global sourced memory", :fact, global_opts)

      Repo.get_by!(ConversationEntry,
        conversation_id: conversation_id,
        entry_id: entry["id"]
      )
      |> Repo.delete!()

      assert {:ok, [%{sources: [source]}]} =
               MemoryStore.provenance(engram.id,
                 memory_scope: :global,
                 workspace_id: "unauthorized-workspace"
               )

      assert source.status == :inaccessible
      refute Map.has_key?(source, :conversation_id)
      refute Map.has_key?(source, :start)
    end

    test "entry deletion tombstones anchors and inaccessible sources suppress identifiers" do
      {conversation_id, [entry]} = conversation_with_entries([{"source", "source"}])

      assert {:ok, deleted_source_memory} =
               MemoryStore.learn(
                 "Deleted source",
                 :fact,
                 provenance_opts(%{citations: [citation(conversation_id, entry)]})
               )

      source_row =
        Repo.get_by!(ConversationEntry,
          conversation_id: conversation_id,
          entry_id: entry["id"]
        )

      Repo.delete!(source_row)

      assert {:ok, [%{sources: [deleted]}]} =
               MemoryStore.provenance(deleted_source_memory.id, @scope_opts)

      assert deleted.status == :deleted
      refute Map.has_key?(deleted, :conversation_id)
      refute Map.has_key?(deleted, :start)

      {hidden_conversation_id, [hidden_entry]} =
        conversation_with_entries([{"hidden", "hidden"}])

      assert {:ok, hidden_source_memory} =
               MemoryStore.learn(
                 "Hidden source",
                 :fact,
                 provenance_opts(%{
                   citations: [citation(hidden_conversation_id, hidden_entry)]
                 })
               )

      from(conversation in Conversation, where: conversation.id == ^hidden_conversation_id)
      |> Repo.update_all(set: [visibility: "internal"])

      assert {:ok, [%{sources: [inaccessible]}]} =
               MemoryStore.provenance(hidden_source_memory.id, @scope_opts)

      assert inaccessible.status == :inaccessible
      refute Map.has_key?(inaccessible, :conversation_id)
      refute inspect(inaccessible) =~ hidden_conversation_id

      Repo.get_by!(ConversationEntry,
        conversation_id: hidden_conversation_id,
        entry_id: hidden_entry["id"]
      )
      |> Repo.delete!()

      assert {:ok, [%{sources: [%{status: :inaccessible}]}]} =
               MemoryStore.provenance(hidden_source_memory.id, @scope_opts)

      from(conversation in Conversation, where: conversation.id == ^hidden_conversation_id)
      |> Repo.update_all(set: [visibility: "user", status: "pending_delete"])

      assert {:ok, [%{sources: [%{status: :inaccessible}]}]} =
               MemoryStore.provenance(hidden_source_memory.id, @scope_opts)
    end
  end

  defp provenance_opts(provenance) do
    Keyword.put(@scope_opts, :provenance, Map.put_new(provenance, :actor, :agent_tool))
  end

  defp citation(conversation_id, entry) do
    %{
      "conversation_id" => conversation_id,
      "entry_id" => entry["id"],
      "sequence" => entry["sequence"],
      "revision" => entry["revision"]
    }
  end

  defp conversation_with_entries(entries, opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id, @workspace_id)
    status = Keyword.get(opts, :status)
    conversation_id = "provenance-#{Ecto.UUID.generate()}"

    assert {:ok, _conversation} =
             Handbean.ConversationStore.create(workspace_id,
               id: conversation_id,
               title: "Provenance fixture"
             )

    persisted =
      Enum.map(entries, fn {entry_id, content} ->
        attrs =
          %{"id" => entry_id, "role" => "user", "content" => content}
          |> then(fn attrs -> if status, do: Map.put(attrs, "status", status), else: attrs end)

        assert {:ok, entry} =
                 Handbean.ConversationTranscriptStore.append(conversation_id, attrs)

        entry
      end)

    {conversation_id, persisted}
  end

  defp count_repo_queries(fun) do
    handler_id = "memory-provenance-query-count-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:handbean, :repo, :query],
        fn _event, _measurements, _metadata, pid -> send(pid, :repo_query) end,
        self()
      )

    try do
      result = fun.()
      {drain_query_messages(0), result}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_query_messages(count) do
    receive do
      :repo_query -> drain_query_messages(count + 1)
    after
      0 -> count
    end
  end

  defp events(engram) do
    Repo.all(from event in EngramEvent, where: event.engram_id == ^engram.id, order_by: event.id)
  end
end
