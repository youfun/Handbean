defmodule Handbean.TranscriptEntry do
  @moduledoc """
  Compatibility read side for tool transcript entries.

  New entries use the `tool_*` names that distinguish tool fields from an
  assistant entry's `status` / `error`. The bare names (`tool`, `status`,
  `duration_ms`, `error`) remain readable for durable legacy records. Readers
  must not spell that fallback themselves.

  Durable transcript projections normally have string keys, while transient
  LiveView projections and tests can have atom keys. Nothing here writes.
  """

  @type entry :: map()

  @doc "Tool name (`tool_name`, falling back to the legacy `tool`)."
  @spec tool_name(entry()) :: String.t() | nil
  def tool_name(entry), do: canonical_or_legacy(entry, ["tool_name", :tool_name], ["tool", :tool])

  @doc "Tool status (`tool_status`, falling back to the legacy `status`), as written."
  @spec tool_status(entry()) :: String.t() | atom() | nil
  def tool_status(entry),
    do: canonical_or_legacy(entry, ["tool_status", :tool_status], ["status", :status])

  @doc "Tool duration (`tool_duration_ms`, falling back to the legacy `duration_ms`)."
  @spec duration_ms(entry()) :: integer() | nil
  def duration_ms(entry),
    do:
      canonical_or_legacy(
        entry,
        ["tool_duration_ms", :tool_duration_ms],
        ["duration_ms", :duration_ms]
      )

  @doc "Tool error (`tool_error`, falling back to the legacy `error`)."
  @spec error(entry()) :: term()
  def error(entry),
    do: canonical_or_legacy(entry, ["tool_error", :tool_error], ["error", :error])

  @doc "Tool input map (`input`; projections may also carry `tool_input`)."
  @spec input(entry()) :: map()
  def input(entry) do
    case first(entry, ["input", "tool_input", :input, :tool_input]) do
      input when is_map(input) -> input
      _ -> %{}
    end
  end

  @doc "Projection input summary (`tool_input_summary`, falling back to `input_summary`)."
  @spec input_summary(entry()) :: String.t() | nil
  def input_summary(entry),
    do:
      first(entry, [
        "tool_input_summary",
        "input_summary",
        :tool_input_summary,
        :input_summary
      ])

  defp first(entry, keys) when is_map(entry) do
    Enum.find_value(keys, fn key ->
      case Map.get(entry, key) do
        nil -> nil
        value -> value
      end
    end)
  end

  defp first(_entry, _keys), do: nil

  # Presence, rather than truthiness, selects the canonical field. In
  # particular, a canonical nil tool_error means the legacy error was cleared.
  defp canonical_or_legacy(entry, canonical_keys, legacy_keys) when is_map(entry) do
    case Enum.find(canonical_keys, &Map.has_key?(entry, &1)) do
      nil -> first(entry, legacy_keys)
      key -> Map.get(entry, key)
    end
  end

  defp canonical_or_legacy(_entry, _canonical_keys, _legacy_keys), do: nil
end
