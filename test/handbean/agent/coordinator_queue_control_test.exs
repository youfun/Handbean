defmodule Handbean.Agent.CoordinatorQueueControlTest do
  use Handbean.DataCase, async: false

  alias Handbean.Agent.Coordinator
  alias Handbean.Agent.CoordinatorTestSupport
  alias Handbean.Agent.CoordinatorTestSupport.TestDelivery
  alias Handbean.PubSub.Session

  import Handbean.Agent.CoordinatorTestSupport

  setup context do
    CoordinatorTestSupport.setup_coordinator(context)
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
end
