defmodule Handbean.Memory.MemoryToolIsolationTest do
  use Handbean.DataCase

  alias Handbean.Agent.{Config, State}
  alias Handbean.Agent.Tool.Executor
  alias Handbean.Memory.{Engram, MemoryStore}
  alias Handbean.Repo

  alias Handbean.Tool.Memory.{
    MemAssociate,
    MemForget,
    MemLearn,
    MemRecall,
    MemReinforce,
    MemUpdate
  }

  @workspace_a %{
    workspace_id: "tool-a",
    memory_scope: "workspace",
    privacy_mode: "standard"
  }
  @both %{
    workspace_id: "tool-a",
    memory_scope: "both",
    privacy_mode: "standard"
  }
  @local_only %{
    workspace_id: "tool-a",
    memory_scope: "both",
    privacy_mode: "local_only"
  }
  @global %{memory_scope: "global", privacy_mode: "standard"}

  describe "memory tool isolation" do
    test "agent config exposes workspace memory policy to tool context" do
      :ok = Handbean.Tool.Registry.register(MemLearn)

      config =
        Config.from_opts(
          workspace_id: "tool-workspace",
          om: %{memory_scope: "workspace", privacy_mode: "local_only"}
        )

      state = State.init(config, "test")

      assert {:ok, _result_msg, [%{is_error: false}]} =
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

      engram = Repo.one!(Engram)
      assert engram.metadata["scope"] == "workspace"
      assert engram.metadata["workspace_id"] == "tool-workspace"
      assert engram.metadata["privacy_mode"] == "local_only"
    end

    test "recall only returns the current workspace" do
      {:ok, _a} = learn_workspace("Tool recall isolation marker workspace A", "tool-a")
      {:ok, _b} = learn_workspace("Tool recall isolation marker workspace B", "tool-b")

      assert {:ok, text, data} =
               MemRecall.execute(%{"query" => "Tool recall isolation marker"}, @workspace_a)

      assert text =~ "workspace A"
      refute text =~ "workspace B"
      assert Enum.all?(data.results, &(&1.metadata["workspace_id"] == "tool-a"))
    end

    test "reinforce update and forget refuse cross-workspace ids" do
      {:ok, engram} = learn_workspace("Cross workspace mutation marker", "tool-b")

      assert {:error, reinforce_error} = MemReinforce.execute(%{"id" => engram.id}, @workspace_a)
      assert reinforce_error =~ "No accessible"

      assert {:error, update_error} =
               MemUpdate.execute(
                 %{"id" => engram.id, "content" => "Cross workspace corrected marker"},
                 @workspace_a
               )

      assert update_error =~ "No accessible"
      assert {:error, forget_error} = MemForget.execute(%{"id" => engram.id}, @workspace_a)
      assert forget_error =~ "No accessible"
      assert Repo.get!(Engram, engram.id).content == "Cross workspace mutation marker"
    end

    test "global mutations work in global scope but local_only cannot access them" do
      assert {:ok, _output, data} =
               MemLearn.execute(
                 %{"content" => "Global tool isolation marker", "kind" => "fact"},
                 @global
               )

      global = Repo.get!(Engram, data.id)
      assert global.metadata["scope"] == "global"

      assert {:error, reason} = MemReinforce.execute(%{"id" => global.id}, @local_only)
      assert reason =~ "No accessible"

      assert {:error, reason} =
               MemUpdate.execute(%{"id" => global.id, "kind" => "rule"}, @local_only)

      assert reason =~ "No accessible"
      assert {:error, reason} = MemForget.execute(%{"id" => global.id}, @local_only)
      assert reason =~ "No accessible"

      assert {:ok, _output} = MemReinforce.execute(%{"id" => global.id}, @global)
    end

    test "associate permits same workspace and two globals" do
      {:ok, source} = learn_workspace("Association source same workspace", "tool-a")
      {:ok, target} = learn_workspace("Association target same workspace", "tool-a")

      assert {:ok, message} =
               MemAssociate.execute(
                 %{
                   "source_id" => source.id,
                   "target_id" => target.id,
                   "kind" => "related"
                 },
                 @workspace_a
               )

      assert message =~ "Associated"

      {:ok, global_a} = learn_global("Global association endpoint A")
      {:ok, global_b} = learn_global("Global association endpoint B")

      assert {:ok, _message} =
               MemAssociate.execute(
                 %{
                   "source_id" => global_a.id,
                   "target_id" => global_b.id,
                   "kind" => "related"
                 },
                 @global
               )
    end

    test "associate rejects cross-workspace and workspace-global links" do
      {:ok, workspace_a} = learn_workspace("Association workspace A endpoint", "tool-a")
      {:ok, workspace_b} = learn_workspace("Association workspace B endpoint", "tool-b")
      {:ok, global} = learn_global("Association global endpoint")

      assert {:error, cross_workspace_error} =
               MemAssociate.execute(
                 %{
                   "source_id" => workspace_a.id,
                   "target_id" => workspace_b.id,
                   "kind" => "related"
                 },
                 @both
               )

      assert cross_workspace_error =~ "not accessible"

      assert {:error, mixed_scope_error} =
               MemAssociate.execute(
                 %{
                   "source_id" => workspace_a.id,
                   "target_id" => global.id,
                   "kind" => "related"
                 },
                 @both
               )

      assert mixed_scope_error =~ "same workspace"
    end

    test "local_only cannot learn or associate global memories" do
      assert {:error, reason} =
               MemLearn.execute(
                 %{"content" => "Forbidden local-only global memory", "kind" => "fact"},
                 %{memory_scope: "global", privacy_mode: "local_only"}
               )

      assert reason =~ "explicit memory scope"

      {:ok, workspace} = learn_workspace("Local-only workspace endpoint", "tool-a")
      {:ok, global} = learn_global("Local-only global endpoint")

      assert {:error, reason} =
               MemAssociate.execute(
                 %{
                   "source_id" => workspace.id,
                   "target_id" => global.id,
                   "kind" => "related"
                 },
                 @local_only
               )

      assert reason =~ "not accessible"
    end
  end

  defp learn_workspace(content, workspace_id) do
    MemoryStore.learn(content, :fact,
      memory_scope: :workspace,
      workspace_id: workspace_id
    )
  end

  defp learn_global(content), do: MemoryStore.learn(content, :fact, memory_scope: :global)
end
