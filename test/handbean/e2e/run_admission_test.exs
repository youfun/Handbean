defmodule Handbean.E2E.RunAdmissionTest do
  use Handbean.DataCase, async: false

  alias Handbean.Agent.{CandidateQueue, Coordinator, PendingMessages}
  alias Handbean.PubSub.Session
  alias Handbean.TestSupport.E2EHarness

  @moduletag :e2e

  setup do
    %{workspace: workspace} = E2EHarness.isolate_home!("run-admission")
    {:ok, conversation} = Handbean.ConversationStore.create("default")
    id = conversation["id"]
    Session.subscribe(id)
    on_exit(fn -> E2EHarness.cancel!(id) end)
    parent = self()

    opts = [
      workspace_path: workspace,
      model: "fake",
      provider: Handbean.TestSupport.FakeProvider,
      provider_config: %{
        scenario:
          {:script,
           fn _messages, _tools ->
             send(parent, {:provider_waiting, self()})
             receive do: (:finish -> "Finished")
           end}
      },
      tools: [],
      middleware: [],
      source: :cli,
      streaming: true
    ]

    %{id: id, opts: opts}
  end

  test "queued receipt and transcript name the accepting run, not a fresh run", %{
    id: id,
    opts: opts
  } do
    {:ok, %{run_id: run_id}} = Coordinator.add_message(id, "first", opts)
    assert_receive {:provider_waiting, _}, 5_000
    queued_opts = Keyword.merge(opts, request_id: "queue-request", message_id: "queued")

    assert {:ok, %{action: :enqueued, run_id: ^run_id}} =
             Coordinator.add_message(id, "second", queued_opts)

    assert {:ok, %{action: :enqueued, run_id: ^run_id, replayed: true}} =
             Coordinator.add_message(id, "second", queued_opts)

    entries = E2EHarness.transcript(id)

    assert [%{"id" => "queued", "run_id" => ^run_id, "delivery" => "steer"}] =
             Enum.filter(entries, &(&1["content"] == "second"))
  end

  test "a full queue rejects before writing a user message", %{id: id, opts: opts} do
    {:ok, _} = Coordinator.add_message(id, "first", opts)
    assert_receive {:provider_waiting, _}, 5_000
    {:ok, %{queue_pid: queue}} = Coordinator.status(id)

    for n <- 1..64, do: :ok = CandidateQueue.enqueue(queue, "queued #{n}")

    assert {:error, :queue_full} = Coordinator.add_message(id, "not accepted", opts)
    refute Enum.any?(E2EHarness.transcript(id), &(&1["content"] == "not accepted"))
  end

  test "cancelled queued input recovers from durable history without replay controls", ctx do
    {:ok, %{run_id: run_id}} = Coordinator.add_message(ctx.id, "first", ctx.opts)
    assert_receive {:provider_waiting, provider}, 5_000

    {:ok, _} =
      Coordinator.add_message(ctx.id, "consumed", Keyword.put(ctx.opts, :message_id, "consumed"))

    send(provider, :finish)
    assert_receive {:provider_waiting, _}, 5_000

    {:ok, _} =
      Coordinator.add_message(ctx.id, "not consumed", Keyword.put(ctx.opts, :message_id, "left"))

    {:ok, _} =
      Coordinator.add_message(ctx.id, "undo", Keyword.put(ctx.opts, :message_id, "deleted"))

    :ok = Coordinator.delete_pending_message(ctx.id, "deleted")
    :ok = Coordinator.cancel(ctx.id)
    assert_receive {:agent_event, %{kind: :run_end, payload: %{status: "cancelled"}}}, 5_000

    {:ok, _} =
      Handbean.ConversationTranscriptStore.append(ctx.id, %{
        "id" => "legacy-consumed",
        "role" => "user",
        "content" => "old answered input",
        "delivery" => "steer"
      })

    pending = PendingMessages.reconcile(%{}, [], false, E2EHarness.transcript(ctx.id))
    assert Map.keys(pending) == ["left"]
    assert pending["left"].status == :undelivered
    assert pending["left"].content == "not consumed"

    assert Enum.any?(
             E2EHarness.transcript(ctx.id),
             &(&1["id"] == "consumed" and &1["consumption"] == "consumed")
           )

    checkpoint = Session.snapshot(ctx.id).last_seq
    Session.broadcast_event(ctx.id, :message_delta, %{run_id: run_id, chunk: "late"})
    assert Session.snapshot(ctx.id).last_seq == checkpoint
  end

  test "late events and finish from another run cannot mutate the active run", %{
    id: id,
    opts: opts
  } do
    {:ok, %{run_id: run_id}} = Coordinator.add_message(id, "first", opts)
    assert_receive {:provider_waiting, _}, 5_000
    snapshot = Session.snapshot(id)

    :ok = Session.broadcast_event(id, :message_delta, %{run_id: "old-run", chunk: "stale"})
    :ok = Session.broadcast_event(id, :run_end, %{run_id: "old-run", status: :completed})
    assert {:error, :stale_run} = Session.mark_run_finished(id, "old-run")
    assert {:error, :stale_run} = Session.mark_run_finished(id)

    assert {:error, :stale_run} =
             Session.enqueue_candidate(id, "stale candidate",
               expected_run_id: "old-run",
               persist_candidate?: true
             )

    assert Session.snapshot(id).last_seq == snapshot.last_seq
    assert {:ok, %{running?: true, run_id: ^run_id}} = Coordinator.status(id)
    refute Enum.any?(E2EHarness.transcript(id), &(&1["content"] == "stale candidate"))
  end

  test "next_turn admission persists once with the accepting identity", %{id: id, opts: opts} do
    {:ok, %{run_id: run_id}} = Coordinator.add_message(id, "first", opts)
    assert_receive {:provider_waiting, _}, 5_000

    assert {:ok, %{action: :enqueued, run_id: ^run_id}} =
             Coordinator.add_message(
               id,
               "future",
               Keyword.merge(opts, deliver_as: :next_turn, message_id: "future")
             )

    assert [%{"id" => "future", "run_id" => ^run_id, "delivery" => "next_turn"}] =
             Enum.filter(E2EHarness.transcript(id), &(&1["content"] == "future"))
  end

  test "sending at a sealed run boundary starts a new run without duplicating inbound", %{
    id: id,
    opts: opts
  } do
    {:ok, %{run_id: previous_run}} = Coordinator.add_message(id, "first", opts)
    assert_receive {:provider_waiting, provider}, 5_000
    {:ok, %{queue_pid: queue}} = Coordinator.status(id)
    :ok = CandidateQueue.seal(queue)
    send(provider, :finish)

    assert {:ok, %{action: :started, run_id: next_run}} =
             Coordinator.add_message(
               id,
               "at boundary",
               Keyword.put(opts, :message_id, "boundary")
             )

    assert next_run != previous_run
    assert_receive {:provider_waiting, next_provider}, 5_000
    send(next_provider, :finish)

    assert_receive {:agent_event,
                    %{kind: :run_end, payload: %{run_id: ^next_run, status: :completed}}},
                   5_000

    assert [%{"id" => "boundary", "run_id" => ^next_run, "delivery" => "new_run"}] =
             Enum.filter(E2EHarness.transcript(id), &(&1["content"] == "at boundary"))
  end
end
