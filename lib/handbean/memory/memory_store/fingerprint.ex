defmodule Handbean.Memory.MemoryStore.Fingerprint do
  @moduledoc false

  @spec hash(term()) :: String.t()
  def hash(term) do
    term
    |> normalize()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp normalize(value) when value in [nil, true, false], do: value
  defp normalize(value) when is_atom(value), do: Atom.to_string(value)

  defp normalize(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} ->
      {normalize_key(key), normalize(nested_value)}
    end)
  end

  defp normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)

  defp normalize(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&normalize/1)
    |> List.to_tuple()
  end

  defp normalize(value), do: value

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: key
end
