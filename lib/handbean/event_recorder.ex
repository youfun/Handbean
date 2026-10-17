defmodule Handbean.EventRecorder do
  @moduledoc """
  JSONL recorder for important agent/session events.

  Security:
    - `event_dir` is validated against `~/.handbean/events` via
      `Handbean.Security.PathValidator.validate_under_root/2` to prevent path
      traversal.
    - Directories are created with mode `0700`.
  """

  alias Handbean.Log.Redactor
  alias Handbean.PubSub.AgentEvent
  alias Handbean.Security.PathValidator

  @recorded_kinds [:run_start, :tool_start, :tool_end, :run_end, :error]
  @dir_mode 0o700

  def record(session_id, event, opts \\ [])

  def record(session_id, %AgentEvent{} = event, opts) do
    if event.kind in @recorded_kinds do
      write_event(session_id, event, opts)
    else
      :ok
    end
  end

  def record(_session_id, _event, _opts), do: :ok

  def event_path(session_id, opts \\ []) do
    event_dir(opts)
    |> Path.join("#{safe_session_id(session_id)}.jsonl")
  end

  defp write_event(session_id, event, opts) do
    path = event_path(session_id, opts)
    dir = Path.dirname(path)
    :ok = PathValidator.validate_under_root(dir, event_dir(opts))
    :ok = File.mkdir_p!(dir)
    :ok = File.chmod!(dir, @dir_mode)

    line =
      event
      |> Map.from_struct()
      |> bound_recorded_event()
      |> Redactor.redact()
      |> Handbean.JsonSafe.normalize()
      |> Handbean.JSON.encode!()

    :ok = File.write!(path, line <> "\n", [:append])
    :ok
  end

  defp event_dir(opts) do
    if dir = Keyword.get(opts, :event_dir) do
      dir
    else
      default_event_dir()
    end
  end

  defp default_event_dir, do: Handbean.Home.expand("~/.handbean/events")

  defp bound_recorded_event(%{payload: payload} = event) when is_map(payload) do
    alias Handbean.Agent.Tool.ResultContract

    payload =
      payload
      |> Map.update(:details, nil, &ResultContract.project_details/1)
      |> Map.update("details", nil, &ResultContract.project_details/1)
      |> bound_recorded_text(:output)
      |> bound_recorded_text(:error)
      |> bound_recorded_text("output")
      |> bound_recorded_text("error")

    %{event | payload: payload}
  end

  defp bound_recorded_event(event), do: event

  defp bound_recorded_text(payload, key) do
    case Map.get(payload, key) do
      text when is_binary(text) and byte_size(text) > 16_000 ->
        Map.put(payload, key, String.slice(text, 0, 15_900) <> "\n[truncated]")

      _ ->
        payload
    end
  end

  defp safe_session_id(session_id) do
    session_id
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_.-]/, "_")
  end
end
