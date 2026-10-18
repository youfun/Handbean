defmodule HandbeanWeb.WorkspaceLive.ToolProjectionTest do
  use ExUnit.Case, async: true

  alias HandbeanWeb.WorkspaceLive.ToolProjection

  test "finish keeps the start name when the end payload has none" do
    %{entry: started} =
      ToolProjection.start(%{tool: "Execute", tool_use_id: "WrxcLFl8Z", input: %{}}, fn _input,
                                                                                        _name ->
        ""
      end)

    %{entry: finished, tool_name: tool_name} =
      ToolProjection.finish(%{tool_use_id: "WrxcLFl8Z", output: "ok"}, started)

    assert tool_name == "Execute"
    assert finished["tool_name"] == "Execute"
    assert finished["tool_status"] == "done"
    assert finished["output"] == "ok"
  end

  test "finish does not replace a real name with the unknown placeholder" do
    base = %{
      "id" => "tool-t1",
      "tool_use_id" => "t1",
      "tool_name" => "Read"
    }

    %{entry: finished} =
      ToolProjection.finish(%{tool_use_id: "t1", tool: "unknown", output: "file"}, base)

    assert finished["tool_name"] == "Read"
  end
end
