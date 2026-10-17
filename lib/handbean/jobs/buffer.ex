defmodule Handbean.Jobs.Buffer do
  @moduledoc "Bounded byte-offset output window. UTF-8 decoding never changes cursor offsets."
  @limit 50_000
  defstruct bytes: "", offset: 0, total: 0

  def append(buffer, data) do
    bytes = buffer.bytes <> data
    drop = max(byte_size(bytes) - @limit, 0)

    %__MODULE__{
      bytes: binary_part(bytes, drop, byte_size(bytes) - drop),
      offset: buffer.offset + drop,
      total: buffer.total + byte_size(data)
    }
  end

  def read(buffer, cursor, final? \\ true) do
    start = min(max(cursor, buffer.offset), buffer.total)
    bytes = binary_part(buffer.bytes, start - buffer.offset, buffer.total - start)
    {output, pending} = decode(bytes, final?, [])

    %{
      output: output,
      cursor: buffer.total - pending,
      truncated: cursor < buffer.offset,
      available_from: buffer.offset,
      encoding: "utf-8 (invalid bytes replaced)"
    }
  end

  defp decode(bytes, final?, chunks) do
    case :unicode.characters_to_binary(bytes, :utf8, :utf8) do
      valid when is_binary(valid) ->
        {IO.iodata_to_binary(Enum.reverse([valid | chunks])), 0}

      {:incomplete, valid, rest} when not final? ->
        {IO.iodata_to_binary(Enum.reverse([valid | chunks])), byte_size(rest)}

      {kind, valid, <<_byte, rest::binary>>} when kind in [:error, :incomplete] ->
        decode(rest, final?, ["�", valid | chunks])
    end
  end
end
