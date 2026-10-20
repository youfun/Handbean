defmodule Handbean.Agent.OperationReceiptTest do
  use Handbean.DataCase, async: false

  alias Handbean.Agent.OperationReceipt

  test "same id replays, different content conflicts, and a pending operation becomes unknown" do
    scope = {:message, unique_id("conversation")}
    fingerprint = OperationReceipt.fingerprint({"hello", :new_run})

    assert :ok = OperationReceipt.reserve(scope, "op-1", fingerprint)
    assert :ok = OperationReceipt.complete(scope, "op-1", %{action: :started})

    assert {:replay, %{"action" => "started"}} =
             OperationReceipt.reserve(scope, "op-1", fingerprint)

    assert {:error, :idempotency_conflict} =
             OperationReceipt.reserve(
               scope,
               "op-1",
               OperationReceipt.fingerprint("other")
             )

    assert :ok = OperationReceipt.reserve(scope, "op-2", fingerprint)

    assert {:unknown, :delivery_unknown} =
             OperationReceipt.reserve(scope, "op-2", fingerprint)

    assert {:ok, %{"status" => "completed"}} = OperationReceipt.lookup(scope, "op-1")
    assert {:ok, %{"status" => "unknown"}} = OperationReceipt.lookup(scope, "op-2")
  end

  test "scope kind and id both isolate request ids" do
    conversation_id = unique_id("conversation")
    fingerprint = OperationReceipt.fingerprint("same request")

    assert :ok = OperationReceipt.reserve({:message, conversation_id}, "op-1", fingerprint)
    assert :ok = OperationReceipt.reserve({:tool_effect, conversation_id}, "op-1", fingerprint)

    assert :ok =
             OperationReceipt.reserve(
               {:message, conversation_id <> "-other"},
               "op-1",
               fingerprint
             )
  end

  test "release frees a matching reservation and leaves every other row" do
    scope = {:message, unique_id("conversation")}
    fingerprint = OperationReceipt.fingerprint({"hello", :new_run})

    assert :ok = OperationReceipt.reserve(scope, "op-rel", fingerprint)
    assert :ok = OperationReceipt.release_reserved(scope, "op-rel", fingerprint)
    assert :error = OperationReceipt.lookup(scope, "op-rel")
    assert :ok = OperationReceipt.reserve(scope, "op-rel", fingerprint)
    assert :ok = OperationReceipt.complete(scope, "op-rel", %{action: :started})

    assert {:error, :not_reserved} =
             OperationReceipt.release_reserved(scope, "op-rel", fingerprint)

    assert :ok = OperationReceipt.reserve(scope, "op-held", fingerprint)

    assert {:error, :idempotency_conflict} =
             OperationReceipt.release_reserved(
               scope,
               "op-held",
               OperationReceipt.fingerprint("other")
             )

    assert {:ok, %{"status" => "reserved"}} = OperationReceipt.lookup(scope, "op-held")
  end

  test "a failed release keeps the reservation" do
    scope = {:message, unique_id("conversation")}
    fingerprint = OperationReceipt.fingerprint({"hello", :new_run})
    assert :ok = OperationReceipt.reserve(scope, "op-fault", fingerprint)

    on_exit(fn -> Application.delete_env(:handbean, :operation_receipt_write_fault) end)

    Application.put_env(:handbean, :operation_receipt_write_fault, fn -> {:error, :injected} end)

    assert {:error, :injected} =
             OperationReceipt.release_reserved(scope, "op-fault", fingerprint)

    assert {:ok, %{"status" => "reserved"}} = OperationReceipt.lookup(scope, "op-fault")
  end

  test "accepted inbound and receipt completion roll back together with a cold store module" do
    store = Handbean.ConversationTranscriptStore.ConversationStore
    :code.purge(store)
    :code.delete(store)
    refute function_exported?(store, :append_with_receipt, 5)
    on_exit(fn -> Code.ensure_loaded!(store) end)

    conversation_id = unique_id("conversation")
    scope = {:message, conversation_id}
    fingerprint = OperationReceipt.fingerprint({"hello", nil})
    assert {:ok, _} = Handbean.ConversationStore.create("default", id: conversation_id)
    assert :ok = OperationReceipt.reserve(scope, "op-atomic", fingerprint)

    on_exit(fn -> Application.delete_env(:handbean, :operation_receipt_write_fault) end)
    Application.put_env(:handbean, :operation_receipt_write_fault, fn -> {:error, :injected} end)

    assert {:error, :injected} =
             Handbean.Agent.TranscriptPersistence.accept_inbound(
               conversation_id,
               "hello",
               %{action: :started, run_id: "run-1"},
               request_id: "op-atomic",
               run_id: "run-1"
             )

    assert {:ok, []} = Handbean.ConversationTranscriptStore.list(conversation_id)
    assert {:ok, %{"status" => "reserved"}} = OperationReceipt.lookup(scope, "op-atomic")
  end

  test "concurrent reserves of a new id accept one writer" do
    scope = {:message, unique_id("conversation")}
    fingerprint = OperationReceipt.fingerprint({"race", :new_run})

    tasks =
      for _ <- 1..8 do
        Task.async(fn -> OperationReceipt.reserve(scope, "race-1", fingerprint) end)
      end

    results = Enum.map(tasks, &Task.await/1)
    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.all?(results -- [:ok], &(&1 == {:unknown, :delivery_unknown}))
  end

  test "mark_unknown clears a completed receipt" do
    scope = {:message, unique_id("conversation")}
    fingerprint = OperationReceipt.fingerprint("completed")

    assert :ok = OperationReceipt.reserve(scope, "op-unknown", fingerprint)
    assert :ok = OperationReceipt.complete(scope, "op-unknown", %{"action" => "started"})
    assert :ok = OperationReceipt.mark_unknown(scope, "op-unknown")

    assert {:ok, %{"status" => "unknown", "receipt" => nil}} =
             OperationReceipt.lookup(scope, "op-unknown")
  end

  test "missing request id does not reserve" do
    scope = {:message, unique_id("conversation")}

    assert :ok = OperationReceipt.reserve(scope, nil, "fp")
    assert :error = OperationReceipt.lookup(scope, "missing")
  end

  defp unique_id(prefix),
    do: prefix <> "-" <> Integer.to_string(System.unique_integer([:positive]))
end
