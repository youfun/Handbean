defmodule Handbean.Utils.SafeMap do
  @moduledoc """
  Map access that accepts either a string key or its existing atom, without
  creating atoms and without treating `nil` or `false` as a missing key.

  The first key that is present wins, even when its value is `nil` or `false`.
  """

  @doc """
  Reads `key`, then the existing atom of the same name.

  Returns `default` only when neither key is present. A present `nil` or
  `false` is returned as-is.
  """
  @spec get(map(), String.t(), term()) :: term()
  def get(map, key, default \\ nil)

  def get(map, key, default) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> fetch_existing_atom(map, key, default)
    end
  end

  def get(_map, _key, default), do: default

  @doc """
  Returns the value of the first present key in `keys`.

  `default` is not taken here; use `get_any/4` when a missing pair needs one.
  """
  @spec get_any(map(), [atom() | String.t()]) :: term()
  def get_any(map, keys) when is_list(keys), do: present(map, keys, nil)

  @doc """
  Returns the value of `first_key` when it is present, otherwise `second_key`.
  """
  @spec get_any(map(), atom() | String.t(), atom() | String.t()) :: term()
  def get_any(map, first_key, second_key) when is_map(map) and not is_list(first_key) do
    present(map, [first_key, second_key], nil)
  end

  def get_any(_map, first_key, _second_key) when not is_list(first_key), do: nil

  @doc """
  Same as `get_any/3`, with `default` when both keys are absent.
  """
  @spec get_any(map(), atom() | String.t(), atom() | String.t(), term()) :: term()
  def get_any(map, first_key, second_key, default)
      when is_map(map) and not is_list(first_key) do
    present(map, [first_key, second_key], default)
  end

  def get_any(_map, first_key, _second_key, default) when not is_list(first_key), do: default

  defp present(map, keys, default) when is_map(map) do
    Enum.reduce_while(keys, default, fn key, acc ->
      case Map.fetch(map, key) do
        {:ok, value} -> {:halt, value}
        :error -> {:cont, acc}
      end
    end)
  end

  defp present(_map, _keys, default), do: default

  defp fetch_existing_atom(map, key, default) do
    case Map.fetch(map, String.to_existing_atom(key)) do
      {:ok, value} -> value
      :error -> default
    end
  rescue
    ArgumentError -> default
  end
end
