defmodule Handbean.Log.Formatter do
  @moduledoc """
  Serialization and deserialization for `Handbean.Log.Event`.

  Provides `to_map/1`, `to_json/1`, and `from_map/1` for
  converting events to/from external representations.

  > **Redaction note:** Always apply `Handbean.Log.Redactor.redact/1` to
  > event metadata before calling `to_json/1` if the output may be
  > persisted or transmitted over the network.

  ## Future hook points

  When the structured log foundation is integrated into the agent pipeline,
  this formatter can be wired into:

    * `Handbean.Agent.Middleware.Logger` — log turn events as structured JSON
    * `Handbean.PubSub.AgentEvent` — serialize for audit persistence
    * Provider error redaction — ensure no API keys leak into logs
  """

  alias Handbean.Log.Event

  @doc """
  Converts an `%Event{}` struct to a plain string-keyed map.

  Kind and level atoms are stringified for external consumption.
  """
  @spec to_map(Event.t()) :: map()
  def to_map(%Event{} = event) do
    %{
      "id" => event.id,
      "kind" => Atom.to_string(event.kind),
      "level" => Atom.to_string(event.level),
      "message" => event.message,
      "timestamp" => event.timestamp,
      "session_id" => event.session_id,
      "turn" => event.turn,
      "source" => event.source,
      "metadata" => event.metadata
    }
  end

  @doc """
  Converts an `%Event{}` struct to a JSON string.

  Uses `Handbean.JSON.encode!/1` — the event is expected to be pre-redacted
  by the caller if secrets may be present in metadata.
  """
  @spec to_json(Event.t()) :: String.t()
  def to_json(%Event{} = event) do
    event
    |> to_map()
    |> Handbean.JSON.encode!()
  end

  @doc """
  Reconstructs an `%Event{}` struct from a map (string or atom keys).

  Kind and level strings are validated against `Event.valid_kinds/0`
  and `Event.valid_levels/0`.

  Returns `{:ok, %Event{}}` or `{:error, reason}`.
  """
  @spec from_map(map()) :: {:ok, Event.t()} | {:error, atom()}
  def from_map(map) when is_map(map) do
    id = get_key(map, :id, "id")
    kind_str = get_key(map, :kind, "kind")
    level_str = get_key(map, :level, "level")
    message = get_key(map, :message, "message")
    timestamp = get_key(map, :timestamp, "timestamp")

    with {:kind, k} when is_binary(k) <- {:kind, kind_str},
         {:ok, kind_atom} <- lookup_kind(k),
         {:level, l} when is_binary(l) <- {:level, level_str},
         {:ok, level_atom} <- lookup_level(l),
         {:msg, m} when is_binary(m) <- {:msg, message},
         {:ts, ts} when is_integer(ts) <- {:ts, timestamp} do
      event = %Event{
        id: id,
        kind: kind_atom,
        level: level_atom,
        message: m,
        timestamp: ts,
        session_id: get_key(map, :session_id, "session_id"),
        turn: get_key(map, :turn, "turn"),
        source: get_key(map, :source, "source"),
        metadata: get_key(map, :metadata, "metadata", %{})
      }

      {:ok, event}
    else
      {:kind, _} -> {:error, :invalid_kind}
      {:error, :invalid_kind} -> {:error, :invalid_kind}
      {:level, _} -> {:error, :invalid_level}
      {:error, :invalid_level} -> {:error, :invalid_level}
      {:msg, _} -> {:error, :invalid_event_map}
      {:ts, _} -> {:error, :invalid_event_map}
    end
  end

  # ── Kind/level lookup (validated against Event's sets) ──

  defp lookup_kind(kind_str) do
    kind_atom = String.to_existing_atom(kind_str)

    if MapSet.member?(Event.valid_kinds(), kind_atom),
      do: {:ok, kind_atom},
      else: {:error, :invalid_kind}
  rescue
    ArgumentError -> {:error, :invalid_kind}
  end

  defp lookup_level(level_str) do
    level_atom = String.to_existing_atom(level_str)

    if MapSet.member?(Event.valid_levels(), level_atom),
      do: {:ok, level_atom},
      else: {:error, :invalid_level}
  rescue
    ArgumentError -> {:error, :invalid_level}
  end

  # ── Private helpers ──

  defp get_key(map, atom_key, string_key, default \\ nil) do
    cond do
      Map.has_key?(map, atom_key) -> Map.get(map, atom_key)
      Map.has_key?(map, string_key) -> Map.get(map, string_key)
      true -> default
    end
  end
end
