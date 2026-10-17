defmodule Handbean.Memory.Observation do
  @moduledoc """
  An observation entry — a structured record of what happened during an agent run.

  Observations are lightweight and zero-LLM-cost: they capture tool executions,
  turn completions, and context snapshots via middleware hooks. They serve as
  the raw material for future LLM-driven Observer/Reflector pipelines (P1/P2).
  """

  @type priority :: :high | :medium | :low
  @type source :: :tool_execution | :completion | :session_start | :observer | :reflector

  @type t :: %__MODULE__{
          id: String.t(),
          timestamp: DateTime.t(),
          priority: priority(),
          source: source(),
          content: String.t(),
          metadata: map()
        }

  defstruct [
    :id,
    :timestamp,
    :priority,
    :source,
    :content,
    metadata: %{}
  ]

  @doc """
  Create a new observation.

  ## Options
    - `:priority` — `:high`, `:medium` (default), or `:low`
    - `:source` — source hook (e.g. `:tool_execution`, `:completion`)
    - `:metadata` — arbitrary extra data (tool_name, turn, tokens, file_path, etc.)
    - `:timestamp` — DateTime (default: now)
    - `:id` — unique id (default: auto-generated)
  """
  @spec new(String.t(), keyword()) :: t()
  def new(content, opts \\ []) when is_binary(content) and is_list(opts) do
    %__MODULE__{
      id: Keyword.get(opts, :id, generate_id()),
      timestamp: Keyword.get(opts, :timestamp, DateTime.utc_now()),
      priority: Keyword.get(opts, :priority, :medium),
      source: Keyword.get(opts, :source),
      content: String.trim(content),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc """
  Convert an observation to a JSON-serializable map.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = obs) do
    %{
      "id" => obs.id,
      "timestamp" => DateTime.to_iso8601(obs.timestamp),
      "priority" => to_string(obs.priority),
      "source" => obs.source && to_string(obs.source),
      "content" => obs.content,
      "metadata" => obs.metadata
    }
  end

  @doc """
  Create an observation from a deserialized map.
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      id: map["id"] || generate_id(),
      timestamp: parse_timestamp(map["timestamp"]),
      priority: parse_priority(map["priority"]),
      source: parse_source(map["source"]),
      content: map["content"] || "",
      metadata: map["metadata"] || %{}
    }
  end

  @doc """
  Format an observation as a human-readable single line for context injection.

  Uses priority icons: 🔴 high, 🟡 medium, 🟢 low
  """
  @spec to_context_line(t()) :: String.t()
  def to_context_line(%__MODULE__{} = obs) do
    icon = priority_icon(obs.priority)
    time = format_time(obs.timestamp)
    "[#{icon} #{time}] #{obs.content}"
  end

  # ── Helpers ──

  defp generate_id do
    "obs_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp priority_icon(:high), do: "重要"
  defp priority_icon(:medium), do: "一般"
  defp priority_icon(:low), do: "备注"

  defp format_time(%DateTime{} = dt) do
    dt
    |> DateTime.to_time()
    |> Time.truncate(:second)
    |> Time.to_iso8601()
  end

  defp parse_timestamp(nil), do: DateTime.utc_now()

  defp parse_timestamp(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _} -> dt
      {:error, _} -> DateTime.utc_now()
    end
  end

  defp parse_timestamp(%DateTime{} = dt), do: dt
  defp parse_timestamp(_), do: DateTime.utc_now()

  defp parse_priority("high"), do: :high
  defp parse_priority("medium"), do: :medium
  defp parse_priority("low"), do: :low
  defp parse_priority(atom) when atom in [:high, :medium, :low], do: atom
  defp parse_priority(_), do: :medium

  defp parse_source(nil), do: nil
  defp parse_source("tool_execution"), do: :tool_execution
  defp parse_source("completion"), do: :completion
  defp parse_source("session_start"), do: :session_start
  defp parse_source("observer"), do: :observer
  defp parse_source("reflector"), do: :reflector
  defp parse_source(atom) when is_atom(atom), do: atom
  defp parse_source(_), do: nil
end
