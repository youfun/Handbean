defmodule HandbeanProbe.Bridge.Payload do
  @moduledoc """
  Key normalisation for data that crosses from `sigil` into the native UI
  with two possible key types: live `Handbean.PubSub.Session` event payloads and
  in-memory tool results carry atom keys, while the same data restored from
  `Handbean.SessionStore` / the persisted transcript carries JSON string
  keys.

  `string_keys/1` maps everything to the persisted (string-keyed) shape once,
  so readers use one key and never fall back between an atom and a string
  key. Values are untouched (atoms stay atoms); structs pass through
  unchanged. `attachment/1` is the canonical attachment map shared by the
  composer draft and the timeline.
  """

  alias Handbean.Attachments

  @spec string_keys(term()) :: term()
  def string_keys(%_{} = struct), do: struct

  def string_keys(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {string_key(k), string_keys(v)} end)

  def string_keys(list) when is_list(list), do: Enum.map(list, &string_keys/1)
  def string_keys(other), do: other

  @doc """
  Canonical string-keyed attachment. `Handbean.Attachments.Imported` is
  persisted first; the display keys `id` / `filename` / `mime_type` are
  filled from the persisted `attachment_id` / `display_name` /
  `canonical_type` so every reader uses the display key only.
  """
  @spec attachment(map() | Attachments.Imported.t()) :: map()
  def attachment(%Attachments.Imported{} = imported) do
    imported
    |> Attachments.persistable()
    |> Map.put("controlled_path", imported.controlled_path)
    |> Map.put("canonical_type", imported.canonical_type)
    |> Map.put("display_name", imported.display_name)
    |> Map.put("attachment_id", imported.attachment_id)
    |> attachment()
  end

  def attachment(map) when is_map(map) do
    att = string_keys(map)

    att
    |> Map.put("id", first(att, ["id", "attachment_id"]))
    |> Map.put("filename", first(att, ["filename", "display_name"]))
    |> Map.put("mime_type", first(att, ["mime_type", "canonical_type"]))
  end

  def attachment(_), do: %{}

  @doc "First non-nil value among `keys` (a documented semantic fallback, not a key-type one)."
  @spec first(map(), [String.t()]) :: term()
  def first(map, keys) when is_map(map), do: Enum.find_value(keys, &Map.get(map, &1))
  def first(_, _), do: nil

  defp string_key(key) when is_atom(key), do: Atom.to_string(key)
  defp string_key(key), do: key
end
