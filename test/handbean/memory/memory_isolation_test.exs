defmodule Handbean.Memory.MemoryIsolationTest do
  use Handbean.DataCase

  alias Handbean.Memory.MemoryStore

  describe "PRD memory scope isolation" do
    test "workspace recall only returns engrams from the requested workspace" do
      {:ok, _a} =
        MemoryStore.learn("Shared isolation marker from workspace A", :fact,
          short_term: false,
          metadata: %{scope: "workspace", workspace_id: "workspace-a"}
        )

      {:ok, _b} =
        MemoryStore.learn("Shared isolation marker from workspace B", :fact,
          short_term: false,
          metadata: %{scope: "workspace", workspace_id: "workspace-b"}
        )

      results =
        MemoryStore.recall("Shared isolation marker",
          memory_scope: :workspace,
          workspace_id: "workspace-a"
        )

      assert Enum.any?(results, &(&1.content =~ "workspace A"))
      refute Enum.any?(results, &(&1.content =~ "workspace B"))
    end

    test "local_only privacy mode does not read global memory" do
      {:ok, _global} =
        MemoryStore.learn("Sensitive isolation global marker", :preference,
          short_term: false,
          metadata: %{scope: "global"}
        )

      {:ok, _workspace} =
        MemoryStore.learn("Sensitive isolation workspace marker", :fact,
          short_term: false,
          metadata: %{scope: "workspace", workspace_id: "private-workspace"}
        )

      results =
        MemoryStore.recall("Sensitive isolation",
          memory_scope: :both,
          privacy_mode: :local_only,
          workspace_id: "private-workspace"
        )

      assert Enum.any?(results, &(&1.content =~ "workspace marker"))
      refute Enum.any?(results, &(&1.content =~ "global marker"))
    end

    test "standard both scope can read workspace and global memory" do
      {:ok, _global} =
        MemoryStore.learn("Both scope global marker", :preference,
          short_term: false,
          metadata: %{scope: "global"}
        )

      {:ok, _workspace} =
        MemoryStore.learn("Both scope workspace marker", :fact,
          short_term: false,
          metadata: %{scope: "workspace", workspace_id: "workspace-c"}
        )

      results =
        MemoryStore.recall("Both scope",
          memory_scope: :both,
          privacy_mode: :standard,
          workspace_id: "workspace-c"
        )

      assert Enum.any?(results, &(&1.content =~ "global marker"))
      assert Enum.any?(results, &(&1.content =~ "workspace marker"))
    end

    test "workspace recall fails closed when workspace identity is missing" do
      {:ok, _workspace_a} =
        MemoryStore.learn("Missing identity workspace A marker", :fact,
          short_term: false,
          metadata: %{scope: "workspace", workspace_id: "workspace-a"}
        )

      {:ok, _workspace_b} =
        MemoryStore.learn("Missing identity workspace B marker", :fact,
          short_term: false,
          metadata: %{scope: "workspace", workspace_id: "workspace-b"}
        )

      for workspace_id <- [nil, "", "   "] do
        assert MemoryStore.recall("Missing identity workspace",
                 memory_scope: :workspace,
                 workspace_id: workspace_id
               ) == []
      end
    end

    test "both scope without workspace identity returns only shareable global memory" do
      {:ok, workspace} =
        MemoryStore.learn("Missing both workspace marker", :fact,
          short_term: false,
          metadata: %{scope: "workspace", workspace_id: "workspace-a"}
        )

      {:ok, global} =
        MemoryStore.learn("Missing both global marker", :fact,
          short_term: false,
          metadata: %{scope: "global", privacy_mode: "standard"}
        )

      {:ok, local_only_global} =
        MemoryStore.learn("Missing both private global marker", :fact,
          short_term: false,
          metadata: %{scope: "global", privacy_mode: "local_only"}
        )

      ids =
        MemoryStore.recall("Missing both marker", memory_scope: :both)
        |> Enum.map(& &1.id)

      assert global.id in ids
      refute workspace.id in ids
      refute local_only_global.id in ids
    end

    test "local-only recall fails closed without workspace identity" do
      {:ok, _workspace} =
        MemoryStore.learn("Missing private identity workspace marker", :fact,
          short_term: false,
          metadata: %{scope: "workspace", workspace_id: "workspace-a"}
        )

      {:ok, _global} =
        MemoryStore.learn("Missing private identity global marker", :fact,
          short_term: false,
          metadata: %{scope: "global"}
        )

      assert MemoryStore.recall("Missing private identity",
               memory_scope: :both,
               privacy_mode: :local_only
             ) == []
    end

    test "recall_metrics reports hit mix and cross-workspace leakage" do
      {:ok, _global} =
        MemoryStore.learn("Metric isolation global marker", :preference,
          short_term: false,
          metadata: %{scope: "global"}
        )

      {:ok, _workspace} =
        MemoryStore.learn("Metric isolation workspace marker", :fact,
          short_term: false,
          metadata: %{scope: "workspace", workspace_id: "workspace-metrics"}
        )

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
end
