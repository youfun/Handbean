defmodule Handbean.Agent.Provider.Cursor.NativeTest do
  use ExUnit.Case, async: true

  alias Handbean.Agent.Provider.Cursor.Native

  test "maps read onto Handbean read without bypassing ToolGuard" do
    assert {:tool, "read", %{"file_path" => "/tmp/a"}} =
             Native.map(:read, %{path: "/tmp/a"}, ["read", "write"])
  end

  test "rejects native delete instead of executing it" do
    assert {:reject, message} = Native.map(:delete, %{path: "/tmp/a"}, ["read"])
    assert message =~ "delete"
  end

  test "rejects unsupported native when no equivalent tool is advertised" do
    assert {:reject, _} = Native.map(:shell, %{command: "ls"}, ["read"])
  end

  test "mcp requests keep name and args" do
    assert {:mcp, %{name: "probe_lookup"}} =
             Native.map(:mcp, %{name: "probe_lookup", args: %{"key" => "violet-17"}}, [
               "probe_lookup"
             ])
  end
end
