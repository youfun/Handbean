defmodule Handbean.Tool.MemoryTest do
  use Handbean.DataCase

  alias Handbean.Memory.{Engram, MemoryStore, Synapse}
  alias Handbean.Repo

  alias Handbean.Tool.Memory.{
    MemAssociate,
    MemForget,
    MemLearn,
    MemRecall,
    MemReflect,
    MemReinforce,
    MemUpdate
  }

  @context %{
    workspace_id: "tool-memory-test",
    memory_scope: "workspace",
    privacy_mode: "standard"
  }
  @scope_opts [
    workspace_id: "tool-memory-test",
    memory_scope: :workspace,
    privacy_mode: :standard
  ]

  describe "mem_learn" do
    test "stores scoped content with fixed default ttl and agent provenance" do
      assert {:ok, output, data} =
               MemLearn.execute(
                 %{"content" => "User prefers spaces over tabs", "kind" => "preference"},
                 @context
               )

      assert output =~ "Learned"
      engram = Repo.get!(Engram, data.id)
      assert engram.metadata["scope"] == "workspace"
      assert engram.metadata["workspace_id"] == "tool-memory-test"
      assert engram.metadata["source"] == "agent_tool"
      assert_in_delta DateTime.diff(engram.expires_at, DateTime.utc_now()), 24 * 3600, 10
      refute Map.has_key?(MemLearn.input_schema().properties, :ttl_hours)
    end

    test "can create long-term memory" do
      assert {:ok, _output, data} =
               MemLearn.execute(
                 %{
                   "content" => "Durable architectural decision for project",
                   "kind" => "rule",
                   "short_term" => false
                 },
                 @context
               )

      engram = Repo.get!(Engram, data.id)
      refute engram.short_term
      assert is_nil(engram.expires_at)
    end

    test "rejects invalid, sensitive, and unscoped writes" do
      assert {:error, reason} =
               MemLearn.execute(%{"content" => "some valid fact", "kind" => "invalid"}, @context)

      assert reason =~ "Invalid kind"

      assert {:error, reason} =
               MemLearn.execute(
                 %{"content" => "my api_key is sk-test-secret-value-123456", "kind" => "fact"},
                 @context
               )

      assert reason =~ "sensitive"

      assert {:error, reason} =
               MemLearn.execute(%{"content" => "Unscoped durable fact", "kind" => "fact"}, %{})

      assert reason =~ "explicit memory scope"
      assert Repo.aggregate(Engram, :count) == 0
    end
  end

  describe "mem_recall" do
    test "returns formatted scoped results and respects limit" do
      for i <- 1..3 do
        {:ok, _} = learn("Phoenix scoped recall item #{i}", :fact, short_term: false)
      end

      assert {:ok, output, data} =
               MemRecall.execute(%{"query" => "Phoenix scoped recall", "limit" => 1}, @context)

      assert output =~ "<stored-knowledge "
      assert output =~ "Phoenix"
      assert data.count == 1
      refute output =~ "2."
    end

    test "fails closed without scope" do
      {:ok, _} = learn("Hidden unscoped recall marker", :fact)

      assert {:ok, "No memories found."} =
               MemRecall.execute(%{"query" => "Hidden unscoped recall"}, %{})
    end
  end

  describe "mem_reinforce" do
    test "reinforces by id and query" do
      {:ok, by_id} = learn("Important scoped pattern", :pattern)
      assert {:ok, output} = MemReinforce.execute(%{"id" => by_id.id}, @context)
      assert output =~ "now long-term"
      refute Repo.get!(Engram, by_id.id).short_term

      {:ok, by_query} = learn("Unique scoped stitch pattern", :pattern)
      assert {:ok, output} = MemReinforce.execute(%{"query" => "stitch pattern"}, @context)
      assert output =~ "Reinforced"
      refute Repo.get!(Engram, by_query.id).short_term
    end

    test "rejects wrong ids and missing scope" do
      assert {:error, reason} = MemReinforce.execute(%{"id" => 999_999}, @context)
      assert reason =~ "No accessible engram"

      {:ok, engram} = learn("Cannot reinforce without scope", :fact)
      assert {:error, reason} = MemReinforce.execute(%{"id" => engram.id}, %{})
      assert reason =~ "explicit memory scope"
    end
  end

  describe "mem_associate" do
    test "associates two scoped memories and handles duplicates" do
      {:ok, source} = learn("Association source memory", :fact)
      {:ok, target} = learn("Association target memory", :fact)
      input = %{"source_id" => source.id, "target_id" => target.id, "kind" => "related"}

      assert {:ok, _output} = MemAssociate.execute(input, @context)
      assert {:ok, _output} = MemAssociate.execute(input, @context)
      assert Repo.aggregate(Synapse, :count) == 1
    end

    test "rejects invalid kind, wrong id, and missing scope" do
      {:ok, source} = learn("Association validation source", :fact)
      {:ok, target} = learn("Association validation target", :fact)

      assert {:error, reason} =
               MemAssociate.execute(
                 %{"source_id" => source.id, "target_id" => target.id, "kind" => "invalid"},
                 @context
               )

      assert reason =~ "Invalid kind"

      assert {:error, reason} =
               MemAssociate.execute(
                 %{"source_id" => source.id, "target_id" => -1, "kind" => "related"},
                 @context
               )

      assert reason =~ "not accessible"

      assert {:error, reason} =
               MemAssociate.execute(
                 %{"source_id" => source.id, "target_id" => target.id, "kind" => "related"},
                 %{}
               )

      assert reason =~ "explicit memory scope"
    end
  end

  describe "mem_update" do
    test "corrects content and kind in scope" do
      {:ok, engram} = learn("Original remembered preference", :preference)

      assert {:ok, output, data} =
               MemUpdate.execute(
                 %{
                   "id" => engram.id,
                   "content" => "Corrected remembered project rule",
                   "kind" => "rule"
                 },
                 @context
               )

      assert output =~ "Updated"
      assert data.id == engram.id
      updated = Repo.get!(Engram, engram.id)
      assert updated.content == "Corrected remembered project rule"
      assert updated.kind == :rule
    end

    test "requires a change and a valid scope" do
      {:ok, engram} = learn("Update validation memory", :fact)
      assert {:error, reason} = MemUpdate.execute(%{"id" => engram.id}, @context)
      assert reason =~ "content or kind"

      assert {:error, reason} =
               MemUpdate.execute(%{"id" => engram.id, "kind" => "rule"}, %{})

      assert reason =~ "explicit memory scope"
    end
  end

  describe "mem_forget" do
    test "deletes an in-scope memory" do
      {:ok, engram} = learn("Memory explicitly retracted by user", :fact)
      assert {:ok, output, %{id: id}} = MemForget.execute(%{"id" => engram.id}, @context)
      assert output =~ "Forgot"
      assert id == engram.id
      refute Repo.get(Engram, engram.id)
    end

    test "fails closed for wrong ids and missing scope" do
      assert {:error, reason} = MemForget.execute(%{"id" => 999_999}, @context)
      assert reason =~ "No accessible memory"

      {:ok, engram} = learn("Cannot forget without scope", :fact)
      assert {:error, reason} = MemForget.execute(%{"id" => engram.id}, %{})
      assert reason =~ "explicit memory scope"
      assert Repo.get(Engram, engram.id)
    end
  end

  describe "mem_reflect" do
    test "requires a persisted conversation context" do
      assert {:error, reason} = MemReflect.execute(%{}, @context)
      assert reason =~ "persisted conversation"
    end

    test "describes a manual, reviewable candidate action" do
      assert MemReflect.description() =~ "explicitly asks"
      assert MemReflect.description() =~ "short-term memory candidate"
      assert MemReflect.input_schema().required == []
    end
  end

  defp learn(content, kind, opts \\ []) do
    MemoryStore.learn(content, kind, Keyword.merge(@scope_opts, opts))
  end
end
