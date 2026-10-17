defmodule Handbean.Tool.MemoryTest do
  @moduledoc """
  Tests for memory tools as Tool behaviour implementations.

  Translated from: `cog-cli/memory.zig` test blocks
  Reference: `sigil/lib/handbean/tool/memory/*.ex`

  Covers:
    - mem_learn: stores content, rejects invalid kinds
    - mem_recall: searches, returns formatted results
    - mem_reinforce: by id, by query
    - mem_associate: links two engrams
  """

  use Handbean.DataCase

  alias Handbean.Tool.Memory.{MemLearn, MemRecall, MemReinforce, MemAssociate}
  alias Handbean.Memory.MemoryStore

  describe "mem_learn tool" do
    test "stores valid content" do
      {:ok, output, data} =
        MemLearn.execute(
          %{"content" => "User prefers spaces over tabs", "kind" => "preference"},
          %{}
        )

      assert output =~ "Learned"
      assert output =~ "User prefers spaces over tabs"
      assert data.kind == "preference"
      assert is_integer(data.id)
    end

    test "rejects invalid kind" do
      {:error, reason} =
        MemLearn.execute(
          %{"content" => "some fact", "kind" => "invalid_kind"},
          %{}
        )

      assert reason =~ "Invalid kind"
    end

    test "rejects content that looks sensitive" do
      {:error, reason} =
        MemLearn.execute(
          %{"content" => "my api_key is sk-test-secret-value-123456", "kind" => "fact"},
          %{}
        )

      assert reason =~ "sensitive"
      assert MemoryStore.recall("api_key") == []
    end

    test "requires content and kind" do
      {:error, reason} = MemLearn.execute(%{}, %{})
      assert reason =~ "content"

      {:error, reason2} = MemLearn.execute(%{"content" => "x"}, %{})
      assert reason2 =~ "kind"
    end

    test "stores short-term memory with expires_at set" do
      {:ok, _output, data} =
        MemLearn.execute(
          %{"content" => "Temporary quick note", "kind" => "fact"},
          %{}
        )

      # Fetch the created engram and verify it has an expiry
      engram = Handbean.Repo.get!(Handbean.Memory.Engram, data.id)
      assert engram.short_term == true
      assert engram.expires_at != nil

      # Expiry should be ~24h from now
      diff = DateTime.diff(engram.expires_at, DateTime.utc_now())
      assert_in_delta diff, 86_400, 10
    end

    test "honors explicit long-term storage option" do
      {:ok, _output, data} =
        MemLearn.execute(
          %{
            "content" => "Project prefers durable architectural decisions in long-term memory",
            "kind" => "rule",
            "short_term" => false
          },
          %{}
        )

      engram = Handbean.Repo.get!(Handbean.Memory.Engram, data.id)
      assert engram.short_term == false
      assert engram.expires_at == nil
    end
  end

  describe "mem_recall tool" do
    test "returns formatted results for matching query" do
      {:ok, _} = MemoryStore.learn("Project uses Phoenix", :fact)
      {:ok, _} = MemoryStore.learn("User likes Elixir", :preference)

      {:ok, output, data} =
        MemRecall.execute(
          %{"query" => "Phoenix"},
          %{}
        )

      assert output =~ "Phoenix"
      assert output =~ "<stored-knowledge "
      assert output =~ "</stored-knowledge>"
      assert is_integer(data.count) and data.count >= 1
    end

    test "returns 'No memories found' for no matches" do
      {:ok, output} =
        MemRecall.execute(
          %{"query" => "xyznonexistent"},
          %{}
        )

      assert output == "No memories found."
    end

    test "labels short-term vs long-term" do
      {:ok, _} = MemoryStore.learn("Short term note", :fact, short_term: true)

      {:ok, output, _data} =
        MemRecall.execute(
          %{"query" => "Short term note"},
          %{}
        )

      assert output =~ ~s(scope="short-term")
    end

    test "respects limit option" do
      for i <- 1..3 do
        {:ok, _} = MemoryStore.learn("Limit recall item #{i}", :fact, short_term: false)
      end

      {:ok, output, data} =
        MemRecall.execute(
          %{"query" => "Limit recall item", "limit" => 1},
          %{}
        )

      assert data.count == 1
      assert output =~ "1."
      refute output =~ "2."
    end

    test "requires query" do
      {:error, reason} = MemRecall.execute(%{}, %{})
      assert reason =~ "query"
    end

    test "long-term memories appear before short-term" do
      {:ok, _} = MemoryStore.learn("Alpha recall ordering", :fact, short_term: true)
      {:ok, _} = MemoryStore.learn("Beta recall ordering", :fact, short_term: false)
      {:ok, _} = MemoryStore.learn("Gamma recall ordering", :pattern, short_term: false)

      {:ok, output, _data} =
        MemRecall.execute(
          %{"query" => "recall ordering"},
          %{}
        )

      # Long-term entries (no tag) should appear before short-term entries (tagged)
      lines = String.split(output, "\n")

      # Find the first line that contains "short-term" — everything before should be long-term
      short_term_idx = Enum.find_index(lines, &String.contains?(&1, "(short-term)"))

      # All preceding lines should NOT have "(short-term)"
      if short_term_idx do
        preceding = Enum.take(lines, short_term_idx)
        refute Enum.any?(preceding, &String.contains?(&1, "(short-term)"))
      end
    end
  end

  describe "mem_reinforce tool" do
    test "reinforces by id" do
      {:ok, engram} = MemoryStore.learn("Important pattern", :pattern, short_term: true)

      {:ok, output} =
        MemReinforce.execute(
          %{"id" => engram.id},
          %{}
        )

      assert output =~ "Reinforced"
      assert output =~ "now long-term"

      # Verify it is now long-term
      reloaded = Handbean.Repo.get!(Handbean.Memory.Engram, engram.id)
      assert reloaded.short_term == false
    end

    test "reinforces by query" do
      {:ok, _} = MemoryStore.learn("Unique stitch pattern", :pattern, short_term: true)

      {:ok, output} =
        MemReinforce.execute(
          %{"query" => "stitch pattern"},
          %{}
        )

      assert output =~ "Reinforced"
      assert output =~ "now long-term"
    end

    test "returns error for non-existent id" do
      {:error, reason} =
        MemReinforce.execute(
          %{"id" => 999_999},
          %{}
        )

      assert reason =~ "No engram found"
    end

    test "returns error for non-matching query" do
      {:error, reason} =
        MemReinforce.execute(
          %{"query" => "xyznonexistent"},
          %{}
        )

      assert reason =~ "No memory found"
    end

    test "sets short_term=false and expires_at=nil" do
      {:ok, engram} = MemoryStore.learn("Ephemeral note", :fact, short_term: true)

      # Before reinforce: short-term with expiry
      assert engram.short_term == true
      assert engram.expires_at != nil

      {:ok, _output} = MemReinforce.execute(%{"id" => engram.id}, %{})

      # After reinforce: long-term with no expiry
      reloaded = Handbean.Repo.get!(Handbean.Memory.Engram, engram.id)
      assert reloaded.short_term == false
      assert reloaded.expires_at == nil
      assert reloaded.reinforced_count == 1
    end
  end

  describe "mem_associate tool" do
    test "associates two engrams" do
      {:ok, a} = MemoryStore.learn("A module", :fact)
      {:ok, b} = MemoryStore.learn("B module", :fact)

      {:ok, output} =
        MemAssociate.execute(
          %{"source_id" => a.id, "target_id" => b.id, "kind" => "related"},
          %{}
        )

      assert output =~ "Associated"
      assert output =~ "related"
    end

    test "returns error for non-existent engrams" do
      {:error, reason} =
        MemAssociate.execute(
          %{"source_id" => -1, "target_id" => -2, "kind" => "related"},
          %{}
        )

      assert reason =~ "not found"
    end

    test "rejects invalid kind" do
      {:ok, a} = MemoryStore.learn("A", :fact)
      {:ok, b} = MemoryStore.learn("B", :fact)

      {:error, reason} =
        MemAssociate.execute(
          %{"source_id" => a.id, "target_id" => b.id, "kind" => "invalid"},
          %{}
        )

      assert reason =~ "Invalid kind"
    end

    test "requires all fields" do
      {:error, reason} = MemAssociate.execute(%{}, %{})
      assert reason =~ "source_id"
    end

    test "duplicate association does not crash" do
      {:ok, a} = MemoryStore.learn("Dup Source", :fact)
      {:ok, b} = MemoryStore.learn("Dup Target", :fact)

      # First association — should succeed
      result1 =
        MemAssociate.execute(
          %{"source_id" => a.id, "target_id" => b.id, "kind" => "related"},
          %{}
        )

      assert match?({:ok, _}, result1)

      # Second association with same params — should NOT crash
      result2 =
        MemAssociate.execute(
          %{"source_id" => a.id, "target_id" => b.id, "kind" => "related"},
          %{}
        )

      # Should return {:ok, _} without error (duplicates silently handled via on_conflict: :nothing)
      assert match?({:ok, _}, result2)

      # Verify only one synapse exists for this pair + kind
      synapse_count =
        Handbean.Memory.Synapse
        |> Handbean.Repo.all()
        |> Enum.count(fn s ->
          s.source_id == a.id and s.target_id == b.id and s.kind == :related
        end)

      assert synapse_count == 1
    end
  end
end
