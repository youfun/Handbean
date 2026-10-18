defmodule Handbean.Tool.Builtin.ElixirScriptIO do
  @moduledoc false

  @type snapshot :: %{text: binary(), truncated?: boolean()}

  @spec start_link(pos_integer()) :: pid()
  def start_link(max_bytes, sink \\ nil) when is_integer(max_bytes) and max_bytes > 0 do
    spawn_link(fn -> loop(%{max: max_bytes, acc: [], size: 0, truncated?: false, sink: sink}) end)
  end

  @spec snapshot(pid()) :: snapshot()
  def snapshot(pid) when is_pid(pid) do
    ref = make_ref()
    send(pid, {:snapshot, self(), ref})

    receive do
      {^ref, result} -> result
    after
      1_000 -> %{text: "", truncated?: true}
    end
  end

  @spec stop(pid()) :: :ok
  def stop(pid) when is_pid(pid) do
    send(pid, :stop)
    :ok
  end

  defp loop(state) do
    receive do
      {:io_request, from, reply_as, request} ->
        {reply, state} = handle_request(request, state)
        send(from, {:io_reply, reply_as, reply})
        loop(state)

      {:snapshot, from, ref} ->
        send(from, {ref, finalize(state)})
        loop(state)

      :stop ->
        :ok

      _other ->
        loop(state)
    end
  end

  defp handle_request({:put_chars, encoding, chars}, state) do
    {:ok, append_chars(state, encoding, chars)}
  end

  defp handle_request({:put_chars, encoding, mod, fun, args}, state) do
    handle_request({:put_chars, encoding, apply(mod, fun, args)}, state)
  end

  defp handle_request({:put_chars, chars}, state) do
    handle_request({:put_chars, :latin1, chars}, state)
  end

  defp handle_request({:get_chars, _encoding, _prompt, _n}, state), do: {:eof, state}
  defp handle_request({:get_line, _encoding, _prompt}, state), do: {:eof, state}

  defp handle_request({:get_until, _encoding, _prompt, _mod, _fun, _extra}, state),
    do: {:eof, state}

  defp handle_request({:setopts, _opts}, state), do: {:ok, state}
  defp handle_request(:getopts, state), do: {[binary: true, encoding: :unicode], state}
  defp handle_request({:get_geometry, _kind}, state), do: {{:error, :enotsup}, state}
  defp handle_request(_other, state), do: {{:error, :enotsup}, state}

  defp append_chars(%{truncated?: true, sink: nil} = state, _encoding, _chars), do: state

  defp append_chars(state, encoding, chars) do
    case encode_chars(encoding, chars) do
      {:ok, ""} ->
        state

      {:ok, bin} ->
        if state.sink, do: state.sink.(bin)
        put_bytes(state, bin)

      {:invalid, good} ->
        if state.sink && good != "", do: state.sink.(good)

        good
        |> case do
          "" -> state
          bin -> put_bytes(state, bin)
        end
        |> Map.put(:truncated?, true)
    end
  end

  defp put_bytes(state, bin) do
    remaining = state.max - state.size

    cond do
      remaining <= 0 ->
        %{state | truncated?: true}

      byte_size(bin) <= remaining ->
        %{state | acc: [state.acc, bin], size: state.size + byte_size(bin)}

      true ->
        {chunk, _} = take_utf8(bin, remaining)
        acc = if chunk == "", do: state.acc, else: [state.acc, chunk]

        %{
          state
          | acc: acc,
            size: state.size + byte_size(chunk),
            truncated?: true
        }
    end
  end

  defp encode_chars(encoding, chars) do
    case :unicode.characters_to_binary(chars, normalize_encoding(encoding), :utf8) do
      bin when is_binary(bin) ->
        {:ok, bin}

      {:error, good, _rest} ->
        {:invalid, iodata_to_binary(good)}

      {:incomplete, good, _rest} ->
        {:invalid, iodata_to_binary(good)}
    end
  end

  defp normalize_encoding(:unicode), do: :utf8
  defp normalize_encoding(:utf8), do: :utf8
  defp normalize_encoding(:latin1), do: :latin1
  defp normalize_encoding(encoding) when encoding in [:utf16, :utf32], do: encoding
  defp normalize_encoding(_), do: :utf8

  defp iodata_to_binary(bin) when is_binary(bin), do: bin
  defp iodata_to_binary(list) when is_list(list), do: IO.iodata_to_binary(list)
  defp iodata_to_binary(_), do: ""

  defp finalize(state) do
    %{text: IO.iodata_to_binary(state.acc), truncated?: state.truncated?}
  end

  @spec take_utf8(binary(), non_neg_integer()) :: {binary(), boolean()}
  def take_utf8(bin, max) when is_binary(bin) and is_integer(max) and max >= 0 do
    cond do
      max == 0 ->
        {"", bin != ""}

      byte_size(bin) <= max ->
        {bin, false}

      true ->
        chunk = binary_part(bin, 0, max)

        trimmed =
          case :unicode.characters_to_binary(chunk, :utf8, :utf8) do
            out when is_binary(out) -> out
            {:incomplete, good, _rest} -> iodata_to_binary(good)
            {:error, good, _rest} -> iodata_to_binary(good)
          end

        {trimmed, true}
    end
  end
end
