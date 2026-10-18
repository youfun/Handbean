defmodule Handbean.JsonSafe do
  @moduledoc """
  Converts runtime values into JSON-encodable data.

  Use at persistence/event boundaries where payloads may contain structs,
  tuples, atoms, DateTimes, or Ecto schemas returned by tools.
  """

  @doc "Convert a term into maps/lists/scalars accepted by Erlang/OTP's JSON encoder."
  @spec normalize(term()) :: term()
  def normalize(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def normalize(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  def normalize(%Date{} = value), do: Date.to_iso8601(value)
  def normalize(%Time{} = value), do: Time.to_iso8601(value)

  def normalize(value) when is_map(value) do
    if Map.has_key?(value, :__struct__) do
      normalize_struct(value)
    else
      Map.new(value, fn {key, val} -> {normalize_key(key), normalize(val)} end)
    end
  end

  def normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)

  def normalize(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&normalize/1)
  end

  def normalize(nil), do: :null
  def normalize(:null), do: :null
  def normalize(value) when is_boolean(value), do: value
  def normalize(value) when is_atom(value), do: Atom.to_string(value)
  def normalize(value) when is_binary(value), do: String.replace_invalid(value, "�")
  def normalize(value) when is_number(value), do: value

  def normalize(value), do: inspect(value)

  defp normalize_struct(%Handbean.Memory.Engram{} = engram) do
    %{
      "id" => engram.id,
      "content" => engram.content,
      "kind" => normalize(engram.kind),
      "short_term" => engram.short_term,
      "expires_at" => normalize(engram.expires_at),
      "reinforced_count" => engram.reinforced_count,
      "last_reinforced_at" => normalize(engram.last_reinforced_at),
      "metadata" => normalize(engram.metadata),
      "inserted_at" => normalize(engram.inserted_at),
      "updated_at" => normalize(engram.updated_at)
    }
  end

  defp normalize_struct(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> Map.drop([:__meta__])
    |> normalize()
  end

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key), do: to_string(key)
end
