defmodule Handbean.SessionStore do
  @moduledoc """
  Behaviour for runtime session snapshot persistence.

  Stores only recoverable runtime data. It must not store process ids, task refs,
  queue pids, ports, or provider connections.
  """

  @callback save(String.t(), map(), keyword()) :: :ok | {:error, term()}
  @callback load(String.t(), keyword()) :: {:ok, map()} | {:error, :not_found | term()}
  @callback delete(String.t(), keyword()) :: :ok | {:error, term()}
  @callback list_active(keyword()) :: {:ok, [String.t()]} | {:error, term()}
  @callback update(String.t(), map(), keyword()) :: :ok | {:error, term()}

  alias Handbean.Log.Redactor

  @recovery_projection_key "__session_recovery_projection__"
  @tool_output_ref_key "__session_tool_output_ref__"

  @runtime_keys [
    :pid,
    :agent_pid,
    :queue_pid,
    :task,
    :task_ref,
    :port,
    "pid",
    "agent_pid",
    "queue_pid",
    "task",
    "task_ref",
    "port"
  ]

  @doc false
  def prepare_snapshot(snapshot) do
    snapshot
    |> strip_runtime_handles()
    |> Redactor.redact()
  end

  @doc false
  def prepare_recovery_projection(snapshot) when is_map(snapshot) do
    case fetch(snapshot, "control_events") do
      {:ok, control_events} when is_list(control_events) ->
        projection =
          snapshot
          |> Map.drop([:events, "events", :control_events, "control_events"])
          |> Map.put(@recovery_projection_key, true)

        {
          prepare_snapshot(projection),
          control_events
          |> Enum.map(&project_control_event/1)
          |> prepare_snapshot()
        }

      _ ->
        {prepare_snapshot(snapshot), []}
    end
  end

  @doc false
  def tool_output_references(snapshot) when is_map(snapshot) do
    Enum.reduce(events(snapshot), MapSet.new(), fn event, references ->
      payload = value(event, "payload")

      if is_map(payload) and payload[@tool_output_ref_key] == "transcript" do
        MapSet.put(references, {value(payload, "run_id"), value(payload, "tool_use_id")})
      else
        references
      end
    end)
  end

  @doc false
  def restore_tool_outputs(snapshot, transcript_entries)
      when is_map(snapshot) and is_list(transcript_entries) do
    referenced_outputs = tool_output_references(snapshot)

    outputs =
      Enum.reduce(transcript_entries, %{}, fn entry, outputs ->
        key = {entry["run_id"], entry["tool_use_id"]}

        with true <- entry["content_type"] == "tool",
             true <- is_binary(entry["tool_use_id"]),
             true <- MapSet.member?(referenced_outputs, key),
             false <- Map.has_key?(outputs, key),
             {:ok, output} <- Map.fetch(entry, "output") do
          Map.put(outputs, key, Redactor.redact(output))
        else
          _ -> outputs
        end
      end)

    snapshot
    |> restore_event_list("events", outputs)
    |> restore_event_list("control_events", outputs)
  end

  defp project_control_event(event) when is_map(event) do
    if value(event, "kind") in [:tool_end, "tool_end"] do
      update_payload(event, fn payload ->
        if Map.has_key?(payload, :output) or Map.has_key?(payload, "output") do
          payload
          |> Map.drop([:output, "output"])
          |> Map.put(@tool_output_ref_key, "transcript")
        else
          payload
        end
      end)
    else
      event
    end
  end

  defp project_control_event(event), do: event

  defp events(snapshot) do
    [value(snapshot, "events"), value(snapshot, "control_events")]
    |> Enum.filter(&is_list/1)
    |> List.flatten()
  end

  defp restore_event_list(snapshot, key, outputs) do
    case fetch(snapshot, key) do
      {:ok, events} when is_list(events) ->
        Map.put(snapshot, key, Enum.map(events, &restore_tool_output(&1, outputs)))

      _ ->
        snapshot
    end
  end

  defp restore_tool_output(event, outputs) when is_map(event) do
    payload = value(event, "payload")

    if is_map(payload) and payload[@tool_output_ref_key] == "transcript" do
      key = {value(payload, "run_id"), value(payload, "tool_use_id")}

      case Map.fetch(outputs, key) do
        {:ok, output} ->
          restored =
            payload
            |> Map.delete(@tool_output_ref_key)
            |> Map.put("output", output)

          put_payload(event, restored)

        _ ->
          event
      end
    else
      event
    end
  end

  defp restore_tool_output(event, _outputs), do: event

  defp update_payload(event, project) do
    cond do
      is_map(event[:payload]) -> Map.update!(event, :payload, project)
      is_map(event["payload"]) -> Map.update!(event, "payload", project)
      true -> event
    end
  end

  defp put_payload(event, payload) do
    if Map.has_key?(event, :payload),
      do: Map.put(event, :payload, payload),
      else: Map.put(event, "payload", payload)
  end

  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, _value} = found -> found
      :error -> Map.fetch(map, String.to_existing_atom(key))
    end
  end

  defp value(map, key) do
    case fetch(map, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp strip_runtime_handles(map) when is_map(map) do
    map
    |> Map.drop(@runtime_keys)
    |> Map.new(fn {key, value} -> {key, strip_runtime_handles(value)} end)
  end

  defp strip_runtime_handles(list) when is_list(list),
    do: Enum.map(list, &strip_runtime_handles/1)

  defp strip_runtime_handles(value) when is_pid(value), do: nil
  defp strip_runtime_handles(value) when is_reference(value), do: nil
  defp strip_runtime_handles(value) when is_function(value), do: nil
  defp strip_runtime_handles(value), do: value
end
