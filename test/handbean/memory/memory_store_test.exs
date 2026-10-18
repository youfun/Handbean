defmodule Handbean.Memory.MemoryStoreTest do
  @moduledoc """
  Tests for the memory store CRUD operations.

  Translated from: `cog-cli/memory.zig` test blocks
  - test "learn and recall"
  - test "reinforce short to long"
  - test "associate and connections"
  - test "learn duplicate detection" (translated as SQL unique constraint handling)
  - test "flush short-term" (translated as cleanup_expired)

  Uses Handbean.DataCase for DB sandbox isolation.
  """

  use Handbean.DataCase

  alias Handbean.Memory.{Engram, MemoryStore}

  @scope_opts [memory_scope: :workspace, workspace_id: "memory-store-test"]

  describe "learn/3 — creating engrams" do
    test "learn stores a fact engram" do
      {:ok, engram} = learn("User prefers snake_case naming", :preference)

      assert engram.content == "User prefers snake_case naming"
      assert engram.kind == :preference
      assert engram.short_term == true
      assert engram.expires_at != nil
      assert engram.reinforced_count == 0
    end

    test "learn sets expiry for short-term engrams" do
      {:ok, engram} = learn("Temporary fact", :fact, short_term: true)

      assert engram.short_term == true
      assert engram.expires_at != nil

      # Should expire ~24h from now
      diff = DateTime.diff(engram.expires_at, DateTime.utc_now())
      assert_in_delta diff, 86_400, 10
    end

    test "learn can create long-term engrams" do
      {:ok, engram} = learn("Important rule", :rule, short_term: false)

      assert engram.short_term == false
      assert engram.expires_at == nil
    end

    test "learn requires content and kind" do
      {:error, changeset} = learn("", :fact)
      assert changeset.errors[:content]

      {:error, changeset2} = learn("some content", nil)
      assert changeset2.errors[:kind]
    end

    test "learn stores metadata" do
      {:ok, engram} = learn("Fact with meta", :fact, metadata: %{source: "test"})
      assert engram.metadata.source == "test"
    end
  end

  describe "recall/2 — searching engrams" do
    test "recall finds engrams by content match" do
      {:ok, _} = learn("Project uses Phoenix framework", :fact, short_term: false)
      {:ok, _} = learn("User prefers tabs over spaces", :preference)

      results = recall("Phoenix")
      assert length(results) >= 1

      matched = Enum.find(results, &(&1.content =~ "Phoenix"))
      assert matched != nil
    end

    test "recall respects limit" do
      # Fill with several engrams
      for i <- 1..5 do
        {:ok, _} = learn("Data point #{i}", :fact, short_term: false)
      end

      results = recall("Data point", limit: 2)
      assert length(results) <= 2
    end

    test "recall filters out expired engrams" do
      # Create an expired engram directly (truncate microseconds for SQLite3 compat)
      expired_dt =
        DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

      expired = %Engram{
        content: "Expired data",
        kind: :fact,
        short_term: true,
        expires_at: expired_dt
      }

      {:ok, expired_engram} =
        expired
        |> Handbean.Repo.insert()

      results = recall("Expired data")

      # Expired engrams should not appear in results
      expired_ids = Enum.map(results, & &1.id)
      refute expired_engram.id in expired_ids
    end

    test "recall returns empty for no match" do
      results = recall("xyznonexistent98765")
      assert results == []
    end

    test "recall orders by long-term first, then reinforced count" do
      {:ok, _lt} = learn("Recall ordered: long-term", :fact, short_term: false)
      {:ok, _st} = learn("Recall ordered: short-term", :fact, short_term: true)

      results = recall("Recall ordered")
      assert length(results) >= 2

      # Long-term should come first
      first = List.first(results)
      assert first.short_term == false
    end
  end

  describe "reinforce/1 — promoting to long-term" do
    test "reinforce promotes short-term to long-term memory" do
      {:ok, engram} = learn("Remember this pattern", :pattern, short_term: true)
      assert engram.short_term == true

      {:ok, reinforced} = reinforce(engram)
      assert reinforced.short_term == false
      assert reinforced.expires_at == nil
      assert reinforced.reinforced_count == 1
    end

    test "reinforce increments count on already long-term" do
      {:ok, engram} = learn("Already long", :fact, short_term: false)
      assert engram.reinforced_count == 0

      {:ok, r1} = reinforce(engram)
      assert r1.reinforced_count == 1

      # A caller can still hold the original snapshot after another reinforcement.
      {:ok, r2} = reinforce(engram)
      assert r2.reinforced_count == 2
      assert Handbean.Repo.get!(Engram, engram.id).reinforced_count == 2
    end

    test "reinforce updates last_reinforced_at" do
      {:ok, engram} = learn("Timing test", :fact, short_term: true)
      {:ok, reinforced} = reinforce(engram)

      assert reinforced.last_reinforced_at != nil
      diff = DateTime.diff(DateTime.utc_now(), reinforced.last_reinforced_at)
      assert diff < 5
    end
  end

  describe "associate/3 — linking engrams" do
    test "associate creates a synapse between two engrams" do
      {:ok, a} = learn("Concept A", :fact)
      {:ok, b} = learn("Concept B", :fact)

      {:ok, synapse} = associate(a, b, :related)

      assert synapse.source_id == a.id
      assert synapse.target_id == b.id
      assert synapse.kind == :related
      assert synapse.strength == 1.0
    end

    test "associate returns not found for a missing endpoint" do
      {:ok, a} = learn("Only A exists", :fact)
      fake = %Engram{id: -9999}

      assert {:error, :not_found} = associate(a, fake, :related)
    end

    test "duplicate association does not raise (on_conflict: :nothing)" do
      {:ok, a} = learn("Store Dup A", :fact)
      {:ok, b} = learn("Store Dup B", :fact)

      # First association
      {:ok, _s1} = associate(a, b, :related)

      # Second association with same pair + kind — should not raise
      {:ok, _s2_or_nil} = associate(a, b, :related)

      # Verify only one synapse exists
      count =
        Handbean.Memory.Synapse
        |> Handbean.Repo.all()
        |> Enum.count(fn s ->
          s.source_id == a.id and s.target_id == b.id and s.kind == :related
        end)

      assert count == 1
    end
  end

  describe "list_engrams/1 and count_summary/2 — settings queries" do
    test "isolates workspace memories and includes globals only for requested scopes" do
      {:ok, workspace_a} =
        learn("Workspace A private memory", :fact,
          short_term: false,
          metadata: %{scope: "workspace", workspace_id: "workspace-a"}
        )

      {:ok, workspace_b} =
        learn("Workspace B private memory", :rule,
          short_term: false,
          metadata: %{scope: "workspace", workspace_id: "workspace-b"}
        )

      {:ok, global} =
        learn("Shared global memory", :preference,
          short_term: false,
          metadata: %{scope: "global"}
        )

      workspace_results =
        MemoryStore.list_engrams(workspace_id: "workspace-a", scope: :workspace)

      assert Enum.map(workspace_results, & &1.id) == [workspace_a.id]
      refute Enum.any?(workspace_results, &(&1.id == workspace_b.id))
      refute Enum.any?(workspace_results, &(&1.id == global.id))

      both_ids =
        MemoryStore.list_engrams(workspace_id: "workspace-a", scope: :both)
        |> Enum.map(& &1.id)

      assert workspace_a.id in both_ids
      assert global.id in both_ids
      refute workspace_b.id in both_ids

      assert [global_result] = MemoryStore.list_engrams(scope: :global)
      assert global_result.id == global.id
    end

    test "filters active, long-term, short-term, and expired memories" do
      {:ok, long_term} =
        learn("Long-lived setting", :rule,
          short_term: false,
          metadata: %{scope: "workspace", workspace_id: "lifecycle-workspace"}
        )

      {:ok, short_term} =
        learn("Temporary setting", :pattern,
          short_term: true,
          metadata: %{scope: "workspace", workspace_id: "lifecycle-workspace"}
        )

      expired_at =
        DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

      {:ok, expired} =
        Handbean.Repo.insert(%Engram{
          content: "Expired setting",
          kind: :fact,
          short_term: true,
          expires_at: expired_at,
          metadata: %{scope: "workspace", workspace_id: "lifecycle-workspace"}
        })

      opts = [workspace_id: "lifecycle-workspace", scope: :workspace]

      assert Enum.map(MemoryStore.list_engrams(opts ++ [lifecycle: :active]), & &1.id) == [
               long_term.id,
               short_term.id
             ]

      assert Enum.map(MemoryStore.list_engrams(opts ++ [lifecycle: :long_term]), & &1.id) == [
               long_term.id
             ]

      assert Enum.map(MemoryStore.list_engrams(opts ++ [lifecycle: :short_term]), & &1.id) == [
               short_term.id
             ]

      assert Enum.map(MemoryStore.list_engrams(opts ++ [lifecycle: :expired]), & &1.id) == [
               expired.id
             ]

      summary = MemoryStore.count_summary("lifecycle-workspace", scope: :workspace)
      assert summary.active == 2
      assert summary.long_term == 1
      assert summary.short_term == 1
      assert summary.expired == 1
      assert summary.by_kind.rule == 1
      assert summary.by_kind.pattern == 1
      assert summary.by_kind.fact == 0
    end

    test "searches by content substring and exact plain or hash-prefixed ID" do
      {:ok, matching} =
        learn("Phoenix release workflow", :pattern,
          short_term: false,
          metadata: %{scope: "workspace", workspace_id: "search-workspace"}
        )

      {:ok, _other} =
        learn("Unrelated editor preference", :preference,
          short_term: false,
          metadata: %{scope: "workspace", workspace_id: "search-workspace"}
        )

      opts = [workspace_id: "search-workspace", scope: :workspace]

      assert [result] = MemoryStore.list_engrams(opts ++ [query: "release WORKFLOW"])
      assert result.id == matching.id

      assert [result] = MemoryStore.list_engrams(opts ++ [query: "##{matching.id}"])
      assert result.id == matching.id

      assert [result] = MemoryStore.list_engrams(opts ++ [query: Integer.to_string(matching.id)])
      assert result.id == matching.id
    end
  end

  describe "cleanup_expired/0 — expired engram deletion" do
    test "delete expired short-term engrams" do
      # Create an expired engram manually (truncate microseconds for SQLite3 compat)
      expired_dt =
        DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.truncate(:second)

      expired = %Engram{
        content: "Will be cleaned up",
        kind: :fact,
        short_term: true,
        expires_at: expired_dt
      }

      {:ok, expired_engram} = Handbean.Repo.insert(expired)

      # Create a non-expired engram
      {:ok, active} = learn("Still valid", :fact, short_term: true)

      {count, nil} = MemoryStore.cleanup_expired()

      assert count >= 1

      # Verify expired is gone
      assert Handbean.Repo.get(Engram, expired_engram.id) == nil

      # Verify active is still there
      assert Handbean.Repo.get(Engram, active.id) != nil
    end

    test "does not delete long-term engrams" do
      {:ok, lt} = learn("Long-term keeps", :fact, short_term: false)

      MemoryStore.cleanup_expired()

      assert Handbean.Repo.get(Engram, lt.id) != nil
    end
  end

  describe "scoped ownership" do
    test "learn requires explicit valid identity and protects identity metadata" do
      assert {:error, :invalid_scope} = MemoryStore.learn("Missing scope memory", :fact)

      assert {:ok, engram} =
               MemoryStore.learn("Scoped memory", :fact,
                 memory_scope: :workspace,
                 workspace_id: "actual-workspace",
                 metadata: %{
                   scope: "global",
                   workspace_id: "spoofed-workspace",
                   source: "test"
                 }
               )

      assert engram.metadata["scope"] == "workspace"
      assert engram.metadata["workspace_id"] == "actual-workspace"
      assert engram.metadata.source == "test"
    end

    test "short-term ttl_hours defaults to 24 and accepts an override" do
      {:ok, default_ttl} = learn("Default TTL memory", :fact)
      {:ok, week_ttl} = learn("Week TTL memory", :fact, ttl_hours: 168)

      assert_in_delta DateTime.diff(default_ttl.expires_at, DateTime.utc_now()), 24 * 3600, 10
      assert_in_delta DateTime.diff(week_ttl.expires_at, DateTime.utc_now()), 168 * 3600, 10
    end

    test "scoped update and delete cannot cross workspaces" do
      {:ok, engram} = learn("Original scoped content", :fact)
      other_opts = [memory_scope: :workspace, workspace_id: "other-workspace"]

      assert {:error, :not_found} =
               MemoryStore.update(engram.id, %{content: "Cross workspace edit"}, other_opts)

      assert {:ok, updated} =
               MemoryStore.update(engram.id, %{content: "Corrected scoped content"}, @scope_opts)

      assert updated.content == "Corrected scoped content"
      assert {:error, :not_found} = MemoryStore.delete(engram.id, other_opts)
      assert {:ok, _deleted} = MemoryStore.delete(engram.id, @scope_opts)
      refute Handbean.Repo.get(Engram, engram.id)
    end

    test "expired memories cannot be updated, reinforced, or associated but can be deleted" do
      expired_at =
        DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

      {:ok, expired} =
        Handbean.Repo.insert(%Engram{
          content: "Expired scoped mutation target",
          kind: :fact,
          short_term: true,
          expires_at: expired_at,
          metadata: %{"scope" => "workspace", "workspace_id" => "memory-store-test"}
        })

      {:ok, active} = learn("Active association endpoint", :fact)

      assert {:error, :not_found} = MemoryStore.reinforce(expired.id, @scope_opts)

      assert {:error, :not_found} =
               MemoryStore.update(expired.id, %{content: "Resurrected content"}, @scope_opts)

      assert {:error, :not_found} =
               MemoryStore.associate(expired.id, active.id, :related, @scope_opts)

      assert {:ok, _deleted} = MemoryStore.delete(expired.id, @scope_opts)
      refute Handbean.Repo.get(Engram, expired.id)
    end

    test "local_only rejects global writes and mutations" do
      global_opts = [memory_scope: :global, privacy_mode: :standard]
      {:ok, global} = MemoryStore.learn("Global scoped memory", :fact, global_opts)

      local_only_opts = [
        memory_scope: :both,
        workspace_id: "memory-store-test",
        privacy_mode: :local_only
      ]

      assert {:error, :invalid_scope} =
               MemoryStore.learn("Forbidden global write", :fact,
                 memory_scope: :global,
                 privacy_mode: :local_only
               )

      assert {:error, :not_found} = MemoryStore.reinforce(global.id, local_only_opts)
      assert {:error, :not_found} = MemoryStore.delete(global.id, local_only_opts)
    end

    test "find_active_exact normalizes content and stays scoped, typed, and active" do
      {:ok, matching} = learn("Café   project\npreference", :preference)

      {:ok, _other_workspace} =
        MemoryStore.learn("Café project preference", :preference,
          memory_scope: :workspace,
          workspace_id: "other-workspace"
        )

      assert {:ok, found} =
               MemoryStore.find_active_exact(
                 "  Cafe\u0301\tproject preference  ",
                 :preference,
                 @scope_opts
               )

      assert found.id == matching.id

      assert :none =
               MemoryStore.find_active_exact("Café project preference", :fact, @scope_opts)

      expired_at =
        DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

      {:ok, _expired} =
        Handbean.Repo.insert(%Engram{
          content: "Expired exact memory",
          kind: :fact,
          short_term: true,
          expires_at: expired_at,
          metadata: %{"scope" => "workspace", "workspace_id" => "memory-store-test"}
        })

      assert :none = MemoryStore.find_active_exact("Expired exact memory", :fact, @scope_opts)

      assert {:error, :invalid_scope} =
               MemoryStore.find_active_exact("Café project preference", :preference, [])
    end

    test "associations require the same workspace or two globals" do
      {:ok, workspace} = learn("Workspace association endpoint", :fact)

      {:ok, other_workspace} =
        MemoryStore.learn("Other workspace endpoint", :fact,
          memory_scope: :workspace,
          workspace_id: "other-workspace"
        )

      {:ok, global_a} =
        MemoryStore.learn("Global association A", :fact, memory_scope: :global)

      {:ok, global_b} =
        MemoryStore.learn("Global association B", :fact, memory_scope: :global)

      both_opts = [memory_scope: :both, workspace_id: "memory-store-test"]

      assert {:error, :not_found} =
               MemoryStore.associate(workspace.id, other_workspace.id, :related, both_opts)

      assert {:error, :scope_mismatch} =
               MemoryStore.associate(workspace.id, global_a.id, :related, both_opts)

      assert {:ok, _synapse} =
               MemoryStore.associate(global_a.id, global_b.id, :related, memory_scope: :global)
    end
  end

  defp learn(content, kind, opts \\ []) do
    identity_opts =
      case Keyword.get(opts, :metadata, %{}) do
        %{scope: "workspace", workspace_id: workspace_id} ->
          [memory_scope: :workspace, workspace_id: workspace_id]

        %{scope: "global"} ->
          [memory_scope: :global]

        _metadata ->
          @scope_opts
      end

    MemoryStore.learn(content, kind, Keyword.merge(identity_opts, opts))
  end

  defp recall(query, opts \\ []),
    do: MemoryStore.recall(query, Keyword.merge(@scope_opts, opts))

  defp reinforce(%Engram{id: id}), do: MemoryStore.reinforce(id, @scope_opts)

  defp associate(%Engram{id: source_id}, %Engram{id: target_id}, kind),
    do: MemoryStore.associate(source_id, target_id, kind, @scope_opts)
end
