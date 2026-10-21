defmodule Handbean.Agent.StreamBatch do
  @moduledoc false

  @default_max_bytes 16_384
  @default_max_wait_ms 50

  defstruct chunks: [],
            bytes: 0,
            signature: nil,
            payload: nil,
            max_bytes: @default_max_bytes,
            max_wait_ms: @default_max_wait_ms,
            timer: nil

  @type t :: %__MODULE__{}

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      max_bytes:
        positive_integer(
          opts[:stream_flush_bytes],
          configured_default(:bytes, @default_max_bytes)
        ),
      max_wait_ms:
        positive_integer(opts[:stream_flush_ms], configured_default(:ms, @default_max_wait_ms))
    }
  end

  # Deployment-level defaults from config/runtime.exs
  # (HANDBEAN_STREAM_FLUSH_MS / HANDBEAN_STREAM_FLUSH_BYTES). Per-run opts
  # still win; non-positive config values fall back to the built-in defaults.
  defp configured_default(key, fallback) do
    case Application.get_env(:handbean, :stream_flush, []) do
      config when is_list(config) ->
        case Keyword.get(config, key) do
          value when is_integer(value) and value > 0 -> value
          _ -> fallback
        end

      _ ->
        fallback
    end
  end

  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{bytes: bytes}), do: bytes == 0

  @spec append(t(), map()) :: {:ok, t()} | {:boundary, t()}
  def append(%__MODULE__{} = batch, payload) when is_map(payload) do
    chunk = value(payload, :chunk)
    signature = signature(payload)

    cond do
      not is_binary(chunk) or chunk == "" ->
        {:ok, batch}

      not empty?(batch) and batch.signature != signature ->
        {:boundary, batch}

      true ->
        {:ok,
         %{
           batch
           | chunks: [chunk | batch.chunks],
             bytes: batch.bytes + byte_size(chunk),
             signature: signature,
             payload: batch.payload || payload
         }}
    end
  end

  @spec full?(t()) :: boolean()
  def full?(%__MODULE__{} = batch), do: batch.bytes >= batch.max_bytes

  @spec event(t()) :: {:message_delta, map()} | nil
  def event(%__MODULE__{} = batch) do
    case batch.chunks do
      [] ->
        nil

      chunks ->
        payload =
          batch.payload
          |> Map.delete("chunk")
          |> Map.put(:chunk, chunks |> Enum.reverse() |> IO.iodata_to_binary())

        {:message_delta, payload}
    end
  end

  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = batch) do
    %{batch | chunks: [], bytes: 0, signature: nil, payload: nil, timer: nil}
  end

  defp signature(payload), do: {value(payload, :phase), value(payload, :output_index)}

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default
end
