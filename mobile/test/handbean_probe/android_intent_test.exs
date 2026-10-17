defmodule HandbeanProbe.AndroidIntentTest do
  use ExUnit.Case, async: false

  alias HandbeanProbe.AndroidIntent

  setup do
    previous_fake = Application.get_env(:handbean_probe, :platform_fake)
    previous_ms = Application.get_env(:handbean_probe, :android_intent_await_ms)

    on_exit(fn ->
      if previous_fake,
        do: Application.put_env(:handbean_probe, :platform_fake, previous_fake),
        else: Application.delete_env(:handbean_probe, :platform_fake)

      if previous_ms,
        do: Application.put_env(:handbean_probe, :android_intent_await_ms, previous_ms),
        else: Application.delete_env(:handbean_probe, :android_intent_await_ms)
    end)

    :ok
  end

  test "waiter is isolated and does not drain the caller mailbox" do
    test = self()

    Application.put_env(:handbean_probe, :platform_fake, fn req, _ ->
      send(test, {:started, req.caller, req.request_id, req.payload["deadline_ms"]})
      send(req.caller, {:engine_result, %{request_id: "other", result: "{}"}})

      send(
        req.caller,
        {:engine_result,
         %{
           request_id: req.request_id,
           result: Jason.encode!(%{outcome: "ui_presented"})
         }}
      )

      {:ok, :async}
    end)

    send(self(), {:keep_me, :inbox})

    assert {:ok, %{outcome: "ui_presented"}} =
             AndroidIntent.dispatch(%{op: :open_url, url: "https://example.com"}, %{})

    assert_received {:keep_me, :inbox}
    assert_received {:started, waiter, _id, deadline}
    assert waiter != self()
    assert is_integer(deadline)
    assert_received {:engine_result, %{request_id: "other"}}
  end

  test "timeout cancels the platform request and does not claim success" do
    test = self()
    Application.put_env(:handbean_probe, :android_intent_await_ms, 30)

    Application.put_env(:handbean_probe, :platform_fake, fn req, _ ->
      send(test, {:started, req.request_id})

      if req.op == "platform_cancel" do
        send(test, {:cancelled, req.payload["target_request_id"]})
        {:ok, %{ok: true}}
      else
        {:ok, :async}
      end
    end)

    assert {:error, :timeout} =
             AndroidIntent.dispatch(%{op: :open_url, url: "https://example.com/late"}, %{})

    assert_receive {:started, request_id}, 200
    assert_receive {:cancelled, ^request_id}, 200
  end

  test "calendar and alarm commands keep typed fields and return inserted rows" do
    test_pid = self()

    Application.put_env(:handbean_probe, :platform_fake, fn req, _ ->
      send(test_pid, {:payload, req.op, req.payload})

      result =
        case req.op do
          "platform_device_calendar" ->
            %{
              "outcome" => "inserted",
              "event_id" => "9",
              "calendar_id" => "3",
              "calendars" => [%{"id" => "3", "name" => "个人"}]
            }

          "platform_device_alarm" ->
            %{"outcome" => "alarm_prefilled", "hour" => 7, "minute" => 5}
        end

      send(
        req.caller,
        {:engine_result, %{request_id: req.request_id, result: Jason.encode!(result)}}
      )

      {:ok, :async}
    end)

    assert {:ok, calendar} =
             AndroidIntent.dispatch(
               %{
                 op: :device_calendar,
                 calendar_action: "insert_event",
                 title: "复诊",
                 start_ms: 100,
                 end_ms: 200,
                 all_day: false
               },
               %{}
             )

    assert calendar.outcome == "inserted"
    assert calendar.event_id == "9"
    assert [%{"name" => "个人"}] = calendar.calendars
    assert_received {:payload, "platform_device_calendar", payload}
    assert payload["action"] == "insert_event"
    assert payload["title"] == "复诊"
    refute Map.has_key?(payload, "intent")

    assert {:ok, %{outcome: "alarm_prefilled", hour: 7, minute: 5}} =
             AndroidIntent.dispatch(%{op: :device_alarm, hour: 7, minute: 5, skip_ui: false}, %{})
  end
end
