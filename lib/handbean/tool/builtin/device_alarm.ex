defmodule Handbean.Tool.Builtin.DeviceAlarm do
  @moduledoc """
  Prefill the system clock alarm screen.

  This launches `AlarmClock.ACTION_SET_ALARM`. It does not write an alarm
  silently, and it does not use accessibility. Many devices still require the
  user to tap save.
  """

  @behaviour Handbean.Agent.Tool

  alias Handbean.ArtifactDelivery
  alias Handbean.ArtifactDelivery.Input

  @keys ~w(hour minute message skip_ui vibrate days)

  @impl true
  def name, do: "device_alarm"

  @impl true
  def description do
    "Open the system clock with an alarm time prefilled. Use this when the user " <>
      "asks to set, change, or be reminded by a clock alarm. Hour is 0-23 and minute " <>
      "is 0-59 in the device local clock. This is not a silent write: many devices " <>
      "still require the user to tap save, and no accessibility service is used. " <>
      "Success means the clock UI was shown, not that the alarm was saved. " <>
      "For a calendar event, use device_calendar instead. iOS does not support this tool."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      additionalProperties: false,
      required: ["hour", "minute"],
      properties: %{
        hour: %{
          type: "integer",
          minimum: 0,
          maximum: 23,
          description: "Hour on a 24-hour clock, device local time."
        },
        minute: %{
          type: "integer",
          minimum: 0,
          maximum: 59,
          description: "Minute, device local time."
        },
        message: %{
          type: "string",
          maxLength: 120,
          description: "Optional alarm label shown in the clock app."
        },
        skip_ui: %{
          type: "boolean",
          description:
            "Ask the clock app to skip its confirmation UI when it supports EXTRA_SKIP_UI. Defaults to false. This is still not a guaranteed silent write."
        },
        vibrate: %{
          type: "boolean",
          description: "Optional vibration hint. Omitted when unset."
        },
        days: %{
          type: "array",
          maxItems: 7,
          items: %{type: "integer", minimum: 1, maximum: 7},
          description:
            "Optional repeat days. 1 is Sunday through 7 is Saturday, matching Calendar.SUNDAY."
        }
      }
    }
  end

  @impl true
  def concurrent?, do: false

  @impl true
  def execute(input, context) when is_map(input) and is_map(context) do
    with {:ok, fields} <- Input.take(input, @keys),
         :ok <- validate(fields),
         {:ok, result} <- ArtifactDelivery.dispatch(command(fields), context) do
      finish(result)
    else
      {:error, :raw_intent_rejected} ->
        {:error, "raw Intent fields are not allowed"}

      {:error, :unexpected_fields} ->
        {:error, "only hour, minute, message, skip_ui, vibrate, and days are accepted"}

      {:error, :unavailable} ->
        {:error, "the system clock is not available on this host"}

      {:error, reason} when is_atom(reason) ->
        {:error, message(reason)}

      {:error, reason} when is_binary(reason) ->
        {:error, message(reason)}
    end
  end

  def execute(_, _), do: {:error, "invalid device_alarm input"}

  defp validate(fields) do
    with :ok <- clock(fields["hour"], fields["minute"]),
         :ok <- optional_message(fields["message"]),
         :ok <- optional_bool(fields, "skip_ui"),
         :ok <- optional_bool(fields, "vibrate") do
      optional_days(fields["days"])
    end
  end

  defp clock(hour, minute)
       when is_integer(hour) and hour in 0..23 and is_integer(minute) and minute in 0..59,
       do: :ok

  defp clock(_, _), do: {:error, :invalid_time}

  defp optional_message(nil), do: :ok

  defp optional_message(text) when is_binary(text) and byte_size(text) <= 480 do
    if String.trim(text) == "", do: {:error, :invalid_message}, else: :ok
  end

  defp optional_message(_), do: {:error, :invalid_message}

  defp optional_bool(fields, key) do
    case fields[key] do
      nil -> :ok
      value when is_boolean(value) -> :ok
      _ -> {:error, :invalid_input}
    end
  end

  defp optional_days(nil), do: :ok

  defp optional_days(days) when is_list(days) and length(days) in 1..7 do
    if Enum.all?(days, &(&1 in 1..7)) and days == Enum.uniq(days) do
      :ok
    else
      {:error, :invalid_days}
    end
  end

  defp optional_days(_), do: {:error, :invalid_days}

  defp command(fields) do
    %{
      op: :device_alarm,
      hour: fields["hour"],
      minute: fields["minute"],
      message: fields["message"],
      skip_ui: fields["skip_ui"] == true,
      vibrate: fields["vibrate"],
      days: fields["days"]
    }
  end

  defp finish(%{outcome: outcome} = result) do
    text = alarm_text(outcome)
    details = Map.take(result, [:outcome, :hour, :minute])

    if ArtifactDelivery.presented?(outcome) or outcome == "alarm_prefilled" do
      {:ok, text, details}
    else
      {:error, text, details}
    end
  end

  defp finish(result) when is_map(result), do: finish(normalize(result))
  defp finish(_), do: {:error, ArtifactDelivery.format_outcome("outcome_unknown")}

  defp alarm_text("alarm_prefilled") do
    "已打开系统时钟并预填闹钟。很多机型还要用户再点一次保存。这不是静默写入。"
  end

  defp alarm_text("ui_presented") do
    "已打开系统时钟并预填闹钟。这只表示界面已出现，不表示闹钟已保存。"
  end

  defp alarm_text(outcome), do: message(outcome)

  defp message("needs_foreground"), do: ArtifactDelivery.format_outcome("needs_foreground")
  defp message("no_handler"), do: "设备上没有可设置闹钟的时钟应用。"
  defp message("invalid_time"), do: "hour 必须是 0-23，minute 必须是 0-59。"
  defp message("invalid_message"), do: "闹钟标签不能为空，且最长 120 个字符。"
  defp message("invalid_days"), do: "days 必须是 1 到 7 的不重复星期列表。"
  defp message("invalid_input"), do: ArtifactDelivery.format_outcome("invalid_input")

  defp message("cancelled_before_launch"),
    do: ArtifactDelivery.format_outcome("cancelled_before_launch")

  defp message(other), do: ArtifactDelivery.format_outcome(other)

  defp normalize(map) do
    %{
      outcome: to_string(field(map, "outcome") || "outcome_unknown"),
      hour: field(map, "hour"),
      minute: field(map, "minute")
    }
  end

  defp field(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, atom_key(key))
  end

  defp field(_, _), do: nil

  defp atom_key(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
