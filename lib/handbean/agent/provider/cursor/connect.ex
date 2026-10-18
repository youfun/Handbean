defmodule Handbean.Agent.Provider.Cursor.Connect do
  @moduledoc """
  Connect protocol framing: 1-byte flags + 4-byte big-endian length + payload.

  Flag `0x02` marks the JSON end-stream envelope. Compression (`0x01`) is
  rejected rather than silently decoded.
  """

  import Bitwise

  @end_stream 0x02
  @compressed 0x01

  def encode(payload, opts \\ []) when is_binary(payload) do
    flags = if Keyword.get(opts, :end_stream, false), do: @end_stream, else: 0
    <<flags, byte_size(payload)::32-big, payload::binary>>
  end

  def decode_all(buffer) when is_binary(buffer) do
    decode_all(buffer, [])
  end

  defp decode_all(<<flags, length::32-big, payload::binary-size(length), rest::binary>>, acc) do
    case decode_frame(flags, payload) do
      {:ok, frame} -> decode_all(rest, [frame | acc])
      {:error, _} = error -> {error, rest}
    end
  end

  defp decode_all(rest, acc), do: {:ok, Enum.reverse(acc), rest}

  defp decode_frame(flags, _payload) when (flags &&& @compressed) == @compressed do
    {:error, :compressed_unsupported}
  end

  defp decode_frame(flags, payload) when (flags &&& @end_stream) == @end_stream do
    {:ok, {:end_stream, payload}}
  end

  defp decode_frame(_flags, payload), do: {:ok, {:message, payload}}

  def end_stream_error(payload) when is_binary(payload) do
    case Handbean.JSON.decode(payload) do
      {:ok, %{"error" => %{"message" => message}}} when is_binary(message) ->
        {:error, message}

      {:ok, %{"error" => %{"code" => code}}} ->
        {:error, "Cursor stream error: #{code}"}

      {:ok, %{"error" => error}} ->
        {:error, "Cursor stream error: #{inspect(error)}"}

      _ ->
        :ok
    end
  end
end
