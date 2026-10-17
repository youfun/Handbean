defmodule Handbean.JSON do
  @moduledoc """
  JSON adapter backed by Erlang/OTP's `:json` module.

  The public functions provide the interface required by Handbean and Phoenix
  while preserving Elixir conventions such as decoding JSON null to `nil`
  and returning binaries from `encode/2`.
  """

  @type option :: {:pretty, boolean()}

  @spec encode(term(), [option()]) :: {:ok, binary()} | {:error, Exception.t()}
  def encode(term, opts \\ []) do
    {:ok, encode!(term, opts)}
  rescue
    exception -> {:error, exception}
  end

  @spec encode!(term(), [option()]) :: binary()
  def encode!(term, opts \\ []) do
    term
    |> encode_iodata(opts)
    |> IO.iodata_to_binary()
  end

  @spec encode_to_iodata!(term()) :: iodata()
  def encode_to_iodata!(term), do: encode_iodata(term, [])

  @spec decode(binary()) :: {:ok, term()} | {:error, Exception.t()}
  def decode(binary) when is_binary(binary) do
    {:ok, decode!(binary)}
  rescue
    exception -> {:error, exception}
  end

  @spec decode!(binary()) :: term()
  def decode!(binary) when is_binary(binary) do
    binary
    |> :json.decode()
    |> restore_elixir_values()
  end

  defp encode_iodata(term, opts) do
    normalized = Handbean.JsonSafe.normalize(term)

    if Keyword.get(opts, :pretty, false) do
      :json.format(normalized)
    else
      :json.encode(normalized)
    end
  end

  defp restore_elixir_values(:null), do: nil

  defp restore_elixir_values(value) when is_list(value),
    do: Enum.map(value, &restore_elixir_values/1)

  defp restore_elixir_values(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {key, restore_elixir_values(nested)} end)
  end

  defp restore_elixir_values(value), do: value
end
