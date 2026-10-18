defmodule HandbeanProbe.PendingRequestsTest do
  use ExUnit.Case, async: true

  alias HandbeanProbe.PendingRequests
  alias HandbeanProbe.PendingRequests.Entry

  test "register binds the entry to the scope generation and take returns it once" do
    pr = PendingRequests.new()
    assert PendingRequests.generation(pr, :composer) == 1
    assert PendingRequests.generation(pr, :share_intakes_ready) == 0

    {entry, pr} = PendingRequests.register(pr, "req-1", :import, scope: :composer, ctx: %{a: 1})

    assert %Entry{ref: "req-1", kind: :import, scope: :composer, generation: 1, deadline: nil} =
             entry

    assert PendingRequests.has?(pr, "req-1")
    assert PendingRequests.ctx(pr, "req-1") == %{a: 1}
    assert [%Entry{ref: "req-1"}] = PendingRequests.by_kind(pr, :import)

    assert {:ok, %Entry{ref: "req-1", ctx: %{a: 1}}, pr} = PendingRequests.take(pr, "req-1", 1)
    refute PendingRequests.has?(pr, "req-1")
    assert {:error, :unknown, _} = PendingRequests.take(pr, "req-1", 1)
  end

  test "a matching wire generation is accepted; :any skips the wire check" do
    {gen, pr} = PendingRequests.new() |> PendingRequests.bump(:models)
    assert gen == 1

    ref = make_ref()
    {_entry, pr} = PendingRequests.register(pr, ref, :model_settings_loaded, scope: :models)

    assert {:ok, %Entry{generation: 1}, _} = PendingRequests.take(pr, ref, 1)
    assert {:ok, %Entry{generation: 1}, _} = PendingRequests.take(pr, ref, :any)
  end

  test "a mismatched wire generation drops the entry" do
    pr = PendingRequests.new()
    {_entry, pr} = PendingRequests.register(pr, "req-2", :open_url, scope: :composer)

    assert {:error, {:generation_mismatch, 1, 7}, pr} = PendingRequests.take(pr, "req-2", 7)
    # Dropped, not left behind for a later matching reply.
    refute PendingRequests.has?(pr, "req-2")
  end

  test "bumping the scope supersedes older entries (latest wins)" do
    pr = PendingRequests.new()
    {%Entry{generation: 0}, pr} = PendingRequests.register(pr, :old, :folder_listed)
    {1, pr} = PendingRequests.bump(pr, :folder_listed)
    {%Entry{generation: 1}, pr} = PendingRequests.register(pr, :new, :folder_listed)

    assert {:error, :superseded, pr} = PendingRequests.take(pr, :old, 0)
    assert {:ok, %Entry{generation: 1}, _} = PendingRequests.take(pr, :new, 1)
  end

  test "a deadline sends the timeout message to the owner and expire removes the entry" do
    pr = PendingRequests.new()
    tag = PendingRequests.timeout_message()

    {entry, pr} = PendingRequests.register(pr, "slow", :share_snapshot, timeout_ms: 0)
    assert is_integer(entry.deadline)
    assert is_reference(entry.timer)

    assert_receive {^tag, "slow"}, 1_000

    assert {:ok, %Entry{ref: "slow", kind: :share_snapshot}, pr} =
             PendingRequests.expire(pr, "slow")

    assert :error = PendingRequests.expire(pr, "slow")
    assert PendingRequests.empty?(pr)
  end

  test "take cancels the deadline timer so no late timeout arrives" do
    pr = PendingRequests.new()
    tag = PendingRequests.timeout_message()

    {_entry, pr} = PendingRequests.register(pr, "fast", :open_snapshot, timeout_ms: 50)
    assert {:ok, _entry, _pr} = PendingRequests.take(pr, "fast", :any)

    refute_receive {^tag, "fast"}, 150
  end

  test "drop_scope returns the entries of that scope only and cancels their timers" do
    pr = PendingRequests.new()
    tag = PendingRequests.timeout_message()

    {_e1, pr} = PendingRequests.register(pr, "c1", :import, scope: :composer, timeout_ms: 50)
    {_e2, pr} = PendingRequests.register(pr, "c2", :share_send_marked, scope: :composer)
    {_e3, pr} = PendingRequests.register(pr, "w1", :workspace_open)

    {dropped, pr} = PendingRequests.drop_scope(pr, :composer)
    assert dropped |> Enum.map(& &1.ref) |> Enum.sort() == ["c1", "c2"]
    assert PendingRequests.has?(pr, "w1")
    assert PendingRequests.size(pr) == 1

    refute_receive {^tag, "c1"}, 150
  end
end
