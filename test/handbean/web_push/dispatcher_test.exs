defmodule Handbean.WebPush.DispatcherTest do
  use Handbean.DataCase, async: false

  alias Handbean.Runtime.TaskTracker
  alias Handbean.WebPush
  alias Handbean.WebPush.Dispatcher
  alias Handbean.WebPush.Protocol

  setup do
    Req.Test.set_req_test_to_shared()
    previous = Application.get_env(:handbean, :web_push)

    Application.put_env(:handbean, :web_push,
      subject: "mailto:push@example.com",
      dispatch: false,
      req_options: [plug: {Req.Test, __MODULE__}]
    )

    TaskTracker.reset()
    worker = start_supervised!({Dispatcher, name: nil, enabled: true})

    on_exit(fn ->
      Application.put_env(:handbean, :web_push, previous)
      TaskTracker.reset()
    end)

    {:ok, subscription} =
      WebPush.subscribe(
        "dispatcher-browser",
        %{
          "endpoint" => "https://fcm.googleapis.com/fcm/send/dispatcher",
          "keys" => %{
            "p256dh" => Protocol.generate_key_pair().public_key,
            "auth" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
          }
        },
        "en"
      )

    {:ok, conversation} = Handbean.ConversationStore.create_free()
    task = %{conversation_id: conversation["id"], run_id: Ecto.UUID.generate(), workspace_id: nil}
    %{worker: worker, subscription: subscription, task: task}
  end

  test "a completed server run sends after all browser views have gone away", %{task: task} do
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(parent, :push_requested)
      Plug.Conn.send_resp(conn, 201, "")
    end)

    lifecycle(task, :run_start, %{})
    lifecycle(task, :run_end, %{status: "completed"})
    assert_receive :push_requested, 1_000
    assert TaskTracker.snapshot().tasks == []
  end

  test "transient provider failures retry and a successful subscription is not retried", %{
    worker: worker,
    task: task
  } do
    parent = self()

    Req.Test.expect(__MODULE__, fn conn ->
      send(parent, :first_attempt)
      Plug.Conn.send_resp(conn, 503, "temporary")
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      send(parent, :second_attempt)
      Plug.Conn.send_resp(conn, 201, "")
    end)

    Dispatcher.broadcast({:ended, task, :completed})
    assert_receive :first_attempt, 1_000
    assert_receive :second_attempt, 3_000
    # Stop the queue after the successful HTTP result; cleanup cannot leak into another test.
    :sys.get_state(worker)
    Req.Test.verify!()
  end

  test "cancellation invalidates queued waiting retries without notifying cancellation", %{
    worker: worker,
    task: task
  } do
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(parent, :waiting_attempt)
      Plug.Conn.send_resp(conn, 503, "temporary")
    end)

    lifecycle(task, :run_start, %{})
    lifecycle(task, :tool_approval_requested, %{})
    assert_receive :waiting_attempt, 1_000
    lifecycle(task, :run_end, %{status: "cancelled"})
    :sys.get_state(worker)
    refute_receive :waiting_attempt, 2_000
  end

  test "credential changes revoke a pending retry", %{task: task} do
    parent = self()
    previous_access = Application.get_env(:handbean, :access)
    on_exit(fn -> Application.put_env(:handbean, :access, previous_access) end)

    Req.Test.stub(__MODULE__, fn conn ->
      send(parent, :attempt)
      Plug.Conn.send_resp(conn, 503, "temporary")
    end)

    Dispatcher.broadcast({:ended, task, :completed})
    assert_receive :attempt, 1_000

    Application.put_env(:handbean, :access,
      mode: :password,
      username: "test",
      password: "changed"
    )

    refute_receive :attempt, 2_000
  end

  test "a pending waiting message is replaced by completion before it can be delivered", %{
    worker: worker,
    task: task
  } do
    parent = self()
    blocker = %{task | run_id: "blocking-run"}

    Req.Test.expect(__MODULE__, fn conn ->
      send(parent, {:blocked, self()})

      receive do
        :continue -> Plug.Conn.send_resp(conn, 201, "")
      end
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      send(parent, :completion_delivered)
      Plug.Conn.send_resp(conn, 201, "")
    end)

    Dispatcher.broadcast({:ended, blocker, :completed})
    assert_receive {:blocked, http_pid}, 1_000
    lifecycle(task, :run_start, %{})
    lifecycle(task, :tool_approval_requested, %{})
    lifecycle(task, :run_end, %{status: "completed"})
    :sys.get_state(worker)
    send(http_pid, :continue)
    assert_receive :completion_delivered, 1_000
    Req.Test.verify!()
  end

  test "an active fanout cannot confuse two waiting episodes of the same run", %{task: task} do
    stop_supervised!(Dispatcher)

    for index <- 1..4 do
      assert {:ok, _} =
               WebPush.subscribe(
                 "episode-browser-#{index}",
                 %{
                   "endpoint" => "https://fcm.googleapis.com/fcm/send/episode-#{index}",
                   "keys" => %{
                     "p256dh" => Protocol.generate_key_pair().public_key,
                     "auth" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
                   }
                 },
                 "en"
               )
    end

    parent = self()
    counter = start_supervised!({Agent, fn -> 0 end})

    Req.Test.stub(__MODULE__, fn conn ->
      index = Agent.get_and_update(counter, fn value -> {value + 1, value + 1} end)

      if index <= 4 do
        send(parent, {:first_episode, self()})

        receive do
          :continue -> :ok
        end
      else
        send(parent, :later_delivery)
      end

      Plug.Conn.send_resp(conn, 201, "")
    end)

    lifecycle(task, :run_start, %{})
    %{tasks: [first_waiting]} = lifecycle(task, :tool_approval_requested, %{})
    first = Task.async(fn -> Handbean.WebPush.Delivery.deliver({:waiting, first_waiting}) end)

    blocked =
      for _ <- 1..4 do
        assert_receive {:first_episode, pid}, 1_000
        pid
      end

    lifecycle(task, :run_resumed, %{})
    %{tasks: [next_waiting]} = lifecycle(task, :tool_approval_requested, %{})
    Enum.each(blocked, &send(&1, :continue))
    assert %{subscriptions: []} = Task.await(first)
    refute_received :later_delivery

    assert %{subscriptions: []} = Handbean.WebPush.Delivery.deliver({:waiting, next_waiting})
    for _ <- 1..5, do: assert_received(:later_delivery)
    refute_received :later_delivery
  end

  defp lifecycle(task, kind, payload) do
    send(
      TaskTracker,
      {:run_lifecycle, task.conversation_id, kind, Map.put(payload, :run_id, task.run_id)}
    )

    TaskTracker.snapshot()
  end
end
