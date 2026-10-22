defmodule Handbean.Runtime.MacNotifyTest do
  use Handbean.DataCase, async: false

  alias Handbean.Runtime.MacNotify
  alias Handbean.Runtime.MacNotify.Bridge

  @task %{
    conversation_id: "conv-1",
    run_id: "run-1",
    workspace_id: "ws-1",
    title: "找图",
    status: :running
  }

  test "completion copy follows the UI locale and does not touch the web flash" do
    payload = MacNotify.ended_payload(@task, :completed, "zh_CN")

    assert payload["op"] == "show_ended"
    assert payload["title"] == "Handbean"
    assert payload["body"] == "Agent 已在「找图」中回复。"
    assert payload["conversation_id"] == "conv-1"
    assert payload["workspace_id"] == "ws-1"

    failed = MacNotify.ended_payload(%{@task | title: nil}, :failed, "en")
    assert failed["body"] == "This run ended in conversation."
  end

  test "a missing bridge keeps the app visible and drops host actions" do
    assert MacNotify.app_visible?()
    assert MacNotify.apply({:in_app_ended, @task, :completed}) == :ok
    assert MacNotify.apply({:system_ended, @task, :completed}) == :ok
    assert MacNotify.apply({:update_running, %{running_count: 1, waiting_count: 0}}) == :ok
  end

  test "shell visibility and completion actions cross the notify bridge" do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, packet: :line, active: false, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)

    on_exit(fn ->
      :gen_tcp.close(listen)
    end)

    if pid = Process.whereis(Bridge) do
      GenServer.stop(pid)
    end

    start_supervised!({Bridge, port: port, token: "secret"})
    {:ok, client} = :gen_tcp.accept(listen, 2_000)

    assert {:ok, hello} = :gen_tcp.recv(client, 0, 2_000)
    assert Handbean.JSON.decode!(hello) == %{"op" => "hello", "token" => "secret"}

    :ok =
      :gen_tcp.send(
        client,
        Handbean.JSON.encode!(%{"op" => "visible", "value" => false}) <> "\n"
      )

    assert wait_until(fn -> MacNotify.app_visible?() == false end)

    assert MacNotify.apply({:in_app_ended, @task, :completed}) == :ok
    assert {:ok, in_app} = :gen_tcp.recv(client, 0, 1_000)
    assert Handbean.JSON.decode!(in_app)["op"] == "show_ended"

    assert MacNotify.apply({:update_running, %{running_count: 0, waiting_count: 1}}) == :ok
    assert {:ok, running} = :gen_tcp.recv(client, 0, 2_000)

    assert Handbean.JSON.decode!(running) == %{
             "op" => "update_running",
             "running_count" => 0,
             "waiting_count" => 1
           }

    assert MacNotify.apply({:system_ended, @task, :completed}) == :ok
    assert {:ok, ended} = :gen_tcp.recv(client, 0, 2_000)
    decoded = Handbean.JSON.decode!(ended)
    assert decoded["op"] == "show_ended"
    assert decoded["reason"] == "completed"
    assert decoded["body"] =~ "找图"
  end

  defp wait_until(fun, attempts \\ 20)
  defp wait_until(fun, 0), do: fun.()

  defp wait_until(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(25)
      wait_until(fun, attempts - 1)
    end
  end
end
