defmodule Handbean.Tool.Builtin.DeviceCalendar do
  @moduledoc """
  Read and write the device system calendar after the user grants access.

  Android inserts through `CalendarContract` without opening the calendar app.
  iOS presents the system event editor instead of writing silently. Success of
  a write means the event was inserted or the editor was shown, not that the
  user will attend.
  """

  @behaviour Handbean.Agent.Tool

  alias Handbean.ArtifactDelivery
  alias Handbean.ArtifactDelivery.Input

  @read_keys ~w(calendar_action calendar_id query start_ms end_ms limit)
  @write_keys ~w(calendar_action title start_ms end_ms description location all_day calendar_id)
  @actions ~w(list_calendars list_events insert_event)

  @impl true
  def name, do: "device_calendar"

  @impl true
  def description do
    "Read or write the device system calendar after the user grants calendar access. " <>
      "Set calendar_action to list_calendars, list_events, or insert_event. " <>
      "On Android an authorized insert " <>
      "writes CalendarContract without opening the calendar app. iOS does not " <>
      "support this tool. Times are UTC epoch milliseconds. This is not an in-app " <>
      "reminder and not a silent alarm."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      additionalProperties: false,
      required: ["calendar_action"],
      properties: %{
        calendar_action: %{
          type: "string",
          enum: @actions,
          description: "list_calendars, list_events, or insert_event."
        },
        calendar_id: %{
          type: "string",
          maxLength: 64,
          description:
            "Calendar id from list_calendars. Optional; the primary calendar is used when omitted."
        },
        query: %{
          type: "string",
          maxLength: 200,
          description: "Optional title filter for list_events."
        },
        start_ms: %{
          type: "integer",
          description: "Window start or event start, UTC epoch milliseconds."
        },
        end_ms: %{
          type: "integer",
          description: "Window end or event end, UTC epoch milliseconds. Must be after start_ms."
        },
        limit: %{
          type: "integer",
          minimum: 1,
          maximum: 50,
          description: "Maximum events to return. Defaults to 20."
        },
        title: %{
          type: "string",
          maxLength: 200,
          description: "Event title. Required for insert_event."
        },
        description: %{
          type: "string",
          maxLength: 2000,
          description: "Optional event notes."
        },
        location: %{
          type: "string",
          maxLength: 300,
          description: "Optional event location."
        },
        all_day: %{
          type: "boolean",
          description: "When true, the event is an all-day event. Defaults to false."
        }
      }
    }
  end

  @impl true
  def concurrent?, do: false

  @impl true
  def execute(input, context) when is_map(input) and is_map(context) do
    with {:ok, action, fields} <- take(input),
         :ok <- validate(action, fields),
         {:ok, result} <- ArtifactDelivery.dispatch(command(action, fields), context) do
      finish(action, result)
    else
      {:error, :raw_intent_rejected} ->
        {:error, "raw Intent fields are not allowed"}

      {:error, :unexpected_fields} ->
        {:error, "only calendar fields for the chosen calendar_action are accepted"}

      {:error, :unavailable} ->
        {:error, "the system calendar is not available on this host"}

      {:error, reason} when is_atom(reason) ->
        {:error, message(reason)}

      {:error, reason} when is_binary(reason) ->
        {:error, message(reason)}
    end
  end

  def execute(_, _), do: {:error, "invalid device_calendar input"}

  defp take(input) do
    with {:ok, fields} <- Input.take(input, Enum.uniq(@read_keys ++ @write_keys)),
         action when action in @actions <- fields["calendar_action"] do
      {:ok, action, fields}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_action}
    end
  end

  defp validate("list_calendars", fields) do
    extra =
      Enum.any?(
        ~w(query start_ms end_ms limit title description location all_day calendar_id),
        &Map.has_key?(fields, &1)
      )

    if extra, do: {:error, :unexpected_fields}, else: :ok
  end

  defp validate("list_events", fields) do
    with :ok <- reject_write_fields(fields),
         :ok <- optional_window(fields),
         :ok <- optional_limit(fields),
         :ok <- optional_text(fields, "query", 200) do
      optional_id(fields, "calendar_id")
    end
  end

  defp validate("insert_event", fields) do
    with :ok <- required_title(fields),
         :ok <- required_range(fields),
         :ok <- optional_text(fields, "description", 2000),
         :ok <- optional_text(fields, "location", 300),
         :ok <- optional_id(fields, "calendar_id"),
         :ok <- optional_bool(fields, "all_day") do
      if Map.has_key?(fields, "query") or Map.has_key?(fields, "limit") do
        {:error, :unexpected_fields}
      else
        :ok
      end
    end
  end

  defp reject_write_fields(fields) do
    if Enum.any?(~w(title description location all_day), &Map.has_key?(fields, &1)) do
      {:error, :unexpected_fields}
    else
      :ok
    end
  end

  defp optional_window(fields) do
    case {fields["start_ms"], fields["end_ms"]} do
      {nil, nil} -> :ok
      {start_ms, end_ms} -> range(start_ms, end_ms)
    end
  end

  defp required_range(fields), do: range(fields["start_ms"], fields["end_ms"])

  defp range(start_ms, end_ms) do
    cond do
      not epoch_ms?(start_ms) or not epoch_ms?(end_ms) -> {:error, :invalid_time}
      end_ms <= start_ms -> {:error, :invalid_time}
      end_ms - start_ms > 366 * 86_400_000 -> {:error, :invalid_time}
      true -> :ok
    end
  end

  defp epoch_ms?(value) when is_integer(value), do: value >= 0 and value <= 4_102_444_800_000
  defp epoch_ms?(_), do: false

  defp optional_limit(%{"limit" => limit}) when is_integer(limit) and limit >= 1 and limit <= 50,
    do: :ok

  defp optional_limit(%{"limit" => _}), do: {:error, :invalid_limit}
  defp optional_limit(_), do: :ok

  defp required_title(%{"title" => title}) when is_binary(title) do
    if String.trim(title) == "" or String.length(title) > 200,
      do: {:error, :invalid_title},
      else: :ok
  end

  defp required_title(_), do: {:error, :invalid_title}

  defp optional_text(fields, key, max) do
    case fields[key] do
      nil -> :ok
      text when is_binary(text) and byte_size(text) <= max * 4 -> :ok
      _ -> {:error, :invalid_text}
    end
  end

  defp optional_id(fields, key) do
    case fields[key] do
      nil -> :ok
      id when is_binary(id) and byte_size(id) in 1..64 -> :ok
      _ -> {:error, :invalid_calendar}
    end
  end

  defp optional_bool(fields, key) do
    case fields[key] do
      nil -> :ok
      value when is_boolean(value) -> :ok
      _ -> {:error, :invalid_input}
    end
  end

  defp command(action, fields) do
    %{
      op: :device_calendar,
      calendar_action: action,
      calendar_id: fields["calendar_id"],
      query: blank_to_nil(fields["query"]),
      start_ms: fields["start_ms"],
      end_ms: fields["end_ms"],
      limit: fields["limit"] || 20,
      title: fields["title"],
      description: fields["description"],
      location: fields["location"],
      all_day: fields["all_day"] == true
    }
  end

  defp blank_to_nil(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil

  defp finish("insert_event", %{outcome: outcome} = result) do
    text = insert_text(outcome, result)
    details = Map.take(result, [:outcome, :event_id, :calendar_id])

    if ArtifactDelivery.presented?(outcome) or outcome in ~w(inserted editor_presented) do
      {:ok, text, details}
    else
      {:error, text, details}
    end
  end

  defp finish(_action, %{outcome: "listed"} = result) do
    {:ok, listed_text(result), Map.take(result, [:outcome, :calendars, :events])}
  end

  defp finish(_action, %{outcome: outcome} = result) do
    {:error, message(outcome), Map.take(result, [:outcome])}
  end

  defp finish(_action, result) when is_map(result), do: finish(:read, normalize(result))
  defp finish(_, _), do: {:error, ArtifactDelivery.format_outcome("outcome_unknown")}

  defp insert_text("inserted", result) do
    id = result[:event_id]
    base = "已写入系统日历。事件已直接插入，没有打开日历应用。"
    if is_binary(id) and id != "", do: base <> " 事件 id：#{id}。", else: base
  end

  defp insert_text(outcome, _result), do: message(outcome)

  defp listed_text(%{calendars: calendars}) when is_list(calendars) do
    if calendars == [] do
      "没有可读写的系统日历。"
    else
      lines =
        Enum.map_join(calendars, "\n", fn cal ->
          name = field(cal, "name") || "日历"
          id = field(cal, "id")
          "- #{name} (id #{id})"
        end)

      "系统日历：\n" <> lines
    end
  end

  defp listed_text(%{events: events}) when is_list(events) do
    if events == [] do
      "这个时间范围内没有日历事件。"
    else
      lines =
        Enum.map_join(events, "\n", fn event ->
          title = field(event, "title") || "（无标题）"
          start_ms = field(event, "start_ms")
          "- #{title} @ #{start_ms}"
        end)

      "日历事件：\n" <> lines
    end
  end

  defp listed_text(_), do: "已读取系统日历。"

  defp message("permission_denied"), do: "没有日历权限。请授权后再试。"
  defp message("needs_foreground"), do: ArtifactDelivery.format_outcome("needs_foreground")
  defp message("no_calendar"), do: "设备上没有可写入的日历。"
  defp message("no_handler"), do: "设备上没有可处理该请求的日历应用。"
  defp message(:invalid_time), do: "开始和结束时间必须是合法的 UTC 毫秒，且结束晚于开始。"
  defp message("invalid_time"), do: message(:invalid_time)
  defp message("invalid_title"), do: "事件标题不能为空。"

  defp message("invalid_action"),
    do: "calendar_action 必须是 list_calendars、list_events 或 insert_event。"

  defp message("invalid_calendar"), do: "calendar_id 无效。"
  defp message("invalid_limit"), do: "limit 必须是 1 到 50。"
  defp message("invalid_text"), do: "日历文本字段过长。"
  defp message("invalid_input"), do: ArtifactDelivery.format_outcome("invalid_input")

  defp message("cancelled_before_launch"),
    do: ArtifactDelivery.format_outcome("cancelled_before_launch")

  defp message("user_rejected"), do: "用户取消了日历编辑。"

  defp message(other) when is_binary(other) or is_atom(other),
    do: ArtifactDelivery.format_outcome(to_string(other))

  defp normalize(map) do
    %{
      outcome: to_string(field(map, "outcome") || "outcome_unknown"),
      event_id: field(map, "event_id"),
      calendar_id: field(map, "calendar_id"),
      calendars: field(map, "calendars"),
      events: field(map, "events")
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
