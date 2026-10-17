defmodule Handbean.Agent.Provider.Cursor.NativeProtocolTest do
  use ExUnit.Case, async: true

  alias Handbean.Agent.Provider.Cursor.{Native, Proto}

  test "shell maps working_directory to bash cwd and keeps timeout unchanged" do
    assert {:tool, "bash", input} =
             Native.map(
               :shell,
               %{command: "ls", working_directory: "/tmp/proj", timeout: 30},
               ["bash"]
             )

    assert input["cwd"] == "/tmp/proj"
    assert input["timeout"] == 30
    refute Map.has_key?(input, "working_directory")
  end

  test "shell_stream success emits start/stdout/exit frames not ShellResult" do
    frames = Native.encode_result(:shell_stream, "hello", false)

    kinds =
      Enum.map(frames, fn
        {kind, _} -> kind
        other -> other
      end)

    assert :stream_close in kinds

    payloads =
      frames
      |> Enum.filter(&match?({:stream, _}, &1))
      |> Enum.map(fn {:stream, bin} -> Proto.decode_fields(bin) end)

    # field 4 = start, field 1 = stdout, field 3 = exit
    fields = Enum.flat_map(payloads, fn f -> Enum.map(f, &elem(&1, 0)) end)
    assert 4 in fields
    assert 1 in fields
    assert 3 in fields
    refute 2 in fields or match_shell_result?(hd(payloads))
  end

  test "unsupported native uses the original result field, not MCP field 11" do
    exec = Proto.decode_server(independent_exec(9))
    assert {:exec, %{kind: :unsupported, result_field: 9}} = exec
    rejected = Native.encode_rejection(:unsupported, "nope")
    fields = Proto.decode_fields(rejected)
    refute Enum.any?(fields, fn {field, _, _} -> field == 11 end)
  end

  test "golden MCP exec bytes from an independent encoder decode tool args" do
    bin = IndependentProto.encode_mcp_exec(7, "call-1", "probe_lookup", "violet-17")
    assert {:exec, %{kind: :mcp, payload: payload, result_field: 11}} = Proto.decode_server(bin)
    assert payload.args["key"] == "violet-17"
    assert payload.tool_call_id == "call-1"
  end

  defp match_shell_result?(fields) do
    Enum.any?(fields, fn {field, _, _} -> field == 5 end)
  end

  defp independent_exec(field) do
    IndependentProto.encode_message(
      2,
      IndependentProto.encode_uint32(1, 1) <>
        IndependentProto.encode_message(field, <<>>) <>
        IndependentProto.encode_string(15, "e")
    )
  end
end
