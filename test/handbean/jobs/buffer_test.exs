defmodule Handbean.Jobs.BufferTest do
  use ExUnit.Case, async: true
  alias Handbean.Jobs.Buffer

  test "byte cursors repeat reads and identify evicted output" do
    buffer = Buffer.append(%Buffer{}, "prefix" <> String.duplicate("x", 50_000) <> "end")
    result = Buffer.read(buffer, 0)
    assert result.truncated
    assert result.available_from == 9
    assert result.cursor == 50_009
    assert result.output == String.duplicate("x", 49_997) <> "end"
    assert Buffer.read(buffer, 0) == result
    assert Buffer.read(buffer, result.cursor).output == ""
    assert Buffer.read(buffer, 50_006).output == "end"
  end

  test "split UTF-8 is withheld until complete without advancing cursor" do
    buffer = Buffer.append(%Buffer{}, <<?a, 0xE4, 0xBD>>)
    assert %{output: "a", cursor: 1} = Buffer.read(buffer, 0, false)
    buffer = Buffer.append(buffer, <<0xA0, ?z>>)
    assert %{output: "你z", cursor: 5} = Buffer.read(buffer, 1, false)
    assert %{output: "a你z", cursor: 5} = Buffer.read(buffer, 0)
  end

  test "invalid and final incomplete bytes are explicit valid UTF-8" do
    buffer = Buffer.append(%Buffer{}, <<?a, 255, ?b, 0xE4, 0xBD>>)
    assert %{output: "a�b��", cursor: 5} = Buffer.read(buffer, 0)
  end
end
