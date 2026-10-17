defmodule Handbean.Runtime.NotifyTest do
  use ExUnit.Case, async: true

  alias Handbean.Runtime.Notify

  defp task(id, status \\ :running) do
    %{conversation_id: id, run_id: "run-#{id}", status: status, title: id}
  end

  test "snapshot counts running and waiting separately" do
    snapshot = Notify.snapshot([task("a"), task("b", :waiting_confirmation)])
    assert snapshot.running_count == 1
    assert snapshot.waiting_count == 1
  end

  test "start and wait only refresh the running notification" do
    snapshot = Notify.snapshot([task("a")])

    assert [{:update_running, ^snapshot}] =
             Notify.actions(snapshot, {:started, task("a")}, %{
               app_visible?: false,
               viewing?: false
             })

    waiting = Notify.snapshot([task("a", :waiting_confirmation)])

    assert [{:update_running, ^waiting}] =
             Notify.actions(waiting, {:waiting, task("a", :waiting_confirmation)}, %{
               app_visible?: false,
               viewing?: true
             })
  end

  test "ended in background posts a system completion" do
    empty = Notify.snapshot([])
    ended = task("a")

    assert [
             {:update_running, ^empty},
             {:system_ended, ^ended, :completed}
           ] =
             Notify.actions(empty, {:ended, ended, :completed}, %{
               app_visible?: false,
               viewing?: false
             })
  end

  test "ended while viewing the conversation stays silent" do
    empty = Notify.snapshot([])
    ended = task("a")

    assert [{:update_running, ^empty}] =
             Notify.actions(empty, {:ended, ended, :completed}, %{
               app_visible?: true,
               viewing?: true
             })
  end

  test "cancel only clears the running notification" do
    empty = Notify.snapshot([])
    ended = task("a")

    assert [{:update_running, ^empty}] =
             Notify.actions(empty, {:ended, ended, :cancelled}, %{
               app_visible?: false,
               viewing?: false
             })
  end

  test "ended in the app but on another page uses an in-app prompt" do
    empty = Notify.snapshot([])
    ended = task("a")

    assert [
             {:update_running, ^empty},
             {:in_app_ended, ^ended, :failed}
           ] =
             Notify.actions(empty, {:ended, ended, :failed}, %{
               app_visible?: true,
               viewing?: false
             })
  end
end
