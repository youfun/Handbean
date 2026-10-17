defmodule Handbean.Threads.Trajectory do
  @moduledoc false

  alias Handbean.{ConversationStore, Threads}

  @detail_levels ~w(summary compact full)
  @record_kinds ~w(user assistant tool system)
  @cursor_salt "thread-trajectory-page"

  def get(input, context) do
    with :ok <-
           Threads.validate(
             input,
             ~w(thread run_id turn detail_level kinds errors_only limit max_chars cursor)
           ),
         {:ok, thread_id} <- Threads.text(input, "thread", nil, 256),
         {:ok, _meta} <- Threads.authorize(context, thread_id),
         {:ok, run_id} <- optional_text(input, "run_id", 256),
         {:ok, turn_number} <- optional_integer(input, "turn", 1, 1_000_000),
         true <- is_nil(turn_number) or is_binary(run_id),
         {:ok, detail_level} <- detail_level(input),
         {:ok, kinds} <- kinds(input),
         true <- is_boolean(Map.get(input, "errors_only", false)),
         {:ok, limit} <- Threads.integer(input, "limit", 50, 1, 50),
         {:ok, max_chars} <- Threads.integer(input, "max_chars", 8_000, 2_000, 16_000),
         binding <- binding(context, input),
         {:ok, page} <- cursor_position(input["cursor"], binding),
         {:ok, snapshot} <-
           ConversationStore.trajectory_snapshot(
             thread_id,
             run_id: run_id,
             turn_number: turn_number,
             kinds: kinds,
             errors_only: Map.get(input, "errors_only", false),
             limit: limit,
             after_sequence: page.after_sequence,
             snapshot_version: page.snapshot_version
           ) do
      response(
        snapshot,
        binding,
        detail_level,
        max_chars,
        page.after_sequence,
        run_id,
        turn_number,
        kinds,
        Map.get(input, "errors_only", false)
      )
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  defp response(
         snapshot,
         binding,
         detail_level,
         max_chars,
         _after_sequence,
         run_id,
         turn_number,
         kinds,
         errors_only
       ) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()

    base = %{
      schema_version: 1,
      detail_level: detail_level,
      generated_at: generated_at,
      snapshot_id: snapshot_id(snapshot.thread.id, snapshot.snapshot_version),
      thread: snapshot.thread,
      stats: snapshot.stats,
      fidelity: snapshot.fidelity,
      filters: %{
        run_id: run_id,
        turn: turn_number,
        kinds: kinds,
        errors_only: errors_only
      }
    }

    {base, _collection_reserve} =
      bound_header_collections(
        base,
        snapshot.runs,
        snapshot.turns,
        snapshot.runs_truncated?,
        snapshot.turns_truncated?,
        detail_level,
        max_chars
      )

    if detail_level == "summary" do
      {:ok,
       base
       |> Map.put(:records, [])
       |> Map.put(:truncated, false)
       |> Map.put(:next_cursor, nil)}
    else
      projected = Enum.map(snapshot.entries, &project_record(&1, detail_level))
      record_budget = max(max_chars - encoded_size(base) - 600, 0)
      {records, consumed} = take_records(projected, record_budget)
      source_count = length(snapshot.entries)
      more? = consumed < source_count or snapshot.entries_have_more?
      last_sequence = records |> List.last() |> then(&(&1 && &1.sequence))

      next_cursor =
        if more? and is_integer(last_sequence) do
          Handbean.EndpointAdapter.sign(
            @cursor_salt,
            {binding, snapshot.snapshot_version, last_sequence}
          )
        end

      {:ok,
       base
       |> Map.put(:records, records)
       |> Map.put(:truncated, more?)
       |> Map.put(:next_cursor, next_cursor)}
    end
  end

  defp bound_header_collections(
         base,
         runs,
         turns,
         runs_truncated?,
         turns_truncated?,
         detail_level,
         max_chars
       ) do
    base_size = encoded_size(base)

    collection_budget =
      if detail_level == "summary" do
        max(max_chars - base_size - 300, 0)
      else
        max(max_chars - base_size - 1_000, 0)
      end

    run_budget = div(collection_budget, 2)
    {kept_runs, more_runs?} = take_json_items(runs, run_budget)
    used = encoded_size(kept_runs)
    {kept_turns, more_turns?} = take_json_items(turns, max(collection_budget - used, 0))

    header =
      base
      |> Map.put(:runs, kept_runs)
      |> Map.put(:runs_truncated, runs_truncated? or more_runs?)
      |> Map.put(:turns, kept_turns)
      |> Map.put(:turns_truncated, turns_truncated? or more_turns?)

    {header, 600}
  end

  defp take_json_items(items, budget) do
    {kept, _used, consumed} =
      Enum.reduce_while(items, {[], 2, 0}, fn item, {kept, used, consumed} ->
        size = encoded_size(item) + if(kept == [], do: 0, else: 1)

        if used + size <= budget do
          {:cont, {[item | kept], used + size, consumed + 1}}
        else
          {:halt, {kept, used, consumed}}
        end
      end)

    {Enum.reverse(kept), consumed < length(items)}
  end

  defp take_records([], _budget), do: {[], 0}

  defp take_records(records, budget) do
    {kept, _used, consumed} =
      Enum.reduce_while(records, {[], 2, 0}, fn record, {kept, used, consumed} ->
        size = encoded_size(record) + if(kept == [], do: 0, else: 1)

        cond do
          used + size <= budget ->
            {:cont, {[record | kept], used + size, consumed + 1}}

          kept == [] ->
            bounded = minimal_record(record, budget)
            {:halt, {[bounded], encoded_size(bounded) + 2, 1}}

          true ->
            {:halt, {kept, used, consumed}}
        end
      end)

    {Enum.reverse(kept), consumed}
  end

  defp minimal_record(record, budget) do
    minimal =
      record
      |> Map.take([
        :id,
        :sequence,
        :revision,
        :run_id,
        :turn,
        :kind,
        :event,
        :status,
        :tool_name,
        :started_at,
        :completed_at,
        :duration_ms,
        :timing_fidelity
      ])
      |> Map.update(:id, nil, &bound_text(&1, 200))
      |> Map.update(:run_id, nil, &bound_text(&1, 200))
      |> Map.update(:tool_name, nil, &bound_text(&1, 200))
      |> Map.put(:summary, bound_text(record.summary, max(div(budget, 3), 80)))
      |> Map.put(:detail_truncated, true)

    if encoded_size(minimal) <= budget do
      minimal
    else
      minimal |> Map.delete(:summary) |> Map.delete(:started_at) |> Map.delete(:completed_at)
    end
  end

  defp project_record(entry, detail_level) do
    kind = record_kind(entry)
    status = record_status(entry, kind)
    timing_fidelity = entry["timing_fidelity"]

    base = %{
      id: entry["id"],
      sequence: entry["sequence"],
      revision: entry["revision"],
      run_id: entry["run_id"],
      turn: entry["turn_number"],
      kind: kind,
      event: record_event(kind, status),
      status: status,
      summary: record_summary(entry, kind),
      created_at: entry["created_at"],
      updated_at: entry["updated_at"]
    }

    base =
      if kind == "tool" do
        base
        |> Map.put(:tool_name, entry["tool_name"])
        |> Map.put(:tool_call_id, entry["tool_call_id"] || entry["tool_use_id"])
        |> Map.put(:parent_tool_call_id, entry["parent_tool_call_id"])
        |> Map.put(:started_at, entry["started_at"] || entry["created_at"])
        |> Map.put(:completed_at, completed_at(entry, status))
        |> Map.put(:timing_fidelity, timing_fidelity || "unknown")
        |> maybe_put_exact_duration(entry, timing_fidelity)
        |> Map.put(:file_path, bound_value(sanitize(entry["file_path"]), 1_000))
      else
        base
      end

    case detail_level do
      "full" -> put_full_fields(base, entry, kind)
      _ -> base
    end
    |> drop_nil_values()
  end

  defp put_full_fields(base, entry, "tool") do
    base
    |> Map.put(:input, bound_value(sanitize(entry["input"]), 4_000))
    |> Map.put(:output, bound_value(sanitize(entry["output"]), 4_000))
    |> Map.put(:error, bound_value(sanitize(entry["tool_error"]), 2_000))
    |> Map.put(
      :output_truncated,
      entry["output_truncated"] == true or persisted_output_truncated?(entry["output"])
    )
  end

  defp put_full_fields(base, entry, _kind) do
    Map.put(base, :content, bound_value(sanitize(entry["content"]), 4_000))
  end

  defp maybe_put_exact_duration(base, entry, fidelity)
       when fidelity in ["exact", "not_started"] do
    Map.put(base, :duration_ms, entry["tool_duration_ms"])
  end

  defp maybe_put_exact_duration(base, _entry, _fidelity), do: base

  defp completed_at(_entry, "running"), do: nil
  defp completed_at(entry, _status), do: entry["completed_at"] || entry["updated_at"]

  defp record_kind(entry) do
    cond do
      entry["role"] == "tool" or entry["content_type"] == "tool" -> "tool"
      entry["role"] == "user" -> "user"
      entry["role"] == "assistant" -> "assistant"
      true -> "system"
    end
  end

  defp record_status(entry, "tool"), do: normalize_status(entry["tool_status"] || entry["status"])
  defp record_status(entry, _kind), do: normalize_status(entry["status"] || "complete")

  defp normalize_status(status) when status in ["done", "completed", "complete", "succeeded"],
    do: "complete"

  defp normalize_status(status) when status in ["failed", "error"], do: "error"
  defp normalize_status(status) when status in ["streaming", "running"], do: "running"
  defp normalize_status(status) when is_binary(status), do: status
  defp normalize_status(_status), do: "unknown"

  defp record_event("tool", "running"), do: "tool_started"
  defp record_event("tool", "error"), do: "tool_failed"
  defp record_event("tool", "cancelled"), do: "tool_cancelled"
  defp record_event("tool", _status), do: "tool_completed"
  defp record_event("user", _status), do: "message_received"
  defp record_event("assistant", "running"), do: "message_streaming"
  defp record_event("assistant", "error"), do: "message_failed"
  defp record_event("assistant", _status), do: "message_completed"
  defp record_event("system", "error"), do: "notice_failed"
  defp record_event("system", _status), do: "notice_recorded"

  defp record_summary(entry, "tool") do
    input = entry["input"]

    value =
      cond do
        is_map(input) and is_binary(input["command"]) -> input["command"]
        is_map(input) and is_binary(input["file_path"]) -> input["file_path"]
        is_binary(entry["tool_name"]) -> entry["tool_name"]
        true -> "tool"
      end

    value |> sanitize() |> to_summary()
  end

  defp record_summary(entry, _kind), do: entry["content"] |> sanitize() |> to_summary()

  defp to_summary(value) when is_binary(value), do: bound_text(value, 500)
  defp to_summary(nil), do: ""
  defp to_summary(value), do: value |> Handbean.JSON.encode!() |> bound_text(500)

  defp sanitize(nil), do: nil

  defp sanitize(value) do
    value
    |> Handbean.Log.Redactor.redact()
    |> Handbean.JsonSafe.normalize()
  end

  defp bound_value(value, max) when is_binary(value), do: bound_text(value, max)

  defp bound_value(value, max) when is_map(value) or is_list(value) do
    encoded = Handbean.JSON.encode!(value)

    if String.length(encoded) <= max do
      value
    else
      %{"preview" => bound_text(encoded, max), "truncated" => true}
    end
  end

  defp bound_value(value, _max), do: value

  defp bound_text(value, max) when is_binary(value) do
    if String.length(value) <= max do
      value
    else
      String.slice(value, 0, max - 40) <> "\n[truncated #{String.length(value)} chars]"
    end
  end

  defp bound_text(value, _max), do: value

  defp persisted_output_truncated?(output) when is_binary(output),
    do: String.contains?(output, "[truncated]")

  defp persisted_output_truncated?(_output), do: false

  defp drop_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp optional_text(input, key, max) do
    case Map.get(input, key) do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      _value -> Threads.text(input, key, nil, max)
    end
  end

  defp optional_integer(input, key, min, max) do
    case Map.fetch(input, key) do
      :error -> {:ok, nil}
      {:ok, value} when is_integer(value) and value >= min and value <= max -> {:ok, value}
      _ -> {:error, :invalid_input}
    end
  end

  defp detail_level(input) do
    value = Map.get(input, "detail_level", "compact")
    if value in @detail_levels, do: {:ok, value}, else: {:error, :invalid_input}
  end

  defp kinds(input) do
    value = Map.get(input, "kinds", [])

    if is_list(value) and length(value) <= length(@record_kinds) and
         Enum.all?(value, &(&1 in @record_kinds)) do
      {:ok, Enum.uniq(value)}
    else
      {:error, :invalid_input}
    end
  end

  defp binding(context, input) do
    :crypto.hash(
      :sha256,
      :erlang.term_to_binary({
        "trajectory",
        context.conversation_id,
        context.workspace_id,
        Map.delete(input, "cursor")
      })
    )
    |> Base.url_encode64(padding: false)
  end

  defp cursor_position(cursor, _binding) when cursor in [nil, ""],
    do: {:ok, %{snapshot_version: nil, after_sequence: 0}}

  defp cursor_position(cursor, binding) when is_binary(cursor) and byte_size(cursor) <= 4096 do
    case Handbean.EndpointAdapter.verify(@cursor_salt, cursor, max_age: 3600) do
      {:ok, {^binding, snapshot_version, after_sequence}}
      when is_integer(after_sequence) and after_sequence >= 0 ->
        {:ok, %{snapshot_version: snapshot_version, after_sequence: after_sequence}}

      _ ->
        {:error, :stale_or_invalid_cursor}
    end
  end

  defp cursor_position(_cursor, _binding), do: {:error, :stale_or_invalid_cursor}

  defp snapshot_id(thread_id, version) do
    :crypto.hash(:sha256, :erlang.term_to_binary({thread_id, version}))
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 22)
  end

  defp encoded_size(value), do: value |> Handbean.JSON.encode!() |> String.length()
end
