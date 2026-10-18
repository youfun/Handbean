defmodule Handbean.Memory.MemoryIsolationTest do
  use Handbean.DataCase

  alias Handbean.Memory.{Engram, MemoryStore}

  describe "memory scope isolation" do
    test "workspace recall only returns the requested workspace" do
      {:ok, _a} = learn_workspace("Shared isolation marker from workspace A", "workspace-a")
      {:ok, _b} = learn_workspace("Shared isolation marker from workspace B", "workspace-b")

      results =
        MemoryStore.recall("Shared isolation marker",
          memory_scope: :workspace,
          workspace_id: "workspace-a"
        )

      assert Enum.any?(results, &(&1.content =~ "workspace A"))
      refute Enum.any?(results, &(&1.content =~ "workspace B"))
    end

    test "local_only reads workspace memory but never global memory" do
      {:ok, _global} = learn_global("Sensitive isolation global marker")

      {:ok, _workspace} =
        learn_workspace("Sensitive isolation workspace marker", "private-workspace")

      results =
        MemoryStore.recall("Sensitive isolation",
          memory_scope: :both,
          privacy_mode: :local_only,
          workspace_id: "private-workspace"
        )

      assert Enum.any?(results, &(&1.content =~ "workspace marker"))
      refute Enum.any?(results, &(&1.content =~ "global marker"))
    end

    test "standard both scope reads current workspace and global memory" do
      {:ok, _global} = learn_global("Both scope global marker")
      {:ok, _workspace} = learn_workspace("Both scope workspace marker", "workspace-c")
      {:ok, _other} = learn_workspace("Both scope other workspace marker", "workspace-d")

      results =
        MemoryStore.recall("Both scope",
          memory_scope: :both,
          privacy_mode: :standard,
          workspace_id: "workspace-c"
        )

      assert Enum.any?(results, &(&1.content =~ "global marker"))
      assert Enum.any?(results, &(&1.content =~ "workspace marker"))
      refute Enum.any?(results, &(&1.content =~ "other workspace"))
    end

    test "workspace recall fails closed when identity is missing or blank" do
      {:ok, _workspace} = learn_workspace("Missing identity workspace marker", "workspace-a")

      for workspace_id <- [nil, "", "   "] do
        assert MemoryStore.recall("Missing identity workspace",
                 memory_scope: :workspace,
                 workspace_id: workspace_id
               ) == []
      end
    end

    test "recall with missing or invalid scope fails closed" do
      {:ok, _workspace} = learn_workspace("Unscoped recall marker", "workspace-a")
      assert MemoryStore.recall("Unscoped recall marker") == []
      assert MemoryStore.recall("Unscoped recall marker", memory_scope: :unknown) == []
    end

    test "both scope without workspace identity returns only shareable global memory" do
      {:ok, workspace} = learn_workspace("Missing both workspace marker", "workspace-a")
      {:ok, global} = learn_global("Missing both global marker")

      {:ok, private_global} =
        Handbean.Repo.insert(%Engram{
          content: "Missing both private global marker",
          kind: :fact,
          short_term: false,
          metadata: %{scope: "global", privacy_mode: "local_only"}
        })

      ids =
        MemoryStore.recall("Missing both marker", memory_scope: :both)
        |> Enum.map(& &1.id)

      assert global.id in ids
      refute workspace.id in ids
      refute private_global.id in ids
    end

    test "local_only recall fails closed without workspace identity" do
      {:ok, _workspace} =
        learn_workspace("Missing private identity workspace marker", "workspace-a")

      {:ok, _global} = learn_global("Missing private identity global marker")

      assert MemoryStore.recall("Missing private identity",
               memory_scope: :both,
               privacy_mode: :local_only
             ) == []
    end

    test "recall does not preload synapses" do
      {:ok, source} = learn_workspace("Recall graph source marker", "workspace-a")
      {:ok, target} = learn_workspace("Recall graph target marker", "workspace-a")
      opts = [memory_scope: :workspace, workspace_id: "workspace-a"]
      {:ok, _synapse} = MemoryStore.associate(source.id, target.id, :related, opts)

      [recalled | _] = MemoryStore.recall("Recall graph source", opts)
      refute Ecto.assoc_loaded?(recalled.source_synapses)
      refute Ecto.assoc_loaded?(recalled.target_synapses)
    end

    test "recall_metrics reports hit mix without cross-workspace leakage" do
      {:ok, _global} = learn_global("Metric isolation global marker")

      {:ok, _workspace} =
        learn_workspace("Metric isolation workspace marker", "workspace-metrics")

      metrics =
        MemoryStore.recall_metrics("Metric isolation",
          memory_scope: :both,
          privacy_mode: :standard,
          workspace_id: "workspace-metrics"
        )

      assert metrics.total_hits == 2
      assert metrics.workspace_hits == 1
      assert metrics.global_hits == 1
      assert metrics.current_workspace_hits == 1
      assert metrics.cross_workspace_hits == 0
    end
  end

  defp learn_workspace(content, workspace_id) do
    MemoryStore.learn(content, :fact,
      short_term: false,
      memory_scope: :workspace,
      workspace_id: workspace_id
    )
  end

  defp learn_global(content) do
    MemoryStore.learn(content, :fact, short_term: false, memory_scope: :global)
  end
end
