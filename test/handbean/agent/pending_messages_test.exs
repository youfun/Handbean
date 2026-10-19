defmodule Handbean.Agent.PendingMessagesTest do
  use ExUnit.Case, async: true

  alias Handbean.Agent.PendingMessages

  test "put_queued is idempotent and Session enqueue payload re-queues the same id" do
    pending = PendingMessages.put_queued(%{}, "m1", :steer, %{content: "hi"})
    pending = PendingMessages.put_queued(pending, "m1", :steer, %{content: "hi"})

    assert pending["m1"] == %{deliver_as: :steer, status: :queued, content: "hi"}

    pending =
      PendingMessages.apply_injected(pending, %{
        "message_id" => "m1",
        "deliver_as" => "steer",
        "content" => "hi"
      })

    assert pending["m1"].status == :queued
  end

  test "Turn inject with message_ids drops those ids even when the list is empty" do
    pending = PendingMessages.put_queued(%{}, "m1", :steer, %{})
    assert PendingMessages.apply_injected(pending, %{message_ids: []}) == pending

    pending = PendingMessages.apply_injected(pending, %{message_ids: ["m1"], count: 1})
    refute Map.has_key?(pending, "m1")
  end

  test "deleted payload drops the candidate" do
    pending = PendingMessages.put_queued(%{}, "m1", :follow_up, %{})
    pending = PendingMessages.apply_deleted(pending, %{message_id: "m1"})
    assert pending == %{}
  end

  test "interrupted run_end does not mark undelivered; terminal status does" do
    pending = PendingMessages.put_queued(%{}, "m1", :steer, %{})
    assert PendingMessages.apply_run_end(pending, :interrupted)["m1"].status == :queued
    assert PendingMessages.apply_run_end(pending, "interrupted")["m1"].status == :queued
    assert PendingMessages.apply_run_end(pending, :completed)["m1"].status == :undelivered
    assert PendingMessages.apply_run_end(pending, "cancelled")["m1"].status == :undelivered
  end

  test "reconcile keeps local undelivered, rebuilds queued from session while running" do
    pending =
      %{"old" => %{deliver_as: :steer, status: :undelivered, content: "missed"}}
      |> PendingMessages.put_queued("q1", :follow_up, %{content: "stale"})

    session = [%{id: "q2", content: "from session", deliver_as: :steer}]
    reconciled = PendingMessages.reconcile(pending, session, true)

    assert reconciled["old"].status == :undelivered
    refute Map.has_key?(reconciled, "q1")
    assert reconciled["q2"].status == :queued
    assert reconciled["q2"].deliver_as == :steer

    idle = PendingMessages.reconcile(pending, session, false)
    assert Map.keys(idle) == ["old"]
  end

  test "reconcile hydrates text and attachments from transcript, not session blocks" do
    pending = %{
      "keep" => %{
        deliver_as: :steer,
        status: :queued,
        content: "local",
        attachments: [%{"id" => "kept"}]
      }
    }

    session = [
      %{id: "keep", content: [%{"type" => "text", "text" => "block"}], deliver_as: :steer},
      %{id: "hyd", content: [%{"type" => "image"}], deliver_as: :follow_up},
      %{id: "", content: "nope", deliver_as: :steer},
      %{id: "nt", content: "next", deliver_as: :next_turn}
    ]

    entries = [
      %{
        "id" => "hyd",
        "content" => "plain hyd",
        "attachments" => [%{"id" => "img1", "filename" => "a.png"}]
      }
    ]

    reconciled = PendingMessages.reconcile(pending, session, true, entries)

    assert reconciled["keep"].content == "local"
    assert reconciled["keep"].attachments == [%{"id" => "kept"}]
    assert reconciled["hyd"].content == "plain hyd"
    assert reconciled["hyd"].attachments == [%{"id" => "img1", "filename" => "a.png"}]
    refute Map.has_key?(reconciled, "")
    refute Map.has_key?(reconciled, "nt")
  end

  test "apply_injected ignores non-string content from Session enqueue" do
    pending = PendingMessages.put_queued(%{}, "m1", :steer, %{content: "hi"})

    pending =
      PendingMessages.apply_injected(pending, %{
        message_id: "m1",
        deliver_as: :steer,
        content: [%{"type" => "text"}]
      })

    assert pending["m1"].content == "hi"
  end

  test "pin_pending keeps queued entries last without reordering the rest" do
    entries = [
      %{"id" => "u1"},
      %{"id" => "q1"},
      %{"id" => "a1"},
      %{"id" => "q2"}
    ]

    pending = %{
      "q1" => %{deliver_as: :follow_up, status: :queued},
      "q2" => %{deliver_as: :follow_up, status: :queued}
    }

    assert Enum.map(PendingMessages.pin_pending(entries, pending), & &1["id"]) ==
             ["u1", "a1", "q1", "q2"]
  end

  test "move_to_end follows the given id order and skips missing ids" do
    entries = [
      %{"id" => "q1"},
      %{"id" => "a1"},
      %{"id" => "q2"},
      %{"id" => "t1"}
    ]

    assert Enum.map(PendingMessages.move_to_end(entries, ["q2", "q1", "gone"]), & &1["id"]) ==
             ["a1", "t1", "q2", "q1"]
  end
end
