defmodule Handbean.Agent.Provider.Cursor.Proto do
  @moduledoc """
  Minimal interoperability codec for Cursor `agent.v1`.

  Field numbers follow the community-observed schema used by
  ephraimduncan/opencode-cursor. This is not a completed clean-room
  legal process: it encodes/decodes the subset Handbean needs and skips
  unknown fields by wire type. It does not copy generated TypeScript or
  descriptor blobs.
  """

  import Bitwise

  @wire_varint 0
  @wire_64 1
  @wire_len 2
  @wire_32 5

  # ── Encode primitives ────────────────────────────────────────────────

  def encode_varint(n) when n >= 0 do
    do_encode_varint(n, [])
  end

  def encode_key(field, wire), do: encode_varint(field <<< 3 ||| wire)

  def encode_string(field, value) when is_binary(value) do
    [encode_key(field, @wire_len), encode_varint(byte_size(value)), value]
  end

  def encode_bytes(field, value) when is_binary(value) do
    encode_string(field, value)
  end

  def encode_bool(field, true), do: [encode_key(field, @wire_varint), encode_varint(1)]
  def encode_bool(field, false), do: [encode_key(field, @wire_varint), encode_varint(0)]

  def encode_int32(field, n) when is_integer(n),
    do: [encode_key(field, @wire_varint), encode_varint(n)]

  def encode_uint32(field, n) when is_integer(n) and n >= 0,
    do: [encode_key(field, @wire_varint), encode_varint(n)]

  def encode_double(field, n) when is_number(n) do
    [encode_key(field, @wire_64), <<n::float-little-64>>]
  end

  def encode_message(field, iodata) do
    bin = IO.iodata_to_binary(iodata)
    [encode_key(field, @wire_len), encode_varint(byte_size(bin)), bin]
  end

  def encode_map_entry(field, key, value_bytes) when is_binary(key) and is_binary(value_bytes) do
    entry = [encode_string(1, key), encode_bytes(2, value_bytes)]
    encode_message(field, entry)
  end

  def finish(iodata), do: IO.iodata_to_binary(iodata)

  # ── Decode ───────────────────────────────────────────────────────────

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
    case List.keyfind(fields, n, 0) do
      {^n, _wire, value} -> value
      nil -> nil
    end
  end

  def fields(fields, n) do
    for {^n, _wire, value} <- fields, do: value
  end

  def decode_string(bin) when is_binary(bin), do: bin
  def decode_string(_), do: ""

  def nested(bin) when is_binary(bin), do: decode_fields(bin)
  def nested(_), do: []

  def decode_varint(bin), do: do_decode_varint(bin, 0, 0)

  defp do_encode_varint(n, acc) when n < 128, do: Enum.reverse([n | acc])

  defp do_encode_varint(n, acc) do
    do_encode_varint(n >>> 7, [(n &&& 0x7F) ||| 0x80 | acc])
  end

  defp do_decode_varint(<<byte, rest::binary>>, acc, shift) when byte < 128 do
    {acc ||| byte <<< shift, rest}
  end

  defp do_decode_varint(<<byte, rest::binary>>, acc, shift) do
    do_decode_varint(rest, acc ||| (byte &&& 0x7F) <<< shift, shift + 7)
  end

  defp do_decode_varint(<<>>, acc, _shift), do: {acc, <<>>}

  defp take_value(@wire_varint, bin) do
    {n, rest} = decode_varint(bin)
    {:ok, n, rest}
  end

  defp take_value(@wire_64, <<value::binary-size(8), rest::binary>>), do: {:ok, value, rest}

  defp take_value(@wire_len, bin) do
    {len, rest} = decode_varint(bin)

    if byte_size(rest) >= len do
      value = binary_part(rest, 0, len)
      rest2 = binary_part(rest, len, byte_size(rest) - len)
      {:ok, value, rest2}
    else
      :error
    end
  end

  defp take_value(@wire_32, <<value::binary-size(4), rest::binary>>), do: {:ok, value, rest}
  defp take_value(_wire, _bin), do: :error

  # ── google.protobuf.Value ────────────────────────────────────────────

  def encode_value(nil), do: finish(encode_int32(1, 0))
  def encode_value(n) when is_integer(n), do: finish(encode_double(2, :erlang.float(n)))
  def encode_value(n) when is_float(n), do: finish(encode_double(2, n))
  def encode_value(s) when is_binary(s), do: finish(encode_string(3, s))
  def encode_value(true), do: finish(encode_bool(4, true))
  def encode_value(false), do: finish(encode_bool(4, false))

  def encode_value(list) when is_list(list) do
    items = Enum.map(list, &encode_message(1, encode_value(&1)))
    finish(encode_message(6, items))
  end

  def encode_value(map) when is_map(map) do
    entries =
      Enum.map(map, fn {k, v} ->
        encode_map_entry(1, to_string(k), encode_value(v))
      end)

    finish(encode_message(5, entries))
  end

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
      f = nested(entry)
      {decode_string(field(f, 1)), decode_value(field(f, 2) || <<>>)}
    end)
  end

  defp decode_list(bin) do
    decode_fields(bin)
    |> fields(1)
    |> Enum.map(&decode_value/1)
  end

  # ── Domain messages ──────────────────────────────────────────────────

  def encode_client(%{run_request: req}) do
    finish(encode_message(1, req))
  end

  def encode_client(%{exec_client: msg}) do
    finish(encode_message(2, msg))
  end

  def encode_client(%{kv_client: msg}) do
    finish(encode_message(3, msg))
  end

  def encode_client(%{conversation_action: msg}) do
    finish(encode_message(4, msg))
  end

  def encode_client(%{exec_control: msg}) do
    finish(encode_message(5, msg))
  end

  def encode_client(%{interaction_response: msg}) do
    finish(encode_message(6, msg))
  end

  def encode_client(:heartbeat) do
    finish(encode_message(7, <<>>))
  end

  def encode_run_request(opts) do
    [
      encode_message(1, Keyword.fetch!(opts, :conversation_state)),
      encode_message(2, Keyword.fetch!(opts, :action)),
      encode_string(5, Keyword.fetch!(opts, :conversation_id)),
      encode_message(9, Keyword.fetch!(opts, :requested_model))
    ]
    |> finish()
  end

  def encode_available_models_request do
    [encode_bool(5, true), encode_bool(7, true)] |> finish()
  end

  def encode_user_action(user_message) do
    finish(encode_message(1, encode_message(1, user_message)))
  end

  def encode_resume_action do
    finish(encode_message(2, <<>>))
  end

  def encode_user_message(text, message_id) do
    [encode_string(1, text), encode_string(2, message_id)] |> finish()
  end

  def encode_requested_model(model_id, opts \\ []) do
    parameters =
      opts
      |> Keyword.get(:parameters, [])
      |> Enum.map(fn parameter ->
        id = Handbean.Utils.SafeMap.get_any(parameter, :id, "id") || ""
        value = Handbean.Utils.SafeMap.get_any(parameter, :value, "value") || ""
        encode_message(3, encode_string(1, id) ++ encode_string(2, value))
      end)

    [
      encode_string(1, model_id),
      encode_bool(2, Keyword.get(opts, :max_mode, false)),
      parameters
    ]
    |> finish()
  end

  def encode_conversation_state(root_ids, turn_ids, extra \\ %{}) do
    iodata =
      Enum.map(root_ids, &encode_bytes(1, &1)) ++
        Enum.map(turn_ids, &encode_bytes(8, &1))

    extra_bin = Map.get(extra, :raw) || <<>>
    finish([iodata, extra_bin])
  end

  def encode_turn(user_blob_id, step_ids, request_id \\ nil) do
    agent =
      [
        encode_bytes(1, user_blob_id),
        Enum.map(step_ids, &encode_bytes(2, &1)),
        if(request_id, do: encode_string(3, request_id), else: [])
      ]
      |> finish()

    finish(encode_message(1, agent))
  end

  def encode_assistant_step(text) do
    finish(encode_message(1, encode_string(1, text)))
  end

  @doc """
  ConversationStep.tool_call → ToolCall.mcp_tool_call → McpToolCall.

  Nested field numbers follow the community `agent.v1` schema
  (ConversationStep=2, ToolCall oneof mcp=15, McpArgs=1, McpToolResult=2).
  Args map values are `google.protobuf.Value` bytes, not JSON strings.
  A completed tool result is attached on the same McpToolCall, not a
  separate ConversationStep.
  """
  def encode_tool_call_step(id, name, input, result \\ nil) when is_map(input) do
    mcp =
      [
        encode_message(1, encode_mcp_args(id, name, input)),
        if(result, do: encode_message(2, encode_mcp_tool_result(result)), else: [])
      ]
      |> finish()

    finish(encode_message(2, encode_message(15, mcp)))
  end

  def encode_mcp_args(id, name, input) when is_map(input) do
    entries =
      Enum.map(input, fn {key, value} ->
        encode_map_entry(2, to_string(key), encode_value(value))
      end)

    [
      encode_string(1, name || ""),
      entries,
      encode_string(3, id || ""),
      encode_string(4, "handbean"),
      encode_string(5, name || "")
    ]
    |> finish()
  end

  def encode_mcp_tool_result({:success, text, is_error}) do
    encode_mcp_success(text, is_error)
  end

  def encode_mcp_tool_result({:error, message}) do
    encode_mcp_error(message)
  end

  def encode_mcp_tool_result({:rejected, message}) do
    encode_mcp_rejected(message)
  end

  def encode_kv_get_result(id, data) do
    result =
      if is_binary(data) do
        encode_bytes(1, data)
      else
        <<>>
      end

    [encode_uint32(1, id), encode_message(2, result)] |> finish()
  end

  def encode_kv_set_result(id) do
    [encode_uint32(1, id), encode_message(3, <<>>)] |> finish()
  end

  def encode_request_context(tools, cloud_rule) do
    tool_msgs = Enum.map(tools, &encode_message(7, encode_mcp_tool(&1)))

    success =
      [tool_msgs, if(cloud_rule, do: encode_string(16, cloud_rule), else: [])]
      |> finish()

    finish(encode_message(1, encode_message(1, success)))
  end

  def encode_mcp_tool(%{name: name, description: description, schema: schema}) do
    [
      encode_string(1, name),
      encode_string(2, description || ""),
      encode_bytes(3, encode_value(schema || %{})),
      encode_string(4, "handbean"),
      encode_string(5, name)
    ]
    |> finish()
  end

  def encode_exec_client(id, exec_id, field, payload) do
    [
      encode_uint32(1, id),
      encode_message(field, payload),
      encode_string(15, exec_id || "")
    ]
    |> finish()
  end

  def encode_interaction_approval(id, field) when field in [2, 5, 6] do
    result = finish(encode_message(1, <<>>))
    finish(encode_uint32(1, id) ++ encode_message(field, result))
  end

  def encode_mcp_success(text, is_error \\ false) do
    item = finish(encode_message(1, encode_string(1, text || "")))
    success = [encode_message(1, item), encode_bool(2, is_error)] |> finish()
    finish(encode_message(1, success))
  end

  def encode_mcp_error(message) do
    finish(encode_message(2, encode_string(1, message)))
  end

  def encode_mcp_rejected(message) do
    finish(encode_message(3, encode_string(1, message)))
  end

  def encode_native_rejected(field, message) do
    error = finish(encode_string(1, message))

    rejected_oneof =
      case field do
        # ReadResult.error = 2
        7 -> 2
        # WriteResult.error = 5
        3 -> 5
        # ShellResult.rejected = 4
        2 -> 4
        # GrepResult.error = 2
        5 -> 2
        # LsResult.error = 2
        8 -> 2
        # DeleteResult.error = 7
        4 -> 7
        # FetchResult.error = 2
        20 -> 2
        # ShellStream.rejected = 5
        14 -> 5
        _ -> 2
      end

    finish(encode_message(rejected_oneof, error))
  end

  def encode_shell_stream_start do
    finish(encode_message(4, <<>>))
  end

  def encode_shell_stream_stdout(data) do
    finish(encode_message(1, encode_string(1, data || "")))
  end

  def encode_shell_stream_exit(code) do
    finish(encode_message(3, encode_int32(1, code || 0)))
  end

  def encode_shell_stream_rejected(message) do
    finish(encode_message(5, encode_string(1, message)))
  end

  def encode_stream_close(exec_id) when is_integer(exec_id) do
    close = finish(encode_uint32(1, exec_id))
    finish(encode_message(1, close))
  end

  def encode_stream_close(exec_id) when is_binary(exec_id) do
    case Integer.parse(exec_id) do
      {int, _} -> encode_stream_close(int)
      :error -> encode_stream_close(0)
    end
  end

  def encode_start_grind_planning_success do
    finish(encode_message(1, <<>>))
  end

  def encode_native_success(_field, payload) do
    finish(encode_message(1, payload))
  end

  def encode_read_success(path, content) do
    [
      encode_string(1, path || ""),
      encode_string(2, content || ""),
      encode_int32(3, line_count(content)),
      encode_int32(4, byte_size(content || ""))
    ]
    |> finish()
  end

  def encode_write_success(path) do
    [encode_string(1, path || "")] |> finish()
  end

  def encode_shell_success(command, stdout, stderr, exit_code) do
    [
      encode_string(1, command || ""),
      encode_int32(3, exit_code || 0),
      encode_string(5, stdout || ""),
      encode_string(6, stderr || "")
    ]
    |> finish()
  end

  def encode_fetch_success(url, content) do
    [encode_string(1, url || ""), encode_string(2, content || ""), encode_int32(3, 200)]
    |> finish()
  end

  def encode_ls_success(path, entries) do
    files =
      Enum.map(entries, fn name ->
        encode_message(3, encode_string(1, name))
      end)

    node = [encode_string(1, path || ""), files, encode_bool(4, true)] |> finish()
    finish(encode_message(1, node))
  end

  def decode_server(bin) do
    fields = decode_fields(bin)

    cond do
      (v = field(fields, 1)) != nil -> {:interaction, decode_interaction(v)}
      (v = field(fields, 2)) != nil -> {:exec, decode_exec(v)}
      (v = field(fields, 3)) != nil -> {:checkpoint, v}
      (v = field(fields, 4)) != nil -> {:kv, decode_kv(v)}
      (v = field(fields, 7)) != nil -> {:interaction_query, decode_interaction_query(v)}
      true -> {:unknown, fields}
    end
  end

  def decode_models_response(bin) do
    decode_fields(maybe_unwrap_connect(bin))
    |> fields(1)
    |> Enum.map(&decode_model_details/1)
  end

  def decode_available_models_response(bin) do
    decode_fields(maybe_unwrap_connect(bin))
    |> fields(2)
    |> Enum.map(&decode_parameterized_model/1)
    |> Enum.reject(&(&1.name == ""))
  end

  defp decode_parameterized_model(bin) do
    f = nested(bin)

    %{
      name: decode_string(field(f, 1) || ""),
      supports_images?: field(f, 10) == 1,
      supports_max_mode?: field(f, 14) == 1,
      context_token_limit: field(f, 15),
      max_context_token_limit: field(f, 16),
      client_display_name: decode_string(field(f, 17) || ""),
      server_model_name: decode_string(field(f, 18) || ""),
      supports_non_max_mode?: field(f, 19) == 1,
      variants: Enum.map(fields(f, 30), &decode_model_variant/1)
    }
  end

  defp decode_model_variant(bin) do
    f = nested(bin)

    %{
      parameters: Enum.map(fields(f, 1), &decode_model_parameter/1),
      display_name: decode_string(field(f, 2) || ""),
      max_mode?: field(f, 3) == 1,
      default_max?: field(f, 4) == 1,
      default_non_max?: field(f, 5) == 1,
      outside_picker_name: decode_string(field(f, 8) || ""),
      representation: decode_string(field(f, 9) || "")
    }
  end

  defp decode_model_parameter(bin) do
    f = nested(bin)

    %{
      id: decode_string(field(f, 1) || ""),
      value: decode_string(field(f, 2) || "")
    }
  end

  def decode_model_details(bin) do
    f = nested(bin)

    %{
      id: decode_string(field(f, 1) || ""),
      thinking?: field(f, 2) != nil,
      display_id: decode_string(field(f, 3) || field(f, 1) || ""),
      name: decode_string(field(f, 4) || field(f, 1) || ""),
      short_name: decode_string(field(f, 5) || ""),
      aliases: Enum.map(fields(f, 6), &decode_string/1)
    }
  end

  defp maybe_unwrap_connect(<<0, len::32-big, rest::binary>>) when byte_size(rest) >= len do
    binary_part(rest, 0, len)
  end

  defp maybe_unwrap_connect(bin), do: bin

  defp decode_interaction(bin) do
    f = nested(bin)

    cond do
      (v = field(f, 1)) != nil -> {:text_delta, decode_string(field(nested(v), 1) || "")}
      (v = field(f, 4)) != nil -> {:thinking_delta, decode_string(field(nested(v), 1) || "")}
      (v = field(f, 8)) != nil -> {:token_delta, field(nested(v), 1) || 0}
      field(f, 14) != nil -> :turn_ended
      field(f, 13) != nil -> :heartbeat
      true -> :other
    end
  end

  defp decode_interaction_query(bin) do
    fields = nested(bin)

    {kind, response_field} =
      cond do
        field(fields, 2) != nil -> {:web_search, 2}
        field(fields, 3) != nil -> {:ask_question, 3}
        field(fields, 4) != nil -> {:switch_mode, 4}
        field(fields, 5) != nil -> {:exa_search, 5}
        field(fields, 6) != nil -> {:exa_fetch, 6}
        field(fields, 7) != nil -> {:create_plan, 7}
        field(fields, 8) != nil -> {:setup_vm_environment, 8}
        true -> {:unknown, 0}
      end

    %{id: field(fields, 1) || 0, kind: kind, response_field: response_field}
  end

  defp decode_exec(bin) do
    f = nested(bin)
    {kind, payload, result_field} = exec_dispatch(f)

    %{
      id: field(f, 1) || 0,
      exec_id: decode_string(field(f, 15) || ""),
      kind: kind,
      payload: payload,
      result_field: result_field
    }
  end

  # Field number, kind, payload decoder. Presence-only kinds use an empty payload.
  # First matching field wins, matching the previous cond order.
  defp exec_dispatch(fields) do
    exec_fields()
    |> Enum.find_value({:unknown, %{}, 0}, fn {number, kind, decoder} ->
      case field(fields, number) do
        nil -> nil
        value -> {kind, exec_payload(decoder, value), number}
      end
    end)
  end

  defp exec_fields do
    [
      {2, :shell, &decode_shell_args/1},
      {3, :write, &decode_write_args/1},
      {4, :delete, &decode_path_args/1},
      {5, :grep, &decode_grep_args/1},
      {7, :read, &decode_path_args/1},
      {8, :ls, &decode_ls_args/1},
      {9, :unsupported, nil},
      {10, :request_context, nil},
      {11, :mcp, &decode_mcp_args/1},
      {14, :shell_stream, &decode_shell_args/1},
      {16, :unsupported, nil},
      {17, :unsupported, nil},
      {18, :unsupported, nil},
      {20, :fetch, &decode_fetch_args/1},
      {21, :unsupported, nil},
      {22, :unsupported, nil},
      {23, :unsupported, nil},
      {36, :start_grind_planning, &decode_grind_args/1}
    ]
  end

  defp exec_payload(nil, _value), do: %{}
  defp exec_payload(decoder, value), do: decoder.(value)

  defp decode_grind_args(bin) do
    f = nested(bin)

    %{
      explanation: decode_string(field(f, 1) || ""),
      tool_call_id: decode_string(field(f, 2) || "")
    }
  end

  defp decode_path_args(bin) do
    f = nested(bin)

    %{
      path: decode_string(field(f, 1) || ""),
      tool_call_id: decode_string(field(f, 2) || "")
    }
  end

  defp decode_write_args(bin) do
    f = nested(bin)

    %{
      path: decode_string(field(f, 1) || ""),
      file_text: decode_string(field(f, 2) || ""),
      tool_call_id: decode_string(field(f, 3) || ""),
      file_bytes: field(f, 5)
    }
  end

  defp decode_ls_args(bin) do
    f = nested(bin)

    %{
      path: decode_string(field(f, 1) || ""),
      tool_call_id: decode_string(field(f, 3) || "")
    }
  end

  defp decode_grep_args(bin) do
    f = nested(bin)

    %{
      pattern: decode_string(field(f, 1) || ""),
      path: decode_string(field(f, 2) || ""),
      glob: decode_string(field(f, 3) || ""),
      tool_call_id: decode_string(field(f, 14) || "")
    }
  end

  defp decode_shell_args(bin) do
    f = nested(bin)

    %{
      command: decode_string(field(f, 1) || ""),
      working_directory: decode_string(field(f, 2) || ""),
      timeout: field(f, 3),
      tool_call_id: decode_string(field(f, 4) || "")
    }
  end

  defp decode_fetch_args(bin) do
    f = nested(bin)

    %{
      url: decode_string(field(f, 1) || ""),
      tool_call_id: decode_string(field(f, 2) || "")
    }
  end

  defp decode_mcp_args(bin) do
    f = nested(bin)

    args =
      f
      |> fields(2)
      |> Map.new(fn entry ->
        ef = nested(entry)
        {decode_string(field(ef, 1)), decode_value(field(ef, 2) || <<>>)}
      end)

    %{
      name: decode_string(field(f, 1) || field(f, 5) || ""),
      args: args,
      tool_call_id: decode_string(field(f, 3) || ""),
      provider_identifier: decode_string(field(f, 4) || ""),
      tool_name: decode_string(field(f, 5) || field(f, 1) || "")
    }
  end

  defp decode_kv(bin) do
    f = nested(bin)
    id = field(f, 1) || 0

    cond do
      (v = field(f, 2)) != nil ->
        {:get, id, field(nested(v), 1)}

      (v = field(f, 3)) != nil ->
        nf = nested(v)
        {:set, id, field(nf, 1), field(nf, 2)}

      true ->
        {:unknown, id}
    end
  end

  defp line_count(nil), do: 0

  defp line_count(text) do
    text |> String.split("\n", trim: false) |> length()
  end
end
