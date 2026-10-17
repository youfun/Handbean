defmodule Handbean.Tool.ActiveSetTest do
  use ExUnit.Case, async: false

  alias Handbean.Tool.Registry

  setup do
    registry_state = :sys.get_state(Registry)
    snapshot_sync_id = "active-set-test-sync-#{System.unique_integer([:positive])}"

    for tool <- [Handbean.Tool.Builtin.Read, Handbean.Tool.Builtin.Bash] do
      assert :ok = Registry.register(tool)
    end

    on_exit(fn ->
      :sys.replace_state(Registry, fn _current -> registry_state end)
      Registry.set_active_for_session(snapshot_sync_id, nil)
    end)
  end

  describe "set_active_for_session/2 and active_for_session/1" do
    test "no active set returns nil (all tools available)" do
      assert Registry.active_for_session("no-such-session") == nil
    end

    test "setting active set stores the list" do
      session_id = "active-test-#{System.unique_integer([:positive])}"
      assert :ok = Registry.set_active_for_session(session_id, ["read", "edit"])
      assert Registry.active_for_session(session_id) == ["read", "edit"]
    end

    test "setting nil clears the active set" do
      session_id = "active-nil-#{System.unique_integer([:positive])}"
      assert :ok = Registry.set_active_for_session(session_id, ["read"])
      assert Registry.active_for_session(session_id) == ["read"]
      assert :ok = Registry.set_active_for_session(session_id, nil)
      assert Registry.active_for_session(session_id) == nil
    end

    test "different sessions have independent active sets" do
      s1 = "active-s1-#{System.unique_integer([:positive])}"
      s2 = "active-s2-#{System.unique_integer([:positive])}"

      Registry.set_active_for_session(s1, ["read"])
      Registry.set_active_for_session(s2, ["edit", "bash"])

      assert Registry.active_for_session(s1) == ["read"]
      assert Registry.active_for_session(s2) == ["edit", "bash"]
    end
  end

  describe "tool_defs_for_session/1" do
    test "with no active set returns all tool defs" do
      defs = Registry.tool_defs_for_session("no-active-set")
      all_defs = Registry.tool_defs()
      assert length(defs) == length(all_defs)
    end

    test "with active set returns only allowed tools" do
      session_id = "active-filter-#{System.unique_integer([:positive])}"
      Registry.set_active_for_session(session_id, ["read", "bash"])

      defs = Registry.tool_defs_for_session(session_id)
      names = Enum.map(defs, & &1.name)

      assert "read" in names
      assert "bash" in names
      refute "edit" in names
      refute "write" in names
    end

    test "active set with non-existent tool names filters them out" do
      session_id = "active-ghost-#{System.unique_integer([:positive])}"
      Registry.set_active_for_session(session_id, ["read", "nonexistent_tool"])

      defs = Registry.tool_defs_for_session(session_id)
      names = Enum.map(defs, & &1.name)

      assert names == ["read"]
    end
  end
end
