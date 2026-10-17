defmodule Handbean.Memory.MetricsTest do
  use Handbean.DataCase

  alias Handbean.Memory.{MemoryStore, Metrics}

  describe "recall_quality/3" do
    test "computes useful, stale, contradiction and token-cost rates" do
      {:ok, useful} = MemoryStore.learn("Useful metric marker", :fact, short_term: false)
      {:ok, stale} = MemoryStore.learn("Stale metric marker", :fact, short_term: false)
      {:ok, bad} = MemoryStore.learn("Contradictory metric marker", :fact, short_term: false)

      metrics =
        Metrics.recall_quality(
          [useful, stale, bad],
          %{useful.id => :useful, stale.id => "stale", bad.id => :contradictory},
          injected_tokens: 120
        )

      assert metrics.total_recalled == 3
      assert metrics.useful_count == 1
      assert metrics.stale_count == 1
      assert metrics.contradictory_count == 1
      assert metrics.useful_rate == 1 / 3
      assert metrics.stale_rate == 1 / 3
      assert metrics.contradiction_rate == 1 / 3
      assert metrics.injected_tokens == 120
      assert_in_delta metrics.useful_per_1k_tokens, 8.333, 0.01
    end
  end

  describe "isolation_quality/2" do
    test "reports cross-workspace leakage rate" do
      {:ok, current} =
        MemoryStore.learn("Current workspace metric", :fact,
          metadata: %{scope: "workspace", workspace_id: "metrics-a"}
        )

      {:ok, other} =
        MemoryStore.learn("Other workspace metric", :fact,
          metadata: %{scope: "workspace", workspace_id: "metrics-b"}
        )

      metrics = Metrics.isolation_quality([current, other], "metrics-a")

      assert metrics.total_recalled == 2
      assert metrics.workspace_hits == 2
      assert metrics.cross_workspace_hits == 1
      assert metrics.leakage_rate == 0.5
    end
  end
end
