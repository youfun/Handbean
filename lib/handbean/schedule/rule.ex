defmodule Handbean.Schedule.Rule do
  @moduledoc """
  Frequency rules for a schedule.

  Weekly clock times, a fixed interval, or one absolute instant.
  A missing local time (spring forward) uses the first valid instant after the
  gap. A repeated local time (fall back) uses the earlier instant.

  A one-shot delay is frozen by `prepare_once/3` before it is stored. The
  stored rule is the UTC instant plus the label from that moment.
  """

  @min_interval 1
  @min_once_seconds 60
  @once_busy_grace_seconds 30 * 60
  @weekdays 1..7

  @type rule :: map()
  @type due :: %{
          slot: DateTime.t(),
          missed: non_neg_integer(),
          missed_from: DateTime.t() | nil,
          missed_to: DateTime.t() | nil,
          next_run_at: DateTime.t()
        }

  @spec validate(term()) :: {:ok, rule()} | {:error, term()}
  def validate(rule), do: normalize(rule)

  @spec next_after(rule(), String.t(), DateTime.t()) :: {:ok, DateTime.t()} | {:error, term()}
  def next_after(rule, time_zone, %DateTime{} = utc) do
    with {:ok, rule} <- normalize(rule),
         :ok <- zone(time_zone) do
      case rule do
        %{kind: :once, at: at} ->
          if DateTime.compare(at, truncate(utc)) == :gt,
            do: {:ok, at},
            else: {:error, :in_the_past}

        _ ->
          {:ok, advance(rule, time_zone, truncate(utc))}
      end
    end
  end

  @spec latest_due(rule(), String.t(), DateTime.t(), DateTime.t()) ::
          {:ok, due()} | :not_due | {:error, term()}
  def latest_due(rule, time_zone, %DateTime{} = from, %DateTime{} = now) do
    from = truncate(from)
    now = truncate(now)

    with {:ok, rule} <- normalize(rule),
         :ok <- zone(time_zone) do
      case rule do
        %{kind: :once, at: at} -> once_due(at, from, now)
        _ -> recurring_due(rule, time_zone, from, now)
      end
    end
  end

  @spec upcoming(rule(), String.t(), DateTime.t(), pos_integer()) ::
          {:ok, [DateTime.t()]} | {:error, term()}
  def upcoming(rule, time_zone, %DateTime{} = from, count) when is_integer(count) and count > 0 do
    with {:ok, rule} <- normalize(rule),
         :ok <- zone(time_zone) do
      case rule do
        %{kind: :once, at: at} ->
          times = if DateTime.compare(at, truncate(from)) == :gt, do: [at], else: []
          {:ok, Enum.take(times, count)}

        _ ->
          with {:ok, first} <- next_after(rule, time_zone, from) do
            {:ok, unfold(rule, time_zone, first, count, [])}
          end
      end
    end
  end

  @spec describe(rule()) :: String.t()
  def describe(rule) do
    case normalize(rule) do
      {:ok, %{kind: :once, label: label}} ->
        label

      {:ok, %{kind: :interval, every_minutes: minutes}} ->
        describe_interval(minutes)

      {:ok, %{kind: :weekly, weekdays: days, times: times}} ->
        describe_weekly(days, times)

      _ ->
        "无效规则"
    end
  end

  @doc "Freeze a one-shot tool rule at `prepared_at`. Canonical rules stay put."
  @spec prepare_once(map(), String.t(), DateTime.t()) :: {:ok, rule()} | {:error, term()}
  def prepare_once(rule, time_zone, %DateTime{} = prepared_at) when is_map(rule) do
    prepared_at = truncate(prepared_at)

    with :ok <- zone(time_zone) do
      freeze_once(stringify(rule), time_zone, prepared_at)
    end
  end

  def prepare_once(_rule, _time_zone, _prepared_at), do: {:error, :invalid_rule}

  @spec once?(term()) :: boolean()
  def once?(rule) when is_map(rule), do: match?({:ok, %{kind: :once}}, normalize(rule))
  def once?(_rule), do: false

  @spec once_at(map()) :: {:ok, DateTime.t()} | :error
  def once_at(rule) when is_map(rule) do
    case normalize(rule) do
      {:ok, %{kind: :once, at: at}} -> {:ok, at}
      _ -> :error
    end
  end

  def once_at(_rule), do: :error

  @spec busy_deadline(map()) :: {:ok, DateTime.t()} | :error
  def busy_deadline(rule) do
    case once_at(rule) do
      {:ok, at} -> {:ok, DateTime.add(at, @once_busy_grace_seconds, :second)}
      :error -> :error
    end
  end

  @spec dump(rule()) :: map()
  def dump(rule) do
    case normalize(rule) do
      {:ok, %{kind: :once, at: at, label: label}} ->
        %{"kind" => "once", "at" => DateTime.to_iso8601(at), "label" => label}

      {:ok, %{kind: :weekly, weekdays: days, times: times}} ->
        %{
          "kind" => "weekly",
          "weekdays" => days,
          "times" => Enum.map(times, &format_time/1)
        }

      {:ok, %{kind: :interval, every_minutes: minutes}} ->
        %{"kind" => "interval", "every_minutes" => minutes}

      _ ->
        rule
    end
  end

  @spec valid_zone?(term()) :: boolean()
  def valid_zone?(name) when is_binary(name) and name != "" do
    match?(:ok, zone(name))
  end

  def valid_zone?(_), do: false

  @spec format_local(DateTime.t(), String.t()) :: String.t()
  def format_local(%DateTime{} = utc, time_zone) do
    case DateTime.shift_zone(truncate(utc), time_zone) do
      {:ok, local} -> Calendar.strftime(local, "%Y-%m-%d %H:%M")
      _ -> Calendar.strftime(truncate(utc), "%Y-%m-%d %H:%M UTC")
    end
  end

  defp recurring_due(rule, time_zone, from, now) do
    if DateTime.compare(from, now) == :gt do
      :not_due
    else
      collect(rule, time_zone, from, now, [])
    end
  end

  defp once_due(at, from, now) do
    cond do
      DateTime.compare(from, now) == :gt -> :not_due
      DateTime.compare(at, now) == :gt -> :not_due
      true -> {:ok, %{slot: at, missed: 0, missed_from: nil, missed_to: nil, next_run_at: nil}}
    end
  end

  defp freeze_once(rule, time_zone, prepared_at) do
    kind = Handbean.Utils.SafeMap.get_any(rule, ["kind", :kind])

    if kind not in ["once", :once] do
      {:error, :invalid_rule}
    else
      minutes = Handbean.Utils.SafeMap.get_any(rule, ["in_minutes", :in_minutes])
      at = Handbean.Utils.SafeMap.get_any(rule, ["at", :at])
      label = Handbean.Utils.SafeMap.get_any(rule, ["label", :label])

      cond do
        present?(minutes) and present?(at) ->
          {:error, :invalid_rule}

        present?(minutes) ->
          freeze_relative(minutes, prepared_at)

        match?({:ok, _}, canonical_instant(at)) ->
          {:ok, utc} = canonical_instant(at)
          freeze_canonical(utc, label, time_zone, prepared_at)

        present?(at) ->
          freeze_local(at, time_zone, prepared_at)

        true ->
          {:error, :invalid_rule}
      end
    end
  end

  defp freeze_relative(minutes, prepared_at) do
    case integer(minutes) do
      minutes when is_integer(minutes) and minutes >= @min_interval ->
        at = DateTime.add(prepared_at, minutes * @min_once_seconds, :second)
        {:ok, %{kind: :once, at: at, label: "#{minutes} 分钟后，只一次"}}

      _ ->
        {:error, :invalid_once}
    end
  end

  defp freeze_local(text, time_zone, prepared_at) do
    with {:ok, at} <- wall_utc(text, time_zone) do
      if DateTime.diff(at, prepared_at) < @min_once_seconds do
        {:error, :too_soon}
      else
        {:ok, %{kind: :once, at: at, label: format_local(at, time_zone) <> "，只一次"}}
      end
    end
  end

  defp freeze_canonical(utc, label, time_zone, prepared_at) do
    seconds_ahead = DateTime.diff(utc, prepared_at)

    if seconds_ahead >= 0 and seconds_ahead < @min_once_seconds do
      {:error, :too_soon}
    else
      {:ok, %{kind: :once, at: utc, label: label_or_default(label, utc, time_zone)}}
    end
  end

  defp label_or_default(label, _at, _time_zone) when is_binary(label) and label != "" do
    label
  end

  defp label_or_default(_label, at, time_zone) do
    format_local(at, time_zone) <> "，只一次"
  end

  defp present?(value) when value in [nil, ""], do: false
  defp present?(_value), do: true

  defp canonical_instant(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} ->
        {:ok, dt |> DateTime.shift_zone!("Etc/UTC") |> truncate()}

      _ ->
        :error
    end
  end

  defp canonical_instant(%DateTime{} = dt),
    do: {:ok, dt |> DateTime.shift_zone!("Etc/UTC") |> truncate()}

  defp canonical_instant(_value), do: :error

  defp wall_utc(text, time_zone) when is_binary(text) do
    case Regex.run(~r/^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2}))?$/, text) do
      [_, year, month, day, hour, minute, second] ->
        with {year, ""} <- Integer.parse(year),
             {month, ""} <- Integer.parse(month),
             {day, ""} <- Integer.parse(day),
             {hour, ""} <- Integer.parse(hour),
             {minute, ""} <- Integer.parse(minute),
             {:ok, date} <- Date.new(year, month, day),
             {:ok, time} <- Time.new(hour, minute, seconds(second)) do
          utc_wall(date, time, time_zone)
        else
          _ -> {:error, :invalid_once}
        end

      _ ->
        {:error, :invalid_once}
    end
  end

  defp wall_utc(_text, _time_zone), do: {:error, :invalid_once}

  defp seconds(nil), do: 0
  defp seconds(""), do: 0

  defp seconds(value) do
    case Integer.parse(value) do
      {seconds, ""} -> seconds
      _ -> :error
    end
  end

  defp utc_wall(date, time, time_zone) do
    naive = NaiveDateTime.new!(date, time)

    utc =
      case DateTime.from_naive(naive, time_zone) do
        {:ok, dt} -> dt
        {:ambiguous, earlier, _later} -> earlier
        {:gap, _before, just_after} -> just_after
        _ -> nil
      end

    if utc do
      {:ok, utc |> DateTime.shift_zone!("Etc/UTC") |> truncate()}
    else
      {:error, :invalid_once}
    end
  end

  defp unfold(_rule, _tz, _slot, 0, acc), do: Enum.reverse(acc)

  defp unfold(rule, tz, slot, count, acc) do
    next = advance(rule, tz, slot)
    unfold(rule, tz, next, count - 1, [slot | acc])
  end

  defp collect(rule, tz, slot, now, earlier) do
    next = advance(rule, tz, slot)

    cond do
      DateTime.compare(slot, now) == :gt ->
        finish(Enum.reverse(earlier), slot)

      DateTime.compare(next, slot) != :gt ->
        {:error, :rule_did_not_advance}

      true ->
        collect(rule, tz, next, now, [slot | earlier])
    end
  end

  defp finish([], _next), do: :not_due

  defp finish(slots, next) do
    {missed, [slot]} = Enum.split(slots, -1)

    {:ok,
     %{
       slot: slot,
       missed: length(missed),
       missed_from: List.first(missed),
       missed_to: List.last(missed),
       next_run_at: next
     }}
  end

  defp advance(%{kind: :interval, every_minutes: minutes}, _tz, utc) do
    DateTime.add(utc, minutes * 60, :second)
  end

  defp advance(%{kind: :weekly} = rule, tz, utc) do
    local = DateTime.shift_zone!(utc, tz)
    start = Date.add(DateTime.to_date(local), -1)

    Enum.find_value(0..14, fn offset ->
      date = Date.add(start, offset)

      if Date.day_of_week(date) in rule.weekdays do
        Enum.find_value(rule.times, fn time ->
          occurrence = local_occurrence(date, time, tz)
          if DateTime.compare(occurrence, utc) == :gt, do: occurrence
        end)
      end
    end) || DateTime.add(utc, 24 * 3600, :second)
  end

  defp local_occurrence(date, {hour, minute}, tz) do
    {:ok, naive} = NaiveDateTime.new(date, Time.new!(hour, minute, 0))

    utc =
      case DateTime.from_naive(naive, tz) do
        {:ok, dt} -> dt
        {:ambiguous, earlier, _later} -> earlier
        {:gap, _before, just_after} -> just_after
      end

    utc
    |> DateTime.shift_zone!("Etc/UTC")
    |> truncate()
  end

  defp normalize(%{kind: kind} = rule), do: normalize(stringify(rule) |> Map.put("kind", kind))

  defp normalize(%{"kind" => kind} = rule) when kind in ["weekly", :weekly] do
    with {:ok, days} <- weekdays(Handbean.Utils.SafeMap.get_any(rule, ["weekdays", :weekdays])),
         {:ok, times} <- times(Handbean.Utils.SafeMap.get_any(rule, ["times", :times])) do
      {:ok, %{kind: :weekly, weekdays: days, times: times}}
    end
  end

  defp normalize(%{"kind" => kind} = rule) when kind in ["once", :once] do
    at = Handbean.Utils.SafeMap.get_any(rule, ["at", :at])
    label = Handbean.Utils.SafeMap.get_any(rule, ["label", :label])
    minutes = Handbean.Utils.SafeMap.get_any(rule, ["in_minutes", :in_minutes])

    cond do
      present?(minutes) ->
        {:error, :invalid_rule}

      match?({:ok, _}, canonical_instant(at)) and is_binary(label) and label != "" ->
        {:ok, utc} = canonical_instant(at)
        {:ok, %{kind: :once, at: utc, label: label}}

      true ->
        {:error, :invalid_rule}
    end
  end

  defp normalize(%{"kind" => kind} = rule) when kind in ["interval", :interval] do
    case integer(Handbean.Utils.SafeMap.get_any(rule, ["every_minutes", :every_minutes])) do
      minutes when is_integer(minutes) and minutes >= @min_interval ->
        {:ok, %{kind: :interval, every_minutes: minutes}}

      _ ->
        {:error, :invalid_interval}
    end
  end

  defp normalize(_), do: {:error, :invalid_rule}

  defp weekdays(days) when is_list(days) and days != [] do
    parsed = Enum.map(days, &integer/1)

    if Enum.all?(parsed, &(&1 in @weekdays)) and parsed == Enum.uniq(parsed) do
      {:ok, Enum.sort(parsed)}
    else
      {:error, :invalid_weekdays}
    end
  end

  defp weekdays(_), do: {:error, :invalid_weekdays}

  defp times(times) when is_list(times) and times != [] do
    parsed = Enum.map(times, &parse_time/1)

    cond do
      Enum.any?(parsed, &(&1 == :error)) ->
        {:error, :invalid_times}

      parsed != Enum.uniq(parsed) ->
        {:error, :invalid_times}

      true ->
        {:ok, Enum.sort(parsed)}
    end
  end

  defp times(_), do: {:error, :invalid_times}

  defp parse_time(value) when is_binary(value) do
    case String.split(value, ":") do
      [hour, minute] ->
        with {hour, ""} <- Integer.parse(hour),
             {minute, ""} <- Integer.parse(minute),
             true <- hour in 0..23 and minute in 0..59 do
          {hour, minute}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp parse_time({hour, minute}) when hour in 0..23 and minute in 0..59, do: {hour, minute}
  defp parse_time(_), do: :error

  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> :error
    end
  end

  defp integer(_), do: :error

  defp zone(name) when is_binary(name) and name != "" do
    case DateTime.now(name) do
      {:ok, _} -> :ok
      _ -> {:error, :invalid_time_zone}
    end
  end

  defp zone(_), do: {:error, :invalid_time_zone}

  defp stringify(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp truncate(%DateTime{} = dt), do: DateTime.truncate(dt, :second)

  defp describe_interval(minutes) when rem(minutes, 60) == 0 and div(minutes, 60) > 1 do
    "每 #{div(minutes, 60)} 小时"
  end

  defp describe_interval(60), do: "每 1 小时"
  defp describe_interval(1), do: "每 1 分钟"
  defp describe_interval(minutes), do: "每 #{minutes} 分钟"

  defp describe_weekly(days, times) do
    prefix =
      cond do
        days == Enum.to_list(1..7) -> "每天"
        days == Enum.to_list(1..5) -> "工作日"
        true -> "每周" <> weekday_labels(days)
      end

    prefix <> " " <> Enum.map_join(times, "、", &format_time/1)
  end

  defp weekday_labels(days) do
    names = %{1 => "一", 2 => "二", 3 => "三", 4 => "四", 5 => "五", 6 => "六", 7 => "日"}
    Enum.map_join(days, "、", &Map.fetch!(names, &1))
  end

  defp format_time({hour, minute}) do
    :io_lib.format("~2..0B:~2..0B", [hour, minute]) |> IO.iodata_to_binary()
  end
end
