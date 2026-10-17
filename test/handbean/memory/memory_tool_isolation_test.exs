defmodule Handbean.Memory.MemoryToolIsolationTest do
  use Handbean.DataCase

  alias Handbean.Agent.Config
  alias Handbean.Agent.State
  alias Handbean.Agent.Tool.Executor
  alias Handbean.Memory.{Engram, MemoryStore}
  alias Handbean.Repo
  alias Handbean.Tool.Memory.{MemAssociate, MemLearn, MemRecall, MemReinforce}

  describe "memory tool isolation" do
    test "agent config exposes workspace memory policy to tool context" do
      :ok = Handbean.Tool.Registry.register(MemLearn)

      config =
        Config.from_opts(
          workspace_id: "tool-workspace",
          om: %{memory_scope: "workspace", privacy_mode: "local_only"}
        )

      state = State.init(config, "test")

      {:ok, _result_msg, blocks} =
        Executor.execute_all_with_details(
          [
            %{
              id: "toolu_1",
              name: "mem_learn",
              input: %{"content" => "Tool context isolation marker", "kind" => "fact"}
            }
          ],
          state
        )

      assert [%{is_error: false}] = blocks

      engram = Repo.one!(Engram)
      assert engram.metadata["scope"] == "workspace"
      assert engram.metadata["workspace_id"] == "tool-workspace"
      assert engram.metadata["privacy_mode"] == "local_only"
    end

    test "mem_recall filters by workspace context" do
      {:ok, _a} =
        MemoryStore.learn("Tool recall isolation marker workspace A", :fact,
          short_term: false,
          metadata: %{scope: "workspace", workspace_id: "tool-a"}
        )

      {:ok, _b} =
        MemoryStore.learn("Tool recall isolation marker workspace B", :fact,
          short_term: false,
          metadata: %{scope: "workspace", workspace_id: "tool-b"}
        )

      {:ok, text, data} =
        MemRecall.execute(
          %{"query" => "Tool recall isolation marker"},
          %{workspace_id: "tool-a", memory_scope: "workspace", privacy_mode: "standard"}
        )

      assert text =~ "workspace A"
      refute text =~ "workspace B"
      assert Enum.all?(data.results, &(&1.metadata["workspace_id"] == "tool-a"))
    end

    test "mem_learn stamps workspace scope metadata from context" do
      {:ok, _text, data} =
        MemLearn.execute(
          %{"content" => "Tool learn scoped marker", "kind" => "fact", "short_term" => false},
          %{workspace_id: "learn-workspace", memory_scope: "workspace", privacy_mode: "standard"}
        )

      engram = Repo.get!(Engram, data.id)
      assert engram.metadata["scope"] == "workspace"
      assert engram.metadata["workspace_id"] == "learn-workspace"
      assert engram.metadata["privacy_mode"] == "standard"
    end

    test "mem_reinforce by id refuses cross-workspace engrams" do
      {:ok, engram} =
        MemoryStore.learn("Cross workspace reinforce marker", :fact,
          metadata: %{scope: "workspace", workspace_id: "other-workspace"}
        )

      assert {:error, message} =
               MemReinforce.execute(%{"id" => engram.id}, %{
                 workspace_id: "current-workspace",
                 memory_scope: "workspace",
                 privacy_mode: "standard"
               })

      assert message =~ "No accessible engram"
    end

    test "mem_associate associates engrams inside the same accessible workspace" do
      {:ok, source} =
        MemoryStore.learn("Associate source in current workspace", :fact,
          metadata: %{scope: "workspace", workspace_id: "associate-workspace"}
        )

      {:ok, target} =
        MemoryStore.learn("Associate target in current workspace", :fact,
          metadata: %{scope: "workspace", workspace_id: "associate-workspace"}
        )

      assert {:ok, message} =
               MemAssociate.execute(
                 %{
                   "source_id" => source.id,
                   "target_id" => target.id,
                   "kind" => "related"
                 },
                 %{
                   workspace_id: "associate-workspace",
                   memory_scope: "workspace",
                   privacy_mode: "standard"
                 }
               )

      assert message =~ "Associated engram"
    end

    test "mem_associate refuses to link an inaccessible cross-workspace engram" do
      {:ok, source} =
        MemoryStore.learn("Associate source in current workspace", :fact,
          metadata: %{scope: "workspace", workspace_id: "associate-current"}
        )

      {:ok, target} =
        MemoryStore.learn("Associate target in another workspace", :fact,
          metadata: %{scope: "workspace", workspace_id: "associate-other"}
        )

      assert {:error, message} =
               MemAssociate.execute(
                 %{
                   "source_id" => source.id,
                   "target_id" => target.id,
                   "kind" => "related"
                 },
                 %{
                   workspace_id: "associate-current",
                   memory_scope: "workspace",
                   privacy_mode: "standard"
                 }
               )

      assert message =~ "not accessible"
    end

    test "mem_associate local_only refuses global engrams" do
      {:ok, source} =
        MemoryStore.learn("Associate local-only source", :fact,
          metadata: %{scope: "workspace", workspace_id: "associate-private"}
        )

      {:ok, target} =
        MemoryStore.learn("Associate global target", :preference, metadata: %{scope: "global"})

      assert {:error, message} =
               MemAssociate.execute(
                 %{
                   "source_id" => source.id,
                   "target_id" => target.id,
                   "kind" => "related"
                 },
                 %{
                   workspace_id: "associate-private",
                   memory_scope: "both",
                   privacy_mode: "local_only"
                 }
               )

      assert message =~ "not accessible"
    end
  end
end
