defmodule Handbean.Runtime.AndroidNotifyTest do
  use ExUnit.Case, async: false

  alias Handbean.Runtime.AndroidNotify

  @task %{
    conversation_id: "conv-1",
    run_id: "run-1",
    workspace_id: "ws-1",
    title: "Hello",
    status: :running
  }

  setup do
    previous = Application.get_env(:handbean, :notifier)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:handbean, :notifier, previous),
        else: Application.delete_env(:handbean, :notifier)
    end)

    :ok
  end

  test "without a notifier every action is a no-op and the app is not visible" do
    Application.delete_env(:handbean, :notifier)

    refute AndroidNotify.app_visible?()
    assert AndroidNotify.apply({:update_running, snapshot()}) == :ok
    assert AndroidNotify.apply({:system_ended, @task, :completed}) == :ok
    assert AndroidNotify.apply({:in_app_ended, @task, :completed}) == :ok
  end

  test "a fun/2 notifier receives the NIF-style call name and encoded JSON" do
    parent = self()

    Application.put_env(:handbean, :notifier, fn fun, args ->
      send(parent, {:notifier, fun, args})
      if fun == :app_visible, do: true, else: :ok
    end)

    assert AndroidNotify.app_visible?()
    assert_received {:notifier, :app_visible, []}

    assert AndroidNotify.apply({:update_running, snapshot()}) == :ok
    assert_received {:notifier, :update_running, [running_json]}

    assert Jason.decode!(running_json) == %{
             "running_count" => 1,
             "waiting_count" => 0,
             "tasks" => [encoded_task("running")]
           }

    assert AndroidNotify.apply({:system_ended, @task, :completed}) == :ok
    assert_received {:notifier, :show_ended, [ended_json]}

    assert Jason.decode!(ended_json) == %{
             "reason" => "completed",
             "task" => encoded_task("running")
           }
  end

  test "a module notifier is called by function name" do
    defmodule NotifierStub do
      def app_visible, do: true
      def update_running(json), do: send(self(), {:stub_running, json})
      def show_ended(json), do: send(self(), {:stub_ended, json})
    end

    Application.put_env(:handbean, :notifier, NotifierStub)

    assert AndroidNotify.app_visible?()
    assert AndroidNotify.apply({:update_running, snapshot()}) == :ok
    assert_received {:stub_running, _}
    assert AndroidNotify.apply({:system_ended, @task, :cancelled}) == :ok
    assert_received {:stub_ended, _}
  end

  test "a notifier module missing the function degrades to the no-op fallback" do
    Application.put_env(:handbean, :notifier, Handbean.Runtime.AndroidNotifyTest.MissingNotifier)

    refute AndroidNotify.app_visible?()
    assert AndroidNotify.apply({:update_running, snapshot()}) == :ok
  end

  defp snapshot, do: %{running_count: 1, waiting_count: 0, tasks: [@task]}

  defp encoded_task(status) do
    %{
      "conversation_id" => "conv-1",
      "run_id" => "run-1",
      "workspace_id" => "ws-1",
      "title" => "Hello",
      "status" => status
    }
  end
end
