defmodule Handbean.ArtifactDelivery.Input do
  @moduledoc false

  @blocked ~w(action component package flags extras intent class mimeType type)

  @spec take(map(), [String.t()]) :: {:ok, map()} | {:error, atom()}
  def take(input, allowed) when is_map(input) and is_list(allowed) do
    keys = stringify(input)
    blocked = Enum.filter(Map.keys(keys), &(&1 in @blocked))
    extras = Map.keys(keys) -- allowed

    cond do
      blocked != [] -> {:error, :raw_intent_rejected}
      extras != [] -> {:error, :unexpected_fields}
      true -> {:ok, keys}
    end
  end

  def take(_, _), do: {:error, :invalid_input}

  def field(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, atom_key(key))
  end

  defp stringify(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} when is_binary(key) -> {key, value}
    end)
  end

  defp atom_key(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
