defmodule Handbean.ConversationsTrajectoryTest do
  use Handbean.ConversationsCase, async: false

  alias Handbean.Agent.TranscriptPersistence
  alias Handbean.{ConversationStore, ConversationTranscriptStore, Conversations}

  test "trajectory exposes durable runs, turns and bounded redacted records", c do
    opts = [run_id: "trajectory-run", model: "provider/model"]

    assert {:ok, _} =
             TranscriptPersistence.append_inbound(c.target, "Investigate", opts)

    assert :ok =
             TranscriptPersistence.handle_event(
               c.target,
               {:run_start, %{model: "provider/model", loop_owner: :handbean}},
               opts
             )

    assert :ok =
             TranscriptPersistence.handle_event(c.target, {:turn_start, %{turn: 1}}, opts)

    assert :ok =
             TranscriptPersistence.handle_event(
               c.target,
               {:message_delta, %{chunk: "Checking the file"}},
               opts
             )

    assert :ok =
             TranscriptPersistence.handle_event(
               c.target,
               {:tool_start,
                %{
                  tool_use_id: "trajectory-tool",
                  tool: "read",
                  input: %{"file_path" => "lib/app.ex", "api_key" => "top-secret"}
                }},
               opts
             )

    assert :ok =
             TranscriptPersistence.handle_event(
               c.target,
               {:tool_end,
                %{
                  tool_use_id: "trajectory-tool",
                  tool: "read",
                  output: "Authorization: Bearer sub-token-value",
                  duration_ms: 12,
                  started_at: "2026-10-16T10:00:00.000000Z",
                  completed_at: "2026-10-16T10:00:00.012000Z",
                  timing_fidelity: "exact"
                }},
               opts
             )

    assert :ok =
             TranscriptPersistence.handle_event(
               c.target,
               {:turn_end,
                %{turn: 1, status: :completed, stop_reason: "completed", duration_ms: 20}},
               opts
             )

    assert :ok =
             TranscriptPersistence.handle_event(
               c.target,
               {:run_end,
                %{
                  status: :completed,
                  turns: 1,
                  duration_ms: 25,
                  model: "provider/model"
                }},
               opts
             )

    assert {:ok, summary} =
             Conversations.trajectory(
               %{"conversation" => c.target, "detail_level" => "summary", "max_chars" => 16_000},
               c.context
             )

    assert summary.schema_version == 1
    assert summary.detail_level == "summary"
    assert summary.records == []
    assert summary.stats == %{errors: 0, records: 3, running: 0, runs: 1, tools: 1, turns: 1}
    assert [%{id: "trajectory-run", status: "completed", turn_count: 1}] = summary.runs
    assert [%{run_id: "trajectory-run", number: 1, status: "completed"}] = summary.turns
    assert summary.fidelity.level == "complete"

    assert {:ok, compact} =
             Conversations.trajectory(
               %{"conversation" => c.target, "detail_level" => "compact", "max_chars" => 16_000},
               c.context
             )

    tool = Enum.find(compact.records, &(&1.kind == "tool"))
    assert tool.duration_ms == 12
    assert tool.timing_fidelity == "exact"
    refute Map.has_key?(tool, :input)
    refute Map.has_key?(tool, :output)

    assert {:ok, small_page} =
             Conversations.trajectory(
               %{"conversation" => c.target, "detail_level" => "compact", "max_chars" => 2_000},
               c.context
             )

    assert small_page.records != []
    assert String.length(Handbean.JSON.encode!(small_page)) <= 2_000

    assert {:ok, full} =
             Conversations.trajectory(
               %{"conversation" => c.target, "detail_level" => "full", "max_chars" => 16_000},
               c.context
             )

    full_tool = Enum.find(full.records, &(&1.kind == "tool"))
    encoded = Handbean.JSON.encode!(full_tool)
    assert encoded =~ "lib/app.ex"
    refute encoded =~ "top-secret"
    refute encoded =~ "sub-token-value"

    assert {:error, :not_accessible} =
             Conversations.trajectory(%{"conversation" => c.foreign}, c.context)

    assert {:error, :invalid_input} =
             Conversations.trajectory(%{"conversation" => c.target, "turn" => 1}, c.context)
  end

  test "trajectory cursor is bound to the durable snapshot", c do
    for i <- 1..3 do
      {:ok, _} =
        ConversationTranscriptStore.append(c.target, %{
          "id" => "trajectory-page-#{i}",
          "role" => "assistant",
          "content" => "record #{i}"
        })
    end

    input = %{
      "conversation" => c.target,
      "detail_level" => "compact",
      "limit" => 1,
      "max_chars" => 4_000
    }

    assert {:ok, %{records: [first], next_cursor: cursor, truncated: true}} =
             Conversations.trajectory(input, c.context)

    assert is_binary(cursor)

    assert {:ok, %{records: [second]}} =
             Conversations.trajectory(Map.put(input, "cursor", cursor), c.context)

    assert first.sequence < second.sequence

    assert {:ok, _} =
             ConversationTranscriptStore.update(c.target, first.id, %{"content" => "changed"})

    assert {:error, :stale_or_invalid_cursor} =
             Conversations.trajectory(Map.put(input, "cursor", cursor), c.context)
  end

  test "trajectory redacts run errors and recovers lifecycle rows without streaming entries", c do
    assert :ok =
             ConversationStore.record_run_start(c.target, %{
               run_id: "orphan-run",
               model: "provider/model"
             })

    assert :ok =
             ConversationStore.record_turn_start(c.target, %{
               run_id: "orphan-run",
               turn_number: 1
             })

    assert "orphan-run" in Handbean.ConversationTranscriptStore.ConversationStore.unfinished_runs(
             c.target
           )

    assert :ok =
             ConversationStore.record_run_end(c.target, %{
               run_id: "orphan-run",
               status: :error,
               error: "Authorization: Bearer run-secret-value"
             })

    refute "orphan-run" in Handbean.ConversationTranscriptStore.ConversationStore.unfinished_runs(
             c.target
           )

    assert {:ok, trajectory} =
             Conversations.trajectory(
               %{
                 "conversation" => c.target,
                 "run_id" => "orphan-run",
                 "detail_level" => "summary",
                 "max_chars" => 4_000
               },
               c.context
             )

    assert [%{status: "error"}] = trajectory.runs
    assert [%{status: "error"}] = trajectory.turns
    refute Handbean.JSON.encode!(trajectory) =~ "run-secret-value"
  end
end
