defmodule Handbean.Agent.CoordinatorTest do
  use Handbean.DataCase, async: false

  alias Handbean.Agent.Coordinator
  alias Handbean.PubSub.Session

  setup do
    old_home = System.get_env("HOME")

    home_dir = Path.join(System.tmp_dir!(), "sigil_coord_home_#{Ecto.UUID.generate()}")

    File.mkdir_p!(home_dir)
    System.put_env("HOME", home_dir)
    previous_host = Application.get_env(:handbean, :host)
    Handbean.Host.put!(%{data_dir: home_dir})

    on_exit(fn ->
      drain_runtime_tasks()
      sync_runtime_observers()

      if old_home, do: System.put_env("HOME", old_home), else: System.delete_env("HOME")

      if previous_host,
        do: Application.put_env(:handbean, :host, previous_host),
        else: Application.delete_env(:handbean, :host)

      remove_home!(home_dir)
    end)

    :ok
  end

  defmodule CrashProvider do
    @behaviour Handbean.Agent.Provider

    @impl true
    def complete(_messages, _tool_defs, _config) do
      raise "intentional provider crash"
    end

    @impl true
    def stream(_messages, _tool_defs, _config, _on_chunk) do
      raise "intentional provider crash"
    end
  end

  defmodule TestDelivery do
    @behaviour Handbean.Delivery

    @impl true
    def deliver(entry, opts) do
      send(Keyword.fetch!(opts, :notify), {:delivered, entry})
      :ok
    end
  end

  defmodule HoldProvider do
    @behaviour Handbean.Agent.Provider

    @impl true
    def complete(_messages, _tool_defs, config) do
      send(Map.fetch!(config, :notify), {:held, self()})

      receive do
        :release -> :ok
      after
        5_000 -> :ok
      end

      {:ok,
       %{
         stop_reason: :end_turn,
         messages: [Handbean.Agent.Message.assistant("ok")],
         usage: %{input_tokens: 1, output_tokens: 1},
         response_metadata: %{id: "hold-provider", model: "fake-model"}
       }}
    end

    @impl true
    def stream(messages, tool_defs, config, _on_chunk), do: complete(messages, tool_defs, config)
  end

  defmodule NotifyProvider do
    @behaviour Handbean.Agent.Provider

    @impl true
    def complete(messages, _tool_defs, config) do
      send(Map.fetch!(config, :notify), {:provider_messages, messages})

      {:ok,
       %{
         stop_reason: :end_turn,
         messages: [Handbean.Agent.Message.assistant("ok")],
         usage: %{input_tokens: 1, output_tokens: 1},
         response_metadata: %{id: "notify-provider", model: "fake-model"}
       }}
    end

    @impl true
    def stream(messages, tool_defs, config, _on_chunk), do: complete(messages, tool_defs, config)
  end

  defmodule FailingInboundStore do
    def append(_conversation_id, _entry, _opts), do: {:error, :eisdir}
  end

  defp tmp_no_policy_workspace do
    dir =
      Path.join(
        System.tmp_dir!(),
        "sigil_coord_nopolicy_" <> Integer.to_string(System.unique_integer([:positive]))
      )

    File.mkdir_p!(dir)

    old = System.get_env("HANDBEAN_MODELS_FILE")
    models_path = Path.join(dir, "models.json")

    File.write!(
      models_path,
      ~s({"providers": {"fake": {"baseUrl": "http://localhost", "api": "openai-chat-completions", "apiKey": "sk-fake", "models": [{"id": "fake-model", "name": "Fake Model"}]}}})
    )

    System.put_env("HANDBEAN_MODELS_FILE", models_path)

    on_exit(fn ->
      if old,
        do: System.put_env("HANDBEAN_MODELS_FILE", old),
        else: System.delete_env("HANDBEAN_MODELS_FILE")

      File.rm_rf(dir)
    end)

    dir
  end

  defp remove_home!(dir) do
    Enum.reduce_while(1..8, :error, fn attempt, _ ->
      case File.rm_rf(dir) do
        {:ok, _} ->
          {:halt, :ok}

        {:error, reason, _path} ->
          if attempt == 8, do: raise("failed to remove #{dir}: #{inspect(reason)}")
          Process.sleep(25 * attempt)
          {:cont, :error}
      end
    end)
  end

  defp drain_runtime_tasks do
    deadline = System.monotonic_time(:millisecond) + 2_000
    await_runtime_tasks(deadline)
  end

  defp await_runtime_tasks(deadline) do
    tasks = Task.Supervisor.children(Handbean.AgentRunTaskSupervisor)

    if tasks != [] and System.monotonic_time(:millisecond) < deadline do
      refs = Enum.map(tasks, &Process.monitor/1)
      timeout = max(deadline - System.monotonic_time(:millisecond), 0)

      Enum.each(refs, fn ref ->
        receive do
          {:DOWN, ^ref, :process, _pid, _reason} -> :ok
        after
          timeout -> Process.demonitor(ref, [:flush])
        end
      end)

      await_runtime_tasks(deadline)
    end
  end

  defp sync_runtime_observers do
    for name <- [Handbean.Runtime.TaskTracker, Handbean.Schedule.Recorder],
        pid = Process.whereis(name),
        is_pid(pid) do
      :sys.get_state(pid)
    end
  end

  defp idle_message(sid, request_id) do
    Coordinator.add_message(
      sid,
      "later",
      opts(source: :schedule, require_idle?: true, request_id: request_id, deliver_as: :follow_up)
    )
  end

  defp opts(extra \\ []) do
    Keyword.merge(
      [
        workspace_path: tmp_no_policy_workspace(),
        model: "fake/fake-model",
        provider: Handbean.TestSupport.FakeProvider,
        provider_config: %{scenario: :simple_answer},
        tools: [],
        source: :cli,
        streaming: false,
        max_turns: 3
      ],
      extra
    )
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

  test "deleting a pending message preserves the other transcript entries" do
    sid = "coord-delete-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)
    {:ok, _session} = Session.start_or_get(session_id: sid, model: "fake")
    queue = start_supervised!({Handbean.Agent.CandidateQueue, session_id: sid, owner: self()})
    :ok = Session.attach_run(sid, self(), queue)

    assert {:ok, _} = Coordinator.add_message(sid, "remove", opts(message_id: "pending-delete"))
    assert {:ok, _} = Coordinator.add_message(sid, "keep", opts(message_id: "pending-keep"))

    assert {:ok, saved} =
             Handbean.ConversationTranscriptStore.append(sid, %{
               "id" => "reply",
               "content" => "working"
             })

    assert :ok = Coordinator.delete_pending_message(sid, "pending-delete")
    assert [%{message: %{id: "pending-keep"}}] = Handbean.Agent.CandidateQueue.get_messages(queue)
    assert {:ok, [kept, ^saved]} = Handbean.ConversationTranscriptStore.list(sid)
    assert kept["id"] == "pending-keep"
    assert {:error, :not_found} = Coordinator.delete_pending_message(sid, "pending-delete")
  end

  test "promoting a follow-up preserves the message and updates its durable delivery" do
    sid = "coord-promote-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)
    {:ok, _session} = Session.start_or_get(session_id: sid, model: "fake")
    queue = start_supervised!({Handbean.Agent.CandidateQueue, session_id: sid, owner: self()})
    :ok = Session.attach_run(sid, self(), queue)

    assert {:ok, _} =
             Coordinator.add_message(
               sid,
               "send this now",
               opts(message_id: "pending-promote", deliver_as: :follow_up)
             )

    assert :ok = Coordinator.promote_pending_message(sid, "pending-promote")
    assert [] = Handbean.Agent.CandidateQueue.drain_follow_up(queue)

    assert [%Handbean.Agent.Message{id: "pending-promote", content: "send this now"}] =
             Handbean.Agent.CandidateQueue.drain_steer(queue)

    assert {:ok, [entry]} = Handbean.ConversationTranscriptStore.list(sid)
    assert entry["id"] == "pending-promote"
    assert entry["delivery"] == "steer"
    assert entry["interrupts_work"] == true
  end

  test "add_message starts a supervised run when session is idle" do
    sid = "coord-idle-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)

    assert {:ok, %{action: :started, run_pid: pid}} =
             Coordinator.add_message(sid, "hello", opts())

    assert is_pid(pid)
    assert inbound_user(sid)["delivery"] == "new_run"
    assert inbound_user(sid)["interrupts_work"] == false
    assert_receive_run_end(sid)
  end

  test "idle add_message writes new_run even when deliver_as is explicit follow_up or steer" do
    sid = "coord-idle-follow-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(sid, "queued wording", opts(deliver_as: :follow_up))

    assert %{
             "content" => "queued wording",
             "delivery" => "new_run",
             "interrupts_work" => false
           } = inbound_user(sid)

    assert_receive_run_end(sid)

    sid2 = "coord-idle-steer-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid2)

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(sid2, "steer wording", opts(deliver_as: :steer))

    assert %{
             "content" => "steer wording",
             "delivery" => "new_run",
             "interrupts_work" => false
           } = inbound_user(sid2)

    assert_receive_run_end(sid2)
  end

  test "add_message enqueues candidate when session is running" do
    sid = "coord-running-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)
    {:ok, _session} = Session.start_or_get(session_id: sid, model: "fake")
    {:ok, queue} = Handbean.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
    :ok = Session.attach_run(sid, self(), queue)

    assert {:ok, %{action: :enqueued, run_pid: nil}} =
             Coordinator.add_message(sid, "steer this", opts())

    assert [%Handbean.Agent.Message{role: :user, content: "steer this"}] =
             Handbean.Agent.CandidateQueue.drain_steer(queue)

    assert %{
             "content" => "steer this",
             "delivery" => "steer",
             "interrupts_work" => true
           } = inbound_user(sid)
  end

  test "add_message enqueues to follow_up queue when running with explicit deliver_as" do
    sid = "coord-running-follow-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)
    {:ok, _session} = Session.start_or_get(session_id: sid, model: "fake")
    {:ok, queue} = Handbean.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
    :ok = Session.attach_run(sid, self(), queue)

    assert {:ok, %{action: :enqueued, run_pid: nil}} =
             Coordinator.add_message(sid, "follow up task", opts(deliver_as: :follow_up))

    # Message must land in follow_up queue, NOT steer queue
    assert [%Handbean.Agent.Message{role: :user, content: "follow up task"}] =
             Handbean.Agent.CandidateQueue.drain_follow_up(queue)

    assert [] = Handbean.Agent.CandidateQueue.drain_steer(queue)

    assert %{
             "content" => "follow up task",
             "delivery" => "follow_up",
             "interrupts_work" => false
           } = inbound_user(sid)
  end

  test "add_message enqueues to steer queue when running with explicit deliver_as steer" do
    sid = "coord-running-steer-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)
    {:ok, _session} = Session.start_or_get(session_id: sid, model: "fake")
    {:ok, queue} = Handbean.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
    :ok = Session.attach_run(sid, self(), queue)

    assert {:ok, %{action: :enqueued, run_pid: nil}} =
             Coordinator.add_message(sid, "steer correction", opts(deliver_as: :steer))

    assert [%Handbean.Agent.Message{role: :user, content: "steer correction"}] =
             Handbean.Agent.CandidateQueue.drain_steer(queue)

    assert [] = Handbean.Agent.CandidateQueue.drain_follow_up(queue)

    assert %{
             "content" => "steer correction",
             "delivery" => "steer",
             "interrupts_work" => true
           } = inbound_user(sid)
  end

  test "stamps one id onto Message, transcript, and candidate queue" do
    sid = "coord-id-align-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)
    {:ok, _session} = Session.start_or_get(session_id: sid, model: "fake")
    {:ok, queue} = Handbean.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
    :ok = Session.attach_run(sid, self(), queue)

    id = "msg-shared-#{System.unique_integer([:positive])}"
    message = %Handbean.Agent.Message{role: :user, content: "aligned", id: nil}

    assert {:ok, %{action: :enqueued}} =
             Coordinator.add_message(
               sid,
               message,
               opts(inbound_id: id, transcript_id: id, message_id: id)
             )

    assert [%Handbean.Agent.Message{id: ^id, content: "aligned"}] =
             Handbean.Agent.CandidateQueue.drain_steer(queue)

    assert inbound_user(sid)["id"] == id
    assert inbound_user(sid)["inbound_id"] == id
  end

  test "generates one queue id for a string message with no ids" do
    sid = "coord-noid-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)
    {:ok, _session} = Session.start_or_get(session_id: sid, model: "fake")
    {:ok, queue} = Handbean.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
    :ok = Session.attach_run(sid, self(), queue)

    assert {:ok, %{action: :enqueued}} = Coordinator.add_message(sid, "sns plain", opts())

    assert [%Handbean.Agent.Message{id: generated, content: "sns plain"}] =
             Handbean.Agent.CandidateQueue.drain_steer(queue)

    assert is_binary(generated) and generated != "" and generated != "msg-user-unknown"
    assert inbound_user(sid)["id"] == generated
    assert inbound_user(sid)["inbound_id"] == generated
  end

  test "opts message_id wins over Message.id and transcript_id; inbound_id stays independent" do
    sid = "coord-id-conflict-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)
    {:ok, _session} = Session.start_or_get(session_id: sid, model: "fake")
    {:ok, queue} = Handbean.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
    :ok = Session.attach_run(sid, self(), queue)

    message = %Handbean.Agent.Message{role: :user, content: "conflict", id: "struct-id"}

    assert {:ok, %{action: :enqueued}} =
             Coordinator.add_message(
               sid,
               message,
               opts(message_id: "opt-id", transcript_id: "tr-id", inbound_id: "ack-id")
             )

    assert [%Handbean.Agent.Message{id: "opt-id", content: "conflict"}] =
             Handbean.Agent.CandidateQueue.drain_steer(queue)

    assert inbound_user(sid)["id"] == "opt-id"
    assert inbound_user(sid)["inbound_id"] == "ack-id"
  end

  test "SNS entry with explicit deliver_as is not overridden to steer" do
    old_home = System.get_env("HOME")

    home_dir =
      Path.join(System.tmp_dir!(), "sigil_coord_sns_follow_#{System.unique_integer([:positive])}")

    System.put_env("HOME", home_dir)

    on_exit(fn ->
      if old_home, do: System.put_env("HOME", old_home), else: System.delete_env("HOME")
      if File.exists?(home_dir), do: remove_home!(home_dir)
    end)

    sid = "coord-sns-follow-#{System.unique_integer([:positive])}"
    {:ok, _conversation} = Handbean.ConversationStore.create("default", id: sid)
    {:ok, _session} = Session.start_or_get(session_id: sid, model: "fake")
    {:ok, queue} = Handbean.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
    :ok = Session.attach_run(sid, self(), queue)

    assert {:ok, %{action: :enqueued, run_pid: nil}} =
             Coordinator.add_message(
               sid,
               "sns follow message",
               opts(
                 source: :sns,
                 channel: :sns,
                 deliver_as: :follow_up,
                 delivery: TestDelivery,
                 delivery_opts: [notify: self()]
               )
             )

    # Must land in follow_up, not steer — Coordinator must not overwrite deliver_as
    assert [%Handbean.Agent.Message{role: :user, content: "sns follow message"}] =
             Handbean.Agent.CandidateQueue.drain_follow_up(queue)

    assert [] = Handbean.Agent.CandidateQueue.drain_steer(queue)

    assert %{
             "content" => "sns follow message",
             "delivery" => "follow_up",
             "interrupts_work" => false,
             "channel" => "sns"
           } = inbound_user(sid)
  end

  test "SNS running without deliver_as defaults to steer" do
    sid = "coord-sns-steer-default-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)
    {:ok, _session} = Session.start_or_get(session_id: sid, model: "fake")
    {:ok, queue} = Handbean.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
    :ok = Session.attach_run(sid, self(), queue)

    assert {:ok, %{action: :enqueued}} =
             Coordinator.add_message(
               sid,
               "sns steer default",
               opts(source: :sns, channel: :sns)
             )

    assert [%Handbean.Agent.Message{content: "sns steer default"}] =
             Handbean.Agent.CandidateQueue.drain_steer(queue)

    assert %{
             "delivery" => "steer",
             "interrupts_work" => true,
             "channel" => "sns"
           } = inbound_user(sid)
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

  test "new runs include durable transcript history before the new prompt" do
    sid = "coord-history-#{System.unique_integer([:positive])}"

    assert {:ok, _conversation} = Handbean.ConversationStore.create("default", id: sid)

    assert {:ok, _} =
             Handbean.ConversationTranscriptStore.append(sid, %{
               "id" => "old-user",
               "role" => "user",
               "content" => "Earlier user context",
               "delivery" => "steer",
               "interrupts_work" => true,
               "metadata" => %{"source" => "cli", "delivery" => "steer"}
             })

    assert {:ok, _} =
             Handbean.ConversationTranscriptStore.append(sid, %{
               "id" => "old-assistant",
               "role" => "assistant",
               "content" => "Earlier assistant answer"
             })

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(
               sid,
               "New prompt",
               opts(provider: NotifyProvider, provider_config: %{notify: self()})
             )

    assert_receive {:provider_messages, messages}

    assert Enum.map(messages, &{&1.role, &1.content}) == [
             {:user, "Earlier user context"},
             {:assistant, "Earlier assistant answer"},
             {:user, "New prompt"}
           ]

    Enum.each(messages, fn message ->
      assert %Handbean.Agent.Message{} = message
      refute Map.has_key?(Map.from_struct(message), :delivery)
      refute Map.has_key?(Map.from_struct(message), :interrupts_work)
      refute Map.has_key?(Map.from_struct(message), :metadata)
    end)

    assert_receive_run_end(sid)
  end

  test "removed observational memory model does not block an unrestricted workspace" do
    sid = "coord-stale-om-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(
               sid,
               "hello",
               opts(
                 om: %{
                   enabled: true,
                   model: "xai/grok-4.7"
                 }
               )
             )

    assert_receive_run_end(sid)
  end

  test "allowlisted workspace still rejects a catalog observational memory model" do
    sid = "coord-restricted-om-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)
    # The helper writes models.json inside the workspace and points
    # HANDBEAN_MODELS_FILE at it. Policy must live in a different directory,
    # otherwise saving the catalog overwrites the allowlist.
    workspace =
      Path.join(System.tmp_dir!(), "sigil_coord_allow_#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)

    File.mkdir_p!(Path.dirname(Handbean.WorkspaceSettings.path(workspace)))

    File.write!(
      Handbean.WorkspaceSettings.path(workspace),
      ~s({"models":{"allow":{"providers":{"fake":{"models":["fake-model"]}}}}})
    )

    run_opts =
      opts(
        workspace_path: workspace,
        om: %{enabled: true, model: "other/other-model"}
      )
      |> Keyword.delete(:provider)

    # opts/1 writes a one-model catalog. Replace it after that call so the
    # rejected observer model is present, then excluded by the allowlist.
    File.write!(
      System.fetch_env!("HANDBEAN_MODELS_FILE"),
      ~s({"providers":{"fake":{"baseUrl":"http://localhost","api":"openai-chat-completions","apiKey":"sk-fake","models":[{"id":"fake-model","name":"Fake Model"}]},"other":{"baseUrl":"http://localhost","api":"openai-chat-completions","apiKey":"sk-other","models":[{"id":"other-model","name":"Other Model"}]}}})
    )

    assert {:error, reason} =
             Coordinator.add_message(
               sid,
               "hello",
               run_opts
             )

    assert reason =~ "other/other-model"
    File.rm_rf(workspace)
  end

  test "missing required opts return structured error" do
    sid = "coord-missing-#{System.unique_integer([:positive])}"

    assert {:error, {:missing_opts, missing}} = Coordinator.add_message(sid, "hello", [])
    assert :workspace_path in missing
    assert :model in missing
    assert :provider_config in missing
    assert :tools in missing
    assert :source in missing
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

  test "SNS-like source persists inbound transcript and delivers assistant outbound" do
    old_home = System.get_env("HOME")

    home_dir =
      Path.join(System.tmp_dir!(), "sigil_coord_sns_home_#{System.unique_integer([:positive])}")

    System.put_env("HOME", home_dir)
    Handbean.Host.put!(%{data_dir: home_dir})

    on_exit(fn ->
      if old_home, do: System.put_env("HOME", old_home), else: System.delete_env("HOME")
      if File.exists?(home_dir), do: remove_home!(home_dir)
    end)

    {:ok, conversation} = Handbean.ConversationStore.create("default", id: "coord-sns")
    sid = conversation["id"]

    assert {:ok, %{action: :started, run_id: run_id}} =
             Coordinator.add_message(
               sid,
               "hello from sns",
               opts(
                 source: :sns,
                 channel: :sns,
                 delivery: TestDelivery,
                 delivery_opts: [notify: self()],
                 provider: Handbean.TestSupport.FakeProvider,
                 provider_config: %{scenario: :simple_answer},
                 streaming: false
               )
             )

    assert is_binary(run_id)

    assert_receive {:delivered, %{"role" => "assistant", "delivery_delta" => delivered_delta}},
                   2_000

    assert delivered_delta =~ "Hello!"
    assert_receive_run_end(sid)

    messages = Handbean.ConversationStore.load_messages(sid)

    assert %{
             "role" => "user",
             "direction" => "inbound",
             "channel" => "sns",
             "content" => "hello from sns",
             "delivery" => "new_run",
             "interrupts_work" => false
           } = Enum.find(messages, &(&1["role"] == "user"))

    assert %{
             "role" => "assistant",
             "direction" => "outbound",
             "channel" => "sns",
             "content" => content
           } = Enum.find(messages, &(&1["role"] == "assistant"))

    assert content =~ "Hello!"
  end

  defp inbound_user(sid) do
    sid
    |> Handbean.ConversationStore.load_messages()
    |> Enum.find(&(&1["role"] == "user"))
  end

  defp assert_receive_run_end(sid) do
    deadline = System.monotonic_time(:millisecond) + 1_000
    wait_for_run_end(sid, deadline)
  end

  defp wait_for_run_end(sid, deadline) do
    %{events: events} = Session.snapshot(sid)

    if Enum.any?(events, &match?(%{kind: :run_end}, &1)) do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("expected run_end event for #{sid}")
      else
        Process.sleep(10)
        wait_for_run_end(sid, deadline)
      end
    end
  end

  # ── Workspace model policy enforcement ──

  describe "workspace model policy enforcement" do
    setup do
      old_models_file = System.get_env("HANDBEAN_MODELS_FILE")

      tmp_dir =
        Path.join(System.tmp_dir!(), "sigil_coord_policy_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)

      # Write a global config with two providers / two models each
      File.write!(
        Path.join(tmp_dir, "models.json"),
        Jason.encode!(%{
          "defaultProvider" => "cloud-provider",
          "defaultModel" => "cloud-model-v1",
          "providers" => %{
            "cloud-provider" => %{
              "baseUrl" => "https://cloud.example.com/v1",
              "api" => "openai-chat-completions",
              "apiKey" => "sk-cloud",
              "models" => [
                %{"id" => "cloud-model-v1", "name" => "Cloud Model V1"},
                %{"id" => "cloud-model-v2", "name" => "Cloud Model V2"}
              ]
            },
            "local-llm" => %{
              "baseUrl" => "http://localhost:11434/v1",
              "api" => "openai-chat-completions",
              "apiKey" => "sk-local",
              "models" => [
                %{"id" => "qwen2.5-coder:7b", "name" => "Qwen 2.5 Coder 7B"}
              ]
            }
          }
        })
      )

      System.put_env("HANDBEAN_MODELS_FILE", Path.join(tmp_dir, "models.json"))

      on_exit(fn ->
        if old_models_file,
          do: System.put_env("HANDBEAN_MODELS_FILE", old_models_file),
          else: System.delete_env("HANDBEAN_MODELS_FILE")

        File.rm_rf(tmp_dir)
      end)

      {:ok, tmp_dir: tmp_dir}
    end

    defp write_workspace_policy(workspace_root, policy) do
      settings_dir = Path.join(workspace_root, ".handbean")
      File.mkdir_p!(settings_dir)
      settings_path = Handbean.WorkspaceSettings.path(workspace_root)
      File.write!(settings_path, Jason.encode!(%{"models" => policy}))
      settings_path
    end

    defp restricted_opts(workspace_root, extra \\ []) do
      Keyword.merge(
        [
          workspace_path: workspace_root,
          model: "local-llm/qwen2.5-coder:7b",
          provider: Handbean.TestSupport.FakeProvider,
          provider_config: %{scenario: :simple_answer},
          tools: [],
          source: :cli,
          streaming: false,
          max_turns: 3
        ],
        extra
      )
    end

    test "add_message rejects disallowed model for restrictive workspace policy" do
      ws =
        Path.join(
          System.tmp_dir!(),
          "sigil_coord_policy_restricted_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(ws)

      write_workspace_policy(ws, %{
        "allow" => %{
          "providers" => %{
            "local-llm" => %{"models" => ["qwen2.5-coder:7b"]}
          }
        }
      })

      sid = "coord-policy-reject-#{System.unique_integer([:positive])}"

      # cloud-model-v1 is NOT in the allowlist
      assert {:error, reason} =
               Coordinator.add_message(
                 sid,
                 "hello",
                 restricted_opts(ws, model: "cloud-provider/cloud-model-v1")
               )

      assert reason =~ "not allowed"
    end

    test "add_message accepts allowed model for restrictive workspace policy" do
      ws =
        Path.join(
          System.tmp_dir!(),
          "sigil_coord_policy_allow_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(ws)

      write_workspace_policy(ws, %{
        "allow" => %{
          "providers" => %{
            "local-llm" => %{"models" => ["qwen2.5-coder:7b"]}
          }
        }
      })

      sid = "coord-policy-allow-#{System.unique_integer([:positive])}"
      {:ok, _} = Handbean.ConversationStore.create("default", id: sid)

      assert {:ok, %{action: :started}} =
               Coordinator.add_message(sid, "hello", restricted_opts(ws))

      assert_receive_run_end(sid)
    end

    test "add_message accepts any model when workspace has no policy file" do
      ws =
        Path.join(
          System.tmp_dir!(),
          "sigil_coord_policy_none_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(ws)

      sid = "coord-policy-none-#{System.unique_integer([:positive])}"
      {:ok, _} = Handbean.ConversationStore.create("default", id: sid)

      assert {:ok, %{action: :started}} =
               Coordinator.add_message(
                 sid,
                 "hello",
                 restricted_opts(ws, model: "cloud-provider/cloud-model-v2")
               )

      assert_receive_run_end(sid)
    end
  end
end
