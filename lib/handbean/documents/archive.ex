defmodule Handbean.Documents.Archive do
  @moduledoc false

  import Bitwise

  @max_entries 2_000
  @max_member 8 * 1024 * 1024
  @max_expanded 16 * 1024 * 1024

  # Only the OOXML ZIP subset is accepted. Nothing is ever written to disk.
  # Central-directory sizes are preflight checks, never an inflation budget.
  def open(bytes) do
    with {:ok, count, start, size} <- directory(bytes),
         true <- count <= @max_entries,
         {:ok, entries, ranges, expanded} <- entries(bytes, start, size, count, %{}, [], 0),
         true <- expanded <= @max_expanded,
         true <- Enum.all?(ranges, fn {_offset, ending} -> ending <= start end),
         true <- disjoint?(Enum.sort(ranges)) do
      {:ok, %{bytes: bytes, entries: entries}}
    else
      _ -> {:error, "Invalid, encrypted or oversized Office ZIP archive"}
    end
  end

  def fetch(%{bytes: bytes, entries: entries}, name) do
    case Map.fetch(entries, name) do
      {:ok, entry} ->
        compressed = binary_part(bytes, entry.offset, entry.compressed)

        with {:ok, data} <- decode(compressed, entry.method, entry.size),
             true <- byte_size(data) == entry.size and :erlang.crc32(data) == entry.crc do
          {:ok, data}
        else
          _ -> {:error, "Invalid or oversized Office ZIP member"}
        end

      :error ->
        {:error, "Missing Office package part: #{name}"}
    end
  end

  def has?(archive, name), do: Map.has_key?(archive.entries, name)

  defp directory(bytes) when byte_size(bytes) >= 22 do
    tail_start = max(0, byte_size(bytes) - 65_557)
    tail = binary_part(bytes, tail_start, byte_size(bytes) - tail_start)

    tail
    |> :binary.matches(<<0x50, 0x4B, 5, 6>>)
    |> Enum.reverse()
    |> Enum.find_value({:error, :directory}, fn {relative, _} ->
      offset = tail_start + relative
      rest = binary_part(bytes, offset, byte_size(bytes) - offset)

      case rest do
        <<0x50, 0x4B, 5, 6, 0::little-16, 0::little-16, disk_count::little-16, count::little-16,
          size::little-32, start::little-32, comment::little-16, comment_bytes::binary>>
        when byte_size(comment_bytes) == comment and disk_count == count and
               start + size == offset and count < 65_535 ->
          {:ok, count, start, size}

        _ ->
          nil
      end
    end)
  end

  defp directory(_), do: {:error, :directory}

  defp entries(_bytes, _start, 0, 0, entries, ranges, expanded),
    do: {:ok, entries, ranges, expanded}

  defp entries(bytes, start, remaining, count, entries, ranges, expanded)
       when count > 0 and remaining >= 46 do
    header = binary_part(bytes, start, remaining)

    case header do
      <<0x50, 0x4B, 1, 2, _made::little-16, _version::little-16, flags::little-16,
        method::little-16, _time::little-16, _date::little-16, crc::little-32,
        compressed::little-32, size::little-32, names::little-16, extras::little-16,
        comments::little-16, 0::little-16, _internal::little-16, external::little-32,
        offset::little-32, rest::binary>>
      when names + extras + comments <= byte_size(rest) and size <= @max_member and
             expanded + size <= @max_expanded and method in [0, 8] and
             size <= max(compressed, 1) * 100 ->
        <<name::binary-size(^names), _::binary>> = rest
        consumed = 46 + names + extras + comments

        with true <- band(flags, 0x41) == 0 and band(external >>> 16, 0xF000) != 0xA000,
             true <- safe_name?(name) and not Map.has_key?(entries, name),
             {:ok, data_offset, end_offset} <-
               local(bytes, offset, start, name, flags, method, crc, compressed, size) do
          entry = %{
            offset: data_offset,
            compressed: compressed,
            size: size,
            crc: crc,
            method: method
          }

          entries(
            bytes,
            start + consumed,
            remaining - consumed,
            count - 1,
            Map.put(entries, name, entry),
            [{offset, end_offset} | ranges],
            expanded + size
          )
        else
          _ -> {:error, :member}
        end

      _ ->
        {:error, :directory}
    end
  end

  defp entries(_, _, _, _, _, _, _), do: {:error, :directory}

  defp local(bytes, offset, directory_start, name, flags, method, crc, compressed, size)
       when offset + 30 <= directory_start do
    case binary_part(bytes, offset, directory_start - offset) do
      <<0x50, 0x4B, 3, 4, _version::little-16, ^flags::little-16, ^method::little-16,
        _time::little-16, _date::little-16, local_crc::little-32, local_compressed::little-32,
        local_size::little-32, names::little-16, extras::little-16, rest::binary>>
      when names + extras + compressed <= byte_size(rest) ->
        <<local_name::binary-size(^names), _::binary>> = rest
        data_offset = offset + 30 + names + extras
        end_offset = data_offset + compressed

        cond do
          local_name != name ->
            {:error, :name}

          band(flags, 8) != 0 ->
            descriptor(bytes, end_offset, directory_start, crc, compressed, size, data_offset)

          {local_crc, local_compressed, local_size} == {crc, compressed, size} ->
            {:ok, data_offset, end_offset}

          true ->
            {:error, :sizes}
        end

      _ ->
        {:error, :local}
    end
  end

  defp local(_, _, _, _, _, _, _, _, _), do: {:error, :local}

  defp descriptor(bytes, offset, boundary, crc, compressed, size, data_offset) do
    case binary_part(bytes, offset, boundary - offset) do
      <<0x50, 0x4B, 7, 8, ^crc::little-32, ^compressed::little-32, ^size::little-32, _::binary>> ->
        {:ok, data_offset, offset + 16}

      <<^crc::little-32, ^compressed::little-32, ^size::little-32, _::binary>> ->
        {:ok, data_offset, offset + 12}

      _ ->
        {:error, :descriptor}
    end
  end

  defp safe_name?(name) do
    String.valid?(name) and byte_size(name) in 1..1_024 and
      not String.contains?(name, ["\\", <<0>>, ":", "%"]) and
      not String.starts_with?(name, "/") and
      Enum.all?(String.split(String.trim_trailing(name, "/"), "/"), &(&1 not in ["", ".", ".."]))
  end

  defp disjoint?([{_, ending}, {start, _} | _]) when ending > start, do: false
  defp disjoint?([_ | rest]), do: disjoint?(rest)
  defp disjoint?([]), do: true

  defp decode(bytes, 0, size) when byte_size(bytes) == size, do: {:ok, bytes}
  defp decode(_bytes, 0, _size), do: {:error, :size}

  defp decode(bytes, 8, size) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, -15)
      result = drain(z, bytes, size, [], 0)
      :ok = :zlib.inflateEnd(z)
      result
    catch
      :error, _ -> {:error, :deflate}
    after
      :zlib.close(z)
    end
  end

  defp drain(z, bytes, limit, parts, used) do
    {status, output} = :zlib.safeInflate(z, bytes)
    output_size = IO.iodata_length(output)
    used = used + output_size

    cond do
      used > limit -> {:error, :expanded_limit}
      status == :finished -> {:ok, IO.iodata_to_binary(Enum.reverse([output | parts]))}
      bytes == <<>> and output_size == 0 -> {:error, :deflate}
      true -> drain(z, <<>>, limit, [output | parts], used)
    end
  end
end
