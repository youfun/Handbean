defmodule Handbean.Agent.CoordinatorAdmissionConcurrencyTest do
  use Handbean.DataCase, async: false

  alias Handbean.Agent.Coordinator
  alias Handbean.Agent.CoordinatorTestSupport
  alias Handbean.Agent.CoordinatorTestSupport.CrashProvider
  alias Handbean.Agent.CoordinatorTestSupport.FailingInboundStore
  alias Handbean.Agent.CoordinatorTestSupport.HoldProvider
  alias Handbean.PubSub.Session

  import Handbean.Agent.CoordinatorTestSupport

  setup context do
    CoordinatorTestSupport.setup_coordinator(context)
  end

  test "deleted conversation checkout never falls back to workspace policy root" do
    checkout =
      Path.join(System.tmp_dir!(), "deleted-checkout-#{System.unique_integer([:positive])}")

    File.mkdir_p!(checkout)
    sid = "coord-deleted-checkout-#{System.unique_integer([:positive])}"

    assert {:ok, _conversation} =
             Handbean.ConversationStore.create("default", id: sid, checkout_path: checkout)

    File.rm_rf!(checkout)
    policy_root = tmp_no_policy_workspace()

    assert {:error, :checkout_unavailable} =
             Coordinator.start_run(sid, "do not run in main", opts(workspace_path: policy_root))

    assert {:error, :not_found} = Handbean.Agent.Runner.status(sid)
  end

  test "new-run request identity suppresses a racing follow-up in the same Handbean run" do
    sid = "coord-initial-dedupe-#{System.unique_integer([:positive])}"
    request_id = "request-#{Ecto.UUID.generate()}"
    message_id = "message-#{Ecto.UUID.generate()}"
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)

    assert {:ok, %{action: :started, run_id: run_id}} =
             Coordinator.add_message(
               sid,
               "one observation",
               opts(
                 request_id: request_id,
                 message_id: message_id,
                 provider: HoldProvider,
                 provider_config: %{notify: self()}
               )
             )

    assert_receive {:held, provider_pid}
    assert {:ok, %{queue_pid: queue_pid}} = Handbean.Agent.Runner.status(sid)

    assert :ok =
             Handbean.Agent.CandidateQueue.enqueue(queue_pid, "one observation",
               request_id: request_id,
               message_id: message_id,
               run_id: run_id,
               deliver_as: :follow_up,
               persist_candidate?: false
             )

    assert [] = Handbean.Agent.CandidateQueue.drain_follow_up(queue_pid)
    send(provider_pid, :release)
    assert_receive_run_end(sid)
  end

  test "require_idle admission ignores a stale Session projection and uses Runner ownership" do
    sid = "coord-stale-session-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)
    {:ok, _session} = Session.start_or_get(session_id: sid, model: "fake")
    {:ok, queue} = Handbean.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
    :ok = Session.attach_run(sid, self(), queue, run_id: "stale-run")
    assert %{meta: %{running?: true, run_id: "stale-run"}} = Session.snapshot(sid)

    assert {:ok, %{action: :started, run_id: run_id}} =
             Coordinator.add_message(
               sid,
               "scheduled",
               opts(source: :schedule, require_idle?: true, request_id: Ecto.UUID.generate())
             )

    assert run_id != "stale-run"
    assert_receive_run_end(sid)
  end

  test "inbound write failure rejects both idle entry points before starting a run" do
    for entry_point <- [:add_message, :start_run] do
      sid = "coord-write-failure-#{entry_point}-#{System.unique_integer([:positive])}"
      {:ok, _} = Handbean.ConversationStore.create("default", id: sid)

      assert {:error, :eisdir} =
               apply(Coordinator, entry_point, [
                 sid,
                 "not accepted",
                 opts(transcript_store: FailingInboundStore)
               ])

      assert {:error, :not_found} = Handbean.Agent.Runner.status(sid)
      assert %{meta: %{running?: false}, events: []} = Session.snapshot(sid)
    end
  end

  test "inbound write failure leaves running queues unchanged" do
    sid = "coord-queue-write-failure-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)
    {:ok, _session} = Session.start_or_get(session_id: sid, model: "fake")
    queue = start_supervised!({Handbean.Agent.CandidateQueue, session_id: sid, owner: self()})
    :ok = Session.attach_run(sid, self(), queue)

    for delivery <- [:steer, :follow_up] do
      assert {:error, :eisdir} =
               Coordinator.add_message(
                 sid,
                 "not queued",
                 opts(deliver_as: delivery, transcript_store: FailingInboundStore)
               )
    end

    assert [] = Handbean.Agent.CandidateQueue.get_messages(queue)
    assert %{events: []} = Session.snapshot(sid)
  end

  test "task_instructions while running is rejected and never enqueued" do
    sid = "coord-review-running-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)
    {:ok, _session} = Session.start_or_get(session_id: sid, model: "fake")
    {:ok, queue} = Handbean.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
    :ok = Session.attach_run(sid, self(), queue)

    assert {:error, :run_in_progress} =
             Coordinator.add_message(
               sid,
               "write a review",
               opts(task_instructions: "trusted skill body")
             )

    assert Handbean.Agent.CandidateQueue.get_messages(queue) == []
    refute inbound_user(sid)
  end

  test "concurrent task_instructions cannot silently enqueue on a racing run" do
    sid = "coord-review-race-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)
    :ok = Session.subscribe(sid)
    parent = self()

    hold_opts =
      opts(
        provider: HoldProvider,
        provider_config: %{notify: parent},
        streaming: false
      )

    tasks =
      Enum.map(["first review", "second review"], fn content ->
        Task.async(fn ->
          Coordinator.add_message(
            sid,
            content,
            Keyword.put(hold_opts, :task_instructions, content)
          )
        end)
      end)

    results = Enum.map(tasks, &Task.await(&1, 5_000))

    assert Enum.any?(results, &match?({:ok, %{action: :started}}, &1))
    assert Enum.any?(results, &match?({:error, :run_in_progress}, &1))
    refute Enum.any?(results, &match?({:ok, %{action: :enqueued}}, &1))

    receive do
      {:held, pid} -> send(pid, :release)
    after
      5_000 -> flunk("hold provider never started")
    end

    contents =
      case Handbean.ConversationTranscriptStore.list(sid) do
        {:ok, entries} ->
          entries
          |> Enum.filter(&(&1["role"] == "user"))
          |> Enum.map(& &1["content"])

        {:error, _} ->
          []
      end

    assert length(contents) == 1
    assert hd(contents) in ["first review", "second review"]
    refute Enum.any?(contents, &(&1 && String.contains?(&1, "task_instructions")))
    assert_receive {:agent_event, %{kind: :run_end}}, 1_000
  end

  test "require_idle releases its reservation when the conversation is busy" do
    sid = "coord-idle-release-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)
    :ok = Session.subscribe(sid)
    parent = self()

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(
               sid,
               "hold",
               opts(
                 provider: HoldProvider,
                 provider_config: %{notify: parent},
                 streaming: false
               )
             )

    assert_receive {:held, pid}, 5_000
    request_id = "sched-#{sid}-1"

    assert {:error, :busy} = idle_message(sid, request_id)
    assert :error = Handbean.Agent.OperationReceipt.lookup({:message, sid}, request_id)
    assert {:error, :busy} = idle_message(sid, request_id)

    send(pid, :release)
    assert_receive {:agent_event, %{kind: :run_end}}, 1_000
  end

  test "require_idle keeps the reservation when releasing it fails" do
    sid = "coord-idle-unknown-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)
    :ok = Session.subscribe(sid)
    parent = self()

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(
               sid,
               "hold",
               opts(
                 provider: HoldProvider,
                 provider_config: %{notify: parent},
                 streaming: false
               )
             )

    assert_receive {:held, pid}, 5_000
    on_exit(fn -> Application.delete_env(:handbean, :operation_receipt_write_fault) end)

    Application.put_env(:handbean, :operation_receipt_write_fault, fn ->
      case Process.get(:receipt_writes, 0) do
        0 ->
          Process.put(:receipt_writes, 1)
          :ok

        _ ->
          {:error, :injected}
      end
    end)

    request_id = "sched-#{sid}-1"
    assert {:error, :delivery_unknown} = idle_message(sid, request_id)

    assert {:ok, %{"status" => "reserved"}} =
             Handbean.Agent.OperationReceipt.lookup({:message, sid}, request_id)

    assert {:ok, entries} = Handbean.ConversationTranscriptStore.list(sid)

    assert ["hold"] ==
             entries |> Enum.filter(&(&1["role"] == "user")) |> Enum.map(& &1["content"])

    send(pid, :release)
    assert_receive {:agent_event, %{kind: :run_end}}, 1_000
  end

  test "add_message returns no_active_run when idle and require_running? is true" do
    sid = "coord-require-#{System.unique_integer([:positive])}"

    assert {:error, :no_active_run} =
             Coordinator.add_message(sid, "steer with no run", opts(require_running?: true))
  end

  test "task crash is isolated from caller and broadcasts error run_end" do
    sid = "coord-crash-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)

    assert {:ok, %{action: :started, run_pid: pid}} =
             Coordinator.add_message(sid, "boom", opts(provider: CrashProvider))

    assert is_pid(pid)

    assert_receive_run_end(sid)

    %{events: events} = Session.snapshot(sid)
    assert Enum.any?(events, &match?(%{kind: :run_end, payload: %{status: "error"}}, &1))
  end
end
