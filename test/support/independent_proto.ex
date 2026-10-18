defmodule IndependentProto do
  @moduledoc false

  import Bitwise

  def encode_varint(n) when n < 128, do: <<n>>
  def encode_varint(n), do: <<(n &&& 0x7F) ||| 0x80, encode_varint(n >>> 7)::binary>>
  def encode_key(field, wire), do: encode_varint(field <<< 3 ||| wire)

  def encode_string(field, value),
    do: encode_key(field, 2) <> encode_varint(byte_size(value)) <> value

  def encode_bytes(field, value), do: encode_string(field, value)
  def encode_uint32(field, n), do: encode_key(field, 0) <> encode_varint(n)
  def encode_message(field, bin), do: encode_key(field, 2) <> encode_varint(byte_size(bin)) <> bin

  def encode_server_interaction(field, inner) do
    update = encode_message(field, inner)
    encode_message(1, update)
  end

  def encode_mcp_exec(id, call_id, name, key) do
    value = encode_string(3, key)
    entry = encode_string(1, "key") <> encode_bytes(2, value)

    args =
      encode_string(1, name) <>
        encode_message(2, entry) <>
        encode_string(3, call_id) <>
        encode_string(5, name)

    exec = encode_uint32(1, id) <> encode_message(11, args) <> encode_string(15, "exec-#{id}")
    encode_message(2, exec)
  end

  def decode_fields(bin) when is_binary(bin), do: decode_fields(bin, [])

  defp decode_fields(<<>>, acc), do: Enum.reverse(acc)

  defp decode_fields(bin, acc) do
    {key, rest} = decode_varint(bin)
    field = key >>> 3
    wire = key &&& 0x07

    case take_value(wire, rest) do
      {:ok, value, rest2} -> decode_fields(rest2, [{field, wire, value} | acc])
      :error -> Enum.reverse(acc)
    end
  end

  def field(fields, n) do
    case Enum.find(fields, fn {f, _, _} -> f == n end) do
      {^n, _wire, value} -> value
      nil -> nil
    end
  end

  def fields(fields, n), do: for({^n, _wire, value} <- fields, do: value)

  def decode_varint(bin), do: do_decode_varint(bin, 0, 0)

  defp do_decode_varint(<<byte, rest::binary>>, acc, shift) when byte < 128 do
    {acc ||| byte <<< shift, rest}
  end

  defp do_decode_varint(<<byte, rest::binary>>, acc, shift) do
    do_decode_varint(rest, acc ||| (byte &&& 0x7F) <<< shift, shift + 7)
  end

  defp do_decode_varint(<<>>, acc, _shift), do: {acc, <<>>}

  defp take_value(0, bin) do
    {n, rest} = decode_varint(bin)
    {:ok, n, rest}
  end

  defp take_value(1, <<value::binary-size(8), rest::binary>>), do: {:ok, value, rest}

  defp take_value(2, bin) do
    {len, rest} = decode_varint(bin)

    if byte_size(rest) >= len do
      {:ok, binary_part(rest, 0, len), binary_part(rest, len, byte_size(rest) - len)}
    else
      :error
    end
  end

  defp take_value(5, <<value::binary-size(4), rest::binary>>), do: {:ok, value, rest}
  defp take_value(_wire, _bin), do: :error

  def decode_value(bin) when is_binary(bin) do
    fields = decode_fields(bin)

    cond do
      field(fields, 1) != nil -> nil
      (n = field(fields, 2)) != nil -> decode_double(n)
      (s = field(fields, 3)) != nil -> s
      (b = field(fields, 4)) != nil -> b == 1
      (struct = field(fields, 5)) != nil -> decode_struct(struct)
      (list = field(fields, 6)) != nil -> decode_list(list)
      true -> nil
    end
  end

  defp decode_double(<<n::float-little-64>>), do: n
  defp decode_double(_), do: 0.0

  defp decode_struct(bin) do
    decode_fields(bin)
    |> fields(1)
    |> Map.new(fn entry ->
      f = decode_fields(entry)
      {field(f, 1) || "", decode_value(field(f, 2) || <<>>)}
    end)
  end

  defp decode_list(bin) do
    decode_fields(bin)
    |> fields(1)
    |> Enum.map(&decode_value/1)
  end

  @doc """
  Decode a ConversationStep using the community field numbers, not the
  production encoder's helpers.
  """
  def decode_conversation_step(bin) when is_binary(bin) do
    step = decode_fields(bin)

    cond do
      (assistant = field(step, 1)) != nil ->
        {:assistant, decode_fields(assistant)}

      (tool_call = field(step, 2)) != nil ->
        {:tool_call, decode_tool_call(tool_call)}

      true ->
        {:unknown, step}
    end
  end

  defp decode_tool_call(bin) do
    fields = decode_fields(bin)

    cond do
      (mcp = field(fields, 15)) != nil -> {:mcp, decode_mcp_tool_call(mcp)}
      true -> {:other, fields}
    end
  end

  defp decode_mcp_tool_call(bin) do
    fields = decode_fields(bin)
    args = decode_mcp_args(field(fields, 1) || <<>>)
    result = decode_mcp_result(field(fields, 2))
    %{args: args, result: result}
  end

  defp decode_mcp_args(bin) do
    fields = decode_fields(bin)

    args =
      fields
      |> fields(2)
      |> Map.new(fn entry ->
        f = decode_fields(entry)
        {field(f, 1) || "", decode_value(field(f, 2) || <<>>)}
      end)

    %{
      name: field(fields, 1),
      args: args,
      tool_call_id: field(fields, 3),
      provider_identifier: field(fields, 4),
      tool_name: field(fields, 5)
    }
  end

  defp decode_mcp_result(nil), do: nil

  defp decode_mcp_result(bin) do
    fields = decode_fields(bin)

    cond do
      (success = field(fields, 1)) != nil -> {:success, decode_mcp_success(success)}
      (error = field(fields, 2)) != nil -> {:error, field(decode_fields(error), 1)}
      (rejected = field(fields, 3)) != nil -> {:rejected, field(decode_fields(rejected), 1)}
      true -> {:unknown, fields}
    end
  end

  defp decode_mcp_success(bin) do
    fields = decode_fields(bin)

    texts =
      fields
      |> fields(1)
      |> Enum.map(fn item ->
        item_fields = decode_fields(item)
        text_msg = field(item_fields, 1)
        text_fields = decode_fields(text_msg || <<>>)
        field(text_fields, 1)
      end)

    %{content: texts, is_error: field(fields, 2) == 1}
  end
end
