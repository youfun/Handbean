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

  describe "learn/3 — creating engrams" do
    test "learn stores a fact engram" do
      {:ok, engram} = MemoryStore.learn("User prefers snake_case naming", :preference)

      assert engram.content == "User prefers snake_case naming"
      assert engram.kind == :preference
      assert engram.short_term == true
      assert engram.expires_at != nil
      assert engram.reinforced_count == 0
    end

    test "learn sets expiry for short-term engrams" do
      {:ok, engram} = MemoryStore.learn("Temporary fact", :fact, short_term: true)

      assert engram.short_term == true
      assert engram.expires_at != nil

      # Should expire ~24h from now
      diff = DateTime.diff(engram.expires_at, DateTime.utc_now())
      assert_in_delta diff, 86_400, 10
    end

    test "learn can create long-term engrams" do
      {:ok, engram} = MemoryStore.learn("Important rule", :rule, short_term: false)

      assert engram.short_term == false
      assert engram.expires_at == nil
    end

    test "learn requires content and kind" do
      {:error, changeset} = MemoryStore.learn("", :fact)
      assert changeset.errors[:content]

      {:error, changeset2} = MemoryStore.learn("some content", nil)
      assert changeset2.errors[:kind]
    end

    test "learn stores metadata" do
      {:ok, engram} = MemoryStore.learn("Fact with meta", :fact, metadata: %{source: "test"})
      assert engram.metadata.source == "test"
    end
  end

  describe "recall/2 — searching engrams" do
    test "recall finds engrams by content match" do
      {:ok, _} = MemoryStore.learn("Project uses Phoenix framework", :fact, short_term: false)
      {:ok, _} = MemoryStore.learn("User prefers tabs over spaces", :preference)

      results = MemoryStore.recall("Phoenix")
      assert length(results) >= 1

      matched = Enum.find(results, &(&1.content =~ "Phoenix"))
      assert matched != nil
    end

    test "recall respects limit" do
      # Fill with several engrams
      for i <- 1..5 do
        {:ok, _} = MemoryStore.learn("Data point #{i}", :fact, short_term: false)
      end

      results = MemoryStore.recall("Data point", limit: 2)
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

      results = MemoryStore.recall("Expired data")

      # Expired engrams should not appear in results
      expired_ids = Enum.map(results, & &1.id)
      refute expired_engram.id in expired_ids
    end

    test "recall returns empty for no match" do
      results = MemoryStore.recall("xyznonexistent98765")
      assert results == []
    end

    test "recall orders by long-term first, then reinforced count" do
      {:ok, _lt} = MemoryStore.learn("Recall ordered: long-term", :fact, short_term: false)
      {:ok, _st} = MemoryStore.learn("Recall ordered: short-term", :fact, short_term: true)

      results = MemoryStore.recall("Recall ordered")
      assert length(results) >= 2

      # Long-term should come first
      first = List.first(results)
      assert first.short_term == false
    end
  end

  describe "reinforce/1 — promoting to long-term" do
    test "reinforce promotes short-term to long-term memory" do
      {:ok, engram} = MemoryStore.learn("Remember this pattern", :pattern, short_term: true)
      assert engram.short_term == true

      {:ok, reinforced} = MemoryStore.reinforce(engram)
      assert reinforced.short_term == false
      assert reinforced.expires_at == nil
      assert reinforced.reinforced_count == 1
    end

    test "reinforce increments count on already long-term" do
      {:ok, engram} = MemoryStore.learn("Already long", :fact, short_term: false)
      assert engram.reinforced_count == 0

      {:ok, r1} = MemoryStore.reinforce(engram)
      assert r1.reinforced_count == 1

      # A caller can still hold the original snapshot after another reinforcement.
      {:ok, r2} = MemoryStore.reinforce(engram)
      assert r2.reinforced_count == 2
      assert Handbean.Repo.get!(Engram, engram.id).reinforced_count == 2
    end

    test "reinforce updates last_reinforced_at" do
      {:ok, engram} = MemoryStore.learn("Timing test", :fact, short_term: true)
      {:ok, reinforced} = MemoryStore.reinforce(engram)

      assert reinforced.last_reinforced_at != nil
      diff = DateTime.diff(DateTime.utc_now(), reinforced.last_reinforced_at)
      assert diff < 5
    end
  end

  describe "associate/3 — linking engrams" do
    test "associate creates a synapse between two engrams" do
      {:ok, a} = MemoryStore.learn("Concept A", :fact)
      {:ok, b} = MemoryStore.learn("Concept B", :fact)

      {:ok, synapse} = MemoryStore.associate(a, b, :related)

      assert synapse.source_id == a.id
      assert synapse.target_id == b.id
      assert synapse.kind == :related
      assert synapse.strength == 1.0
    end

    test "associate with missing engram raises" do
      {:ok, a} = MemoryStore.learn("Only A exists", :fact)
      fake = %Engram{id: -9999}

      # FK constraint may raise — this is expected behavior and should be caught
      assert_raise Ecto.ConstraintError, fn ->
        MemoryStore.associate(a, fake, :related)
      end
    end

    test "duplicate association does not raise (on_conflict: :nothing)" do
      {:ok, a} = MemoryStore.learn("Store Dup A", :fact)
      {:ok, b} = MemoryStore.learn("Store Dup B", :fact)

      # First association
      {:ok, _s1} = MemoryStore.associate(a, b, :related)

      # Second association with same pair + kind — should not raise
      {:ok, _s2_or_nil} = MemoryStore.associate(a, b, :related)

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
        MemoryStore.learn("Workspace A private memory", :fact,
          short_term: false,
          metadata: %{scope: "workspace", workspace_id: "workspace-a"}
        )

      {:ok, workspace_b} =
        MemoryStore.learn("Workspace B private memory", :rule,
          short_term: false,
          metadata: %{scope: "workspace", workspace_id: "workspace-b"}
        )

      {:ok, global} =
        MemoryStore.learn("Shared global memory", :preference,
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
        MemoryStore.learn("Long-lived setting", :rule,
          short_term: false,
          metadata: %{scope: "workspace", workspace_id: "lifecycle-workspace"}
        )

      {:ok, short_term} =
        MemoryStore.learn("Temporary setting", :pattern,
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
        MemoryStore.learn("Phoenix release workflow", :pattern,
          short_term: false,
          metadata: %{scope: "workspace", workspace_id: "search-workspace"}
        )

      {:ok, _other} =
        MemoryStore.learn("Unrelated editor preference", :preference,
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
      {:ok, active} = MemoryStore.learn("Still valid", :fact, short_term: true)

      {count, nil} = MemoryStore.cleanup_expired()

      assert count >= 1

      # Verify expired is gone
      assert Handbean.Repo.get(Engram, expired_engram.id) == nil

      # Verify active is still there
      assert Handbean.Repo.get(Engram, active.id) != nil
    end

    test "does not delete long-term engrams" do
      {:ok, lt} = MemoryStore.learn("Long-term keeps", :fact, short_term: false)

      MemoryStore.cleanup_expired()

      assert Handbean.Repo.get(Engram, lt.id) != nil
    end
  end
end
