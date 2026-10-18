defmodule HandbeanWeb.ChangeHelper do
  @moduledoc """
  Data transformation helpers for change and reversion logic,
  extracted from `HandbeanWeb.WorkspaceLive`.

  These functions operate on plain maps and lists without LiveView assigns.
  Recorded snapshot references are resolved when extracting a change.
  """

  alias Handbean.TranscriptEntry
  alias HandbeanWeb.FileChangeCard

  @doc """
  Normalizes a list of diff line maps to have string keys `"type"` and `"text"`.
  Returns `nil` for non-list inputs.
  """
  def normalize_diff_lines(lines) when is_list(lines) do
    Enum.map(lines, fn
      %{"type" => type, "text" => text} -> %{"type" => to_string(type), "text" => to_string(text)}
      %{type: type, text: text} -> %{"type" => to_string(type), "text" => to_string(text)}
      other -> %{"type" => "eq", "text" => to_string(other)}
    end)
  end

  def normalize_diff_lines(_), do: nil

  @doc """
  Converts all atom keys in a map to string keys, recursively.
  Returns `%{}` for non-map inputs.
  """
  def stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_nested(value)} end)
  end

  def stringify_keys(_), do: %{}

  @doc """
  Recursively stringifies keys in nested maps and lists.
  Leaf values pass through unchanged.
  """
  def stringify_nested(value) when is_map(value), do: stringify_keys(value)
  def stringify_nested(value) when is_list(value), do: Enum.map(value, &stringify_nested/1)
  def stringify_nested(value), do: value

  @doc """
  Adds `key` with `value` to `map` only if the key is not already present.
  Does nothing when `value` is `nil`.
  """
  def put_if_missing(map, _key, nil), do: map

  def put_if_missing(map, key, value),
    do: if(Map.get(map, key), do: map, else: Map.put(map, key, value))

  @doc """
  Reads a value from a map by string key, then the existing atom of the same name.

  A present `nil` stays `nil`. Returns `nil` for non-map inputs or non-binary keys.
  """
  def value(map, key) when is_map(map) and is_binary(key) do
    Handbean.Utils.SafeMap.get(map, key)
  end

  def value(_map, _key), do: nil

  @doc """
  Extracts a normalized change map from a timeline entry.

  Reads from `entry["change"]`, `entry["details"]["change"]`,
  and top-level `entry` fields, applying defaults for missing keys.
  """
  def change_from_entry(entry) do
    details = Handbean.Utils.SafeMap.get_any(entry, "details", :details) || %{}
    raw_change = value(entry, "change") || value(details, "change") || %{}
    ref = value(raw_change, "change_snapshot_ref") || value(details, "change_snapshot_ref")

    raw_change =
      case Handbean.ChangeSnapshot.load(ref) do
        {:ok, snapshot} ->
          metadata =
            raw_change |> stringify_keys() |> Map.reject(fn {_key, value} -> is_nil(value) end)

          Map.merge(snapshot, metadata)

        {:error, _reason} ->
          raw_change
      end

    raw_change
    |> stringify_keys()
    |> put_if_missing("change_id", value(entry, "change_id") || value(details, "change_id"))
    |> put_if_missing("change_type", TranscriptEntry.tool_name(entry))
    |> put_if_missing("file_path", value(entry, "file_path") || value(details, "file_path"))
    |> put_if_missing("diff_lines", value(entry, "diff_lines") || value(details, "diff_lines"))
    |> Map.update("diff_lines", nil, &normalize_diff_lines/1)
    |> put_if_missing("reversible", value(entry, "reversible") || value(details, "reversible"))
    |> put_if_missing(
      "revert_status",
      value(entry, "revert_status") || value(details, "revert_status") || "unavailable"
    )
  end

  @doc """
  Builds a change map from tool execution details, overriding or extending
  with explicit `file_path`, `diff_lines`, and `tool_name` arguments.
  """
  def change_from_details(details, file_path, diff_lines, tool_name) do
    details
    |> change_from_entry()
    |> put_if_missing("change_type", tool_name)
    |> put_if_missing("file_path", file_path)
    |> put_if_missing("diff_lines", diff_lines)
    |> Map.update("diff_lines", nil, &normalize_diff_lines/1)
  end

  @doc """
  Finds a change by `change_id` in a timeline list.

  A Changes-panel id belongs to the session net row for that path, not to
  an intermediate edit or write. Timeline call ids still resolve to that
  call. Returns the change map or `nil`.
  """
  def find_change(timeline, change_id) when is_binary(change_id) and is_list(timeline) do
    find_net_change(timeline, change_id) || find_timeline_change(timeline, change_id)
  end

  def find_change(_timeline, _change_id), do: nil

  defp find_net_change(timeline, change_id) do
    timeline
    |> FileChangeCard.changes()
    |> Enum.find_value(fn entry ->
      change = change_from_entry(entry)

      if Map.get(change, "change_id") == change_id do
        change
      end
    end)
  end

  defp find_timeline_change(timeline, change_id) do
    Enum.find_value(timeline, fn entry ->
      change = change_from_entry(entry)

      if Map.get(change, "change_id") == change_id do
        change
      end
    end)
  end
end
