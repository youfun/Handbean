defmodule Handbean.ConversationCollaborationReportingTest do
  use Handbean.DataCase, async: false

  alias Handbean.ConversationCollaborationSupport, as: Support
  alias Handbean.ConversationCollaborationSupport.FailingInboundStore
  alias Handbean.{ConversationStore, ConversationTranscriptStore}
  alias Handbean.Conversations.Collaboration

  setup do
    Support.setup()
  end

  test "progress does not fulfill a request and repeated completion is idempotent", c do
    {:ok, request} =
      Collaboration.send_message(
        %{
          "conversation" => c.target,
          "message" => "Do the work",
          "request_id" => "progress-task"
        },
        c.context
      )

    assert_receive {:held, _, _}, 2_000
    {:ok, target_status} = Handbean.Agent.Runner.status(c.target)
    target_context = %{c.context | conversation_id: c.target, run_id: target_status.run_id}

    assert {:ok, _progress} =
             Collaboration.send_message(
               %{
                 "conversation" => c.source,
                 "message" => "Halfway done",
                 "request_id" => "progress-update",
                 "handoff_id" => request.handoff_id,
                 "purpose" => "progress"
               },
               target_context
             )

    assert_receive {:held, _, _}, 2_000
    {:ok, source_status} = Handbean.Agent.Runner.status(c.source)

    {:ok, _} =
      ConversationTranscriptStore.append(c.target, %{
        "id" => "unique-final",
        "content_type" => "assistant_msg",
        "message_type" => "assistant",
        "role" => "assistant",
        "direction" => "outbound",
        "run_id" => target_status.run_id,
        "phase" => "final",
        "status" => "completed",
        "content" => "UNIQUELY ATTRIBUTABLE FINAL"
      })

    assert :ok =
             Collaboration.completed(c.target, %{status: :completed},
               run_id: target_status.run_id,
               workspace_path: c.context.conversation_run_opts[:workspace_path]
             )

    assert :ok =
             Collaboration.completed(c.target, %{status: :completed},
               run_id: target_status.run_id,
               workspace_path: c.context.conversation_run_opts[:workspace_path]
             )

    {:ok, target_entries} = ConversationTranscriptStore.list(c.target)

    reports =
      Enum.filter(target_entries, fn entry ->
        entry["content_type"] == "conversation_handoff" and entry["automatic_report"] == true
      end)

    assert [report] = reports
    assert report["purpose"] == "result"
    assert report["covered_inbound_ids"] == [request.message_id]
    assert report["content"] =~ "UNIQUELY ATTRIBUTABLE FINAL"

    {:ok, source_entries} = ConversationTranscriptStore.list(c.source)
    automatic = Enum.find(source_entries, &(get_in(&1, ["origin", "automatic_report"]) == true))
    assert get_in(automatic, ["origin", "purpose"]) == "result"
    refute get_in(automatic, ["origin", "expect_report"])

    :ok =
      Handbean.Agent.TranscriptPersistence.handle_event(
        c.source,
        {:candidate_message_injected, %{message_ids: [automatic["id"]]}},
        run_id: source_status.run_id
      )

    outbound_before = Enum.count(source_entries, &(&1["content_type"] == "conversation_handoff"))

    assert :ok =
             Collaboration.completed(c.source, %{status: :completed},
               run_id: source_status.run_id,
               workspace_path: c.context.conversation_run_opts[:workspace_path]
             )

    {:ok, source_entries_after} = ConversationTranscriptStore.list(c.source)

    assert Enum.count(source_entries_after, &(&1["content_type"] == "conversation_handoff")) ==
             outbound_before
  end

  test "reverse requests and results require explicit purpose and cover only requests already consumed",
       c do
    {:ok, handoff} =
      Collaboration.send_message(
        %{"conversation" => c.target, "message" => "Initial task", "request_id" => "round-trip"},
        c.context
      )

    assert_receive {:held, _, _}, 2_000
    {:ok, target_status} = Handbean.Agent.Runner.status(c.target)
    target_context = %{c.context | conversation_id: c.target, run_id: target_status.run_id}

    {:ok, first_question} =
      Collaboration.send_message(
        %{
          "conversation" => c.source,
          "message" => "Need clarification one",
          "request_id" => "clarify-one",
          "handoff_id" => handoff.handoff_id,
          "purpose" => "request"
        },
        target_context
      )

    assert_receive {:held, _, _}, 2_000
    {:ok, source_status} = Handbean.Agent.Runner.status(c.source)
    source_context = %{c.context | run_id: source_status.run_id}

    {:ok, first_answer} =
      Collaboration.send_message(
        %{
          "conversation" => c.target,
          "message" => "First answer",
          "request_id" => "answer-one",
          "handoff_id" => handoff.handoff_id,
          "purpose" => "result"
        },
        source_context
      )

    {:ok, second_question} =
      Collaboration.send_message(
        %{
          "conversation" => c.source,
          "message" => "Need clarification two",
          "request_id" => "clarify-two",
          "handoff_id" => handoff.handoff_id,
          "purpose" => "request"
        },
        target_context
      )

    :ok =
      Handbean.Agent.TranscriptPersistence.handle_event(
        c.source,
        {:candidate_message_injected, %{message_ids: [second_question.message_id]}},
        run_id: source_status.run_id
      )

    {:ok, source_entries} = ConversationTranscriptStore.list(c.source)
    first_result = Enum.find(source_entries, &(&1["id"] == first_answer.message_id))
    assert first_result["covered_inbound_ids"] == [first_question.message_id]
    refute second_question.message_id in first_result["covered_inbound_ids"]

    assert :ok =
             Collaboration.completed(c.source, %{status: :completed},
               run_id: source_status.run_id,
               workspace_path: c.context.conversation_run_opts[:workspace_path]
             )

    {:ok, source_entries} = ConversationTranscriptStore.list(c.source)
    automatic = Enum.find(source_entries, &(&1["automatic_report"] == true))
    assert automatic["covered_inbound_ids"] == [second_question.message_id]
  end

  test "a non-completed terminal status is reported even after an explicit result", c do
    {:ok, request} =
      Collaboration.send_message(
        %{"conversation" => c.target, "message" => "May halt", "request_id" => "halt-task"},
        c.context
      )

    assert_receive {:held, _, _}, 2_000
    {:ok, target_status} = Handbean.Agent.Runner.status(c.target)
    target_context = %{c.context | conversation_id: c.target, run_id: target_status.run_id}

    assert {:ok, _} =
             Collaboration.send_message(
               %{
                 "conversation" => c.source,
                 "message" => "Partial result",
                 "request_id" => "halt-partial",
                 "handoff_id" => request.handoff_id,
                 "purpose" => "result"
               },
               target_context
             )

    assert_receive {:held, _, _}, 2_000

    assert :ok =
             Collaboration.completed(c.target, %{status: :max_turns},
               run_id: target_status.run_id,
               workspace_path: c.context.conversation_run_opts[:workspace_path]
             )

    {:ok, entries} = ConversationTranscriptStore.list(c.target)
    report = Enum.find(entries, &(&1["automatic_report"] == true))
    assert report["purpose"] == "notification"
    assert report["content"] =~ "max_turns"
    refute report["content"] =~ "Partial result"
  end

  test "legacy entries are not retroactively reported and delegated task ownership does not double report",
       c do
    for {id, purpose, expect_report} <- [
          {"legacy-consumed", nil, nil},
          {"delegation-owned", "request", true}
        ] do
      origin =
        %{
          "kind" => "conversation",
          "conversation_id" => c.source,
          "handoff_id" => "historical-handoff"
        }
        |> Map.put("purpose", purpose)
        |> Map.put("expect_report", expect_report)

      {:ok, _} =
        ConversationTranscriptStore.append(c.target, %{
          "id" => id,
          "content_type" => "user_msg",
          "message_type" => "user",
          "role" => "user",
          "direction" => "inbound",
          "content" => id,
          "consumption" => "consumed",
          "consumed_run_id" => id,
          "origin" => origin
        })
    end

    assert :ok =
             Collaboration.completed(c.target, %{status: :completed}, run_id: "legacy-consumed")

    assert :ok =
             Collaboration.completed(c.target, %{status: :completed},
               run_id: "delegation-owned",
               delegated?: true
             )

    {:ok, entries} = ConversationTranscriptStore.list(c.target)
    refute Enum.any?(entries, &(&1["content_type"] == "conversation_handoff"))
  end

  test "an uncertain explicit result is not replayed or replaced by an automatic report", c do
    {:ok, request} =
      Collaboration.send_message(
        %{
          "conversation" => c.target,
          "message" => "Uncertain result task",
          "request_id" => "uncertain-task"
        },
        c.context
      )

    assert_receive {:held, _, _}, 2_000
    {:ok, target_status} = Handbean.Agent.Runner.status(c.target)

    target_context = %{
      c.context
      | conversation_id: c.target,
        run_id: target_status.run_id,
        conversation_run_opts:
          Keyword.put(c.context.conversation_run_opts, :transcript_store, FailingInboundStore)
    }

    result_input = %{
      "conversation" => c.source,
      "message" => "Uncertain explicit result",
      "request_id" => "uncertain-result",
      "handoff_id" => request.handoff_id,
      "purpose" => "result"
    }

    assert {:ok, %{delivery: "delivery_unknown"} = uncertain} =
             Collaboration.send_message(result_input, target_context)

    assert {:ok, ^uncertain} = Collaboration.send_message(result_input, target_context)

    assert :ok =
             Collaboration.completed(c.target, %{status: :completed},
               run_id: target_status.run_id,
               workspace_path: c.context.conversation_run_opts[:workspace_path]
             )

    {:ok, entries} = ConversationTranscriptStore.list(c.target)
    assert Enum.count(entries, &(&1["content_type"] == "conversation_handoff")) == 1
    [reservation] = Enum.filter(entries, &(&1["content_type"] == "conversation_handoff"))
    assert reservation["delivery_status"] == "delivery_unknown"
    assert reservation["covered_inbound_ids"] == [request.message_id]
    refute reservation["automatic_report"]
  end

  test "an unavailable report peer does not delay the source conversation's next run", c do
    assert {:ok, receipt} =
             Collaboration.send_message(
               %{
                 "conversation" => c.target,
                 "message" => "Finish despite unavailable peer",
                 "request_id" => "unavailable-report-peer"
               },
               c.context
             )

    assert_receive {:held, provider, _config}, 2_000
    assert {:ok, status} = Handbean.Agent.Runner.status(receipt.conversation)
    supervisor_ref = Process.monitor(status.run_supervisor)
    assert {:ok, _} = ConversationStore.update_meta(c.source, visibility: "internal")
    send(provider, :release)
    assert_receive {:DOWN, ^supervisor_ref, :process, _, _}, 1_000

    assert {:ok, %{action: :started}} =
             Handbean.Agent.Coordinator.add_message(c.target, "next run", c.opts)

    assert_receive {:held, _, _}, 2_000
  end

  test "timeout report reaches its peer only after the old source run exits", c do
    assert {:ok, request} =
             Collaboration.send_message(
               %{
                 "conversation" => c.target,
                 "message" => "Timeout ordering task",
                 "request_id" => "timeout-ordering"
               },
               c.context
             )

    assert_receive {:held, _, _}, 2_000
    {:ok, status} = Handbean.Agent.Runner.status(c.target)
    old_run_id = status.run_id
    supervisor_ref = Process.monitor(status.run_supervisor)

    # The timer message is the narrowest available test entry point for timeout.
    state = :sys.get_state(status.run_pid)
    send(status.run_pid, {:run_inactivity, state.deadline})

    assert_receive {:held, _, %{conversation_id: conversation_id}}, 2_000
    assert conversation_id == c.source
    assert_receive {:DOWN, ^supervisor_ref, :process, _, _}, 0
    assert {:ok, %{running?: false}} = Handbean.Agent.Coordinator.status(c.target)

    assert {:ok, %{delivery: "started"}} =
             Collaboration.send_message(
               %{
                 "conversation" => c.target,
                 "message" => "Immediate follow-up",
                 "request_id" => "after-timeout",
                 "handoff_id" => request.handoff_id,
                 "purpose" => "request"
               },
               c.context
             )

    assert {:ok, %{run_id: new_run_id, running?: true}} =
             Handbean.Agent.Coordinator.status(c.target)

    assert new_run_id != old_run_id
    assert_receive {:held, _, %{conversation_id: target_id}}, 2_000
    assert target_id == c.target
  end

  test "cancel, timeout and abnormal stop report sanitized status without duplicate task reports",
       c do
    {:ok, timeout_target} = ConversationStore.create("ws", selected_model: "fake/fake-model")
    {:ok, error_target} = ConversationStore.create("ws", selected_model: "fake/fake-model")

    receipts =
      for {target, key} <- [
            {c.target, "cancel-terminal"},
            {timeout_target["id"], "timeout-terminal"},
            {error_target["id"], "error-terminal"}
          ],
          into: %{} do
        {:ok, receipt} =
          Collaboration.send_message(
            %{"conversation" => target, "message" => "terminal task", "request_id" => key},
            c.context
          )

        assert_receive {:held, _, _}, 2_000
        {:ok, status} = Handbean.Agent.Runner.status(target)
        {key, {receipt, status}}
      end

    cancel_id = c.target
    timeout_id = timeout_target["id"]
    error_id = error_target["id"]
    :ok = Phoenix.PubSub.subscribe(Handbean.PubSub, "conversation:updated")

    {cancel_receipt, cancel_status} = receipts["cancel-terminal"]
    cancel_context = %{c.context | conversation_id: c.target, run_id: cancel_status.run_id}

    assert {:ok, _result} =
             Collaboration.send_message(
               %{
                 "conversation" => c.source,
                 "message" => "Result sent before cancellation",
                 "request_id" => "before-cancel-result",
                 "handoff_id" => cancel_receipt.handoff_id,
                 "purpose" => "result"
               },
               cancel_context
             )

    assert_receive {:held, _, _}, 2_000
    cancel_ref = Process.monitor(cancel_status.run_pid)
    assert :ok = Handbean.Agent.Coordinator.cancel(c.target)
    assert_receive {:DOWN, ^cancel_ref, :process, _, _}, 2_000
    assert_receive {:conversation_updated, ^cancel_id}, 2_000

    {_timeout_receipt, timeout_status} = receipts["timeout-terminal"]
    timeout_state = :sys.get_state(timeout_status.run_pid)
    timeout_ref = Process.monitor(timeout_status.run_pid)
    send(timeout_status.run_pid, {:run_inactivity, timeout_state.deadline})
    assert_receive {:DOWN, ^timeout_ref, :process, _, _}, 2_000
    assert_receive {:conversation_updated, ^timeout_id}, 2_000

    {_error_receipt, error_status} = receipts["error-terminal"]
    error_ref = Process.monitor(error_status.run_pid)
    send(error_status.run_pid, {:EXIT, self(), {:secret_provider_error, "do not forward"}})
    assert_receive {:DOWN, ^error_ref, :process, _, _}, 2_000
    assert_receive {:conversation_updated, ^error_id}, 2_000
    {:ok, source_entries} = ConversationTranscriptStore.list(c.source)

    reports =
      Enum.filter(source_entries, &(get_in(&1, ["origin", "automatic_report"]) == true))

    assert length(reports) == 3
    assert Enum.all?(reports, &(get_in(&1, ["origin", "purpose"]) == "notification"))
    assert Enum.any?(reports, &(&1["content"] =~ "cancelled"))
    assert Enum.any?(reports, &(&1["content"] =~ "timeout"))
    assert Enum.any?(reports, &(&1["content"] =~ "error"))
    refute Enum.any?(reports, &(&1["content"] =~ "secret_provider_error"))
  end

  test "one remaining request does not receive unpartitioned final text from a mixed run", c do
    {:ok, peer_b} = ConversationStore.create("ws", selected_model: "fake/fake-model")
    peer_b_context = %{c.context | conversation_id: peer_b["id"], run_id: "peer-b-run"}

    {:ok, from_a} =
      Collaboration.send_message(
        %{"conversation" => c.target, "message" => "A task", "request_id" => "mixed-a"},
        c.context
      )

    assert_receive {:held, _, _}, 2_000
    {:ok, target_status} = Handbean.Agent.Runner.status(c.target)

    {:ok, from_b} =
      Collaboration.send_message(
        %{"conversation" => c.target, "message" => "B task", "request_id" => "mixed-b"},
        peer_b_context
      )

    :ok =
      Handbean.Agent.TranscriptPersistence.handle_event(
        c.target,
        {:candidate_message_injected, %{message_ids: [from_b.message_id]}},
        run_id: target_status.run_id
      )

    {:ok, _} =
      ConversationTranscriptStore.append(c.target, %{
        "id" => "ordinary-user-steer",
        "content_type" => "user_msg",
        "message_type" => "user",
        "role" => "user",
        "direction" => "inbound",
        "content" => "ordinary user input",
        "consumption" => "consumed",
        "consumed_run_id" => target_status.run_id
      })

    {:ok, _} =
      ConversationTranscriptStore.append(c.target, %{
        "id" => "mixed-final",
        "content_type" => "assistant_msg",
        "message_type" => "assistant",
        "role" => "assistant",
        "direction" => "outbound",
        "run_id" => target_status.run_id,
        "phase" => "final",
        "status" => "completed",
        "content" => "PRIVATE UNPARTITIONED FINAL"
      })

    target_context = %{c.context | conversation_id: c.target, run_id: target_status.run_id}

    assert {:ok, _} =
             Collaboration.send_message(
               %{
                 "conversation" => c.source,
                 "message" => "A result",
                 "request_id" => "mixed-a-result",
                 "handoff_id" => from_a.handoff_id,
                 "purpose" => "result"
               },
               target_context
             )

    assert_receive {:held, _, _}, 2_000

    assert :ok =
             Collaboration.completed(c.target, %{status: :completed},
               run_id: target_status.run_id,
               workspace_path: c.context.conversation_run_opts[:workspace_path]
             )

    {:ok, target_entries} = ConversationTranscriptStore.list(c.target)

    [report] =
      Enum.filter(target_entries, fn entry ->
        entry["automatic_report"] == true and entry["handoff_id"] == from_b.handoff_id
      end)

    assert report["content"] =~ "mixed inputs"
    refute report["content"] =~ "PRIVATE UNPARTITIONED FINAL"
  end
end
