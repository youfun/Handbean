defmodule Handbean.ConversationCollaborationTest do
  use Handbean.DataCase, async: false

  alias Handbean.ConversationCollaborationSupport, as: Support
  alias Handbean.ConversationCollaborationSupport.FailingInboundStore
  alias Handbean.{ConversationTranscriptStore, Conversations}
  alias Handbean.Conversations.Collaboration

  setup do
    Support.setup()
  end

  test "Coordinator sends once, preserves trusted origin, defaults steer and allows explicit follow_up",
       c do
    {:ok, ack} = Handbean.Agent.Coordinator.add_message(c.target, "Human task", c.opts)
    assert_receive {:held, _, _}, 2000

    assert {:ok, %{state: "running", current_run: run}} =
             Conversations.status(%{"conversation" => c.target}, c.context)

    assert run == ack.run_id
    :sys.replace_state(ack.run_pid, &%{&1 | status: :awaiting_approval})

    assert {:ok, %{state: "awaiting_approval"}} =
             Conversations.status(%{"conversation" => c.target}, c.context)

    :sys.replace_state(ack.run_pid, &%{&1 | status: :running})
    input = %{"conversation" => c.target, "message" => "Report", "request_id" => "same"}
    tasks = for _ <- 1..4, do: Task.async(fn -> Collaboration.send_message(input, c.context) end)
    receipts = Enum.map(tasks, &Task.await/1)
    assert Enum.all?(receipts, &match?({:ok, %{delivery: "enqueued"}}, &1))
    {:ok, first} = hd(receipts)

    assert {:ok, %{delivery: "enqueued"}} =
             Collaboration.send_message(
               %{input | "request_id" => "later"} |> Map.put("deliver_as", "follow_up"),
               c.context
             )

    {:ok, entries} = ConversationTranscriptStore.list(c.target)
    inbound = Enum.filter(entries, &(get_in(&1, ["origin", "kind"]) == "conversation"))
    assert length(inbound) == 2
    assert Enum.map(inbound, & &1["delivery"]) == ["steer", "follow_up"]
    assert hd(inbound)["origin"]["conversation_id"] == c.source
    assert hd(inbound)["origin"]["run_id"] == "source-run"
    assert hd(inbound)["id"] == first.message_id
    assert hd(inbound)["origin"]["purpose"] == "request"
    assert hd(inbound)["origin"]["expect_report"]
    assert hd(inbound)["consumption"] == "pending"

    Handbean.Agent.TranscriptPersistence.handle_event(
      c.target,
      {:candidate_message_injected, %{message_ids: [first.message_id]}},
      []
    )

    {:ok, entries} = ConversationTranscriptStore.list(c.target)
    assert Enum.find(entries, &(&1["id"] == first.message_id))["consumption"] == "consumed"
  end

  test "inbound persistence failure is uncertain, retained and never dispatched twice", c do
    context = %{
      c.context
      | conversation_run_opts: Keyword.put(c.opts, :transcript_store, FailingInboundStore)
    }

    input = %{"conversation" => c.target, "message" => "Must survive", "request_id" => "fail"}
    assert {:ok, %{delivery: "delivery_unknown"}} = Collaboration.send_message(input, context)
    assert {:ok, %{delivery: "delivery_unknown"}} = Collaboration.send_message(input, context)
    refute_receive {:held, _, _}, 100
    assert {:ok, []} = ConversationTranscriptStore.list(c.target)
  end

  test "blank optional handoff starts a new exchange and matches an omitted-field retry", c do
    input = %{
      "conversation" => c.target,
      "message" => "Coordinate work",
      "request_id" => "blank-handoff"
    }

    assert {:ok, receipt} =
             Collaboration.send_message(Map.put(input, "handoff_id", ""), c.context)

    assert {:ok, ^receipt} = Collaboration.send_message(input, c.context)

    assert {:error, :idempotency_conflict} =
             Collaboration.send_message(Map.put(input, "purpose", "notification"), c.context)

    assert {:error, :invalid_input} =
             Collaboration.send_message(
               %{input | "request_id" => "invalid-purpose"} |> Map.put("purpose", "bogus"),
               c.context
             )

    assert String.starts_with?(receipt.handoff_id, "handoff-")
    assert_receive {:held, _, _}, 2000

    assert {:ok, entries} = ConversationTranscriptStore.list(c.source)
    assert Enum.count(entries, &(&1["content_type"] == "conversation_handoff")) == 1
  end

  test "independent handoffs, replies and retries preserve their exact association", c do
    {:ok, first} =
      Collaboration.create(
        %{"title" => "Audit", "message" => "ALPHA request", "request_id" => "alpha"},
        c.context
      )

    assert_receive {:held, _, _}, 2000

    input = %{
      "conversation" => first.conversation,
      "message" => "BETA request",
      "request_id" => "beta"
    }

    {:ok, second} = Collaboration.send_message(input, c.context)
    assert first.handoff_id != second.handoff_id
    assert {:ok, ^second} = Collaboration.send_message(input, c.context)

    child_context = %{c.context | conversation_id: first.conversation}

    for {receipt, label} <- [{first, "ALPHA"}, {second, "BETA"}] do
      reply = %{
        "message" => "#{label} result",
        "request_id" => "#{label}-result",
        "handoff_id" => receipt.handoff_id
      }

      assert {:ok, result} = Collaboration.reply(reply, child_context)
      assert result.handoff_id == receipt.handoff_id
      assert {:ok, ^result} = Collaboration.reply(reply, child_context)
    end

    {:ok, parent_entries} = ConversationTranscriptStore.list(c.source)
    {:ok, child_entries} = ConversationTranscriptStore.list(first.conversation)
    assert Enum.count(parent_entries, &(&1["content_type"] == "conversation_handoff")) == 2

    for {receipt, label} <- [{first, "ALPHA"}, {second, "BETA"}] do
      [request] =
        Enum.filter(child_entries, &(get_in(&1, ["origin", "handoff_id"]) == receipt.handoff_id))

      assert request["content"] =~ "#{label} request"

      [result] =
        Enum.filter(parent_entries, &(get_in(&1, ["origin", "handoff_id"]) == receipt.handoff_id))

      assert result["content"] =~ "#{label} result"
      assert result["origin"]["important"]
    end

    assert {:error, :invalid_handoff_id} =
             Collaboration.send_message(
               Map.put(input, "request_id", "forged") |> Map.put("handoff_id", "invented"),
               c.context
             )

    assert {:error, :invalid_handoff_id} =
             Collaboration.send_message(
               %{input | "conversation" => c.target, "request_id" => "wrong-peer"}
               |> Map.put("handoff_id", first.handoff_id),
               c.context
             )

    assert {:error, :idempotency_conflict} =
             Collaboration.send_message(Map.put(input, "handoff_id", first.handoff_id), c.context)
  end

  test "a child can explicitly message any authorized conversation and receive its reply", c do
    {:ok, child} =
      Collaboration.create(
        %{"title" => "Audit", "message" => "First", "request_id" => "first"},
        c.context
      )

    assert_receive {:held, _, _}, 2000
    {:ok, parent_entries_before} = ConversationTranscriptStore.list(c.source)
    child_context = %{c.context | conversation_id: child.conversation, run_id: "child-run"}

    assert {:ok, outbound} =
             Collaboration.send_message(
               %{
                 "conversation" => c.target,
                 "message" => "Question for an unrelated conversation",
                 "request_id" => "child-to-target"
               },
               child_context
             )

    assert_receive {:held, _, _}, 2000
    assert {:ok, target_status} = Handbean.Agent.Runner.status(c.target)

    target_agent_config =
      target_status.run_pid |> :sys.get_state() |> then(&Handbean.Agent.Config.from_opts(&1.opts))

    assert target_agent_config.context.origin_conversation_id == child.conversation
    refute Map.has_key?(target_agent_config.context, :created_by_conversation_id)

    assert target_agent_config.system_prompt =~
             "active_origin_conversation_id: #{child.conversation}"

    assert {:ok, target_entries} = ConversationTranscriptStore.list(c.target)

    assert Enum.any?(target_entries, fn entry ->
             entry["content"] =~ "Source conversation_id: #{child.conversation}" and
               entry["content"] =~ "Handoff_id: #{outbound.handoff_id}"
           end)

    target_context = %{c.context | conversation_id: c.target, run_id: "target-run"}

    assert {:ok, reply} =
             Collaboration.send_message(
               %{
                 "conversation" => child.conversation,
                 "message" => "Direct answer",
                 "request_id" => "target-to-child",
                 "handoff_id" => outbound.handoff_id
               },
               target_context
             )

    assert reply.handoff_id == outbound.handoff_id
    {:ok, parent_entries_after} = ConversationTranscriptStore.list(c.source)
    assert parent_entries_after == parent_entries_before

    assert {:ok, child_entries} = ConversationTranscriptStore.list(child.conversation)

    assert Enum.any?(child_entries, fn entry ->
             entry["content"] =~ "Direct answer" and
               entry["content"] =~ "Source conversation_id: #{c.target}" and
               get_in(entry, ["origin", "conversation_id"]) == c.target and
               get_in(entry, ["origin", "handoff_id"]) == outbound.handoff_id
           end)
  end
end
