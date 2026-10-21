defmodule Handbean.Settings.UITest do
  use Handbean.DataCase, async: false

  alias Handbean.Settings.UI

  test "theme defaults to light and round-trips a saved choice" do
    assert UI.theme() == "light"
    assert UI.save_theme("dark") == :ok
    assert UI.theme() == "dark"
    assert UI.save_theme("system") == :ok
    assert UI.theme() == "system"
    assert {:error, _changeset} = UI.save_theme("neon")
    assert UI.theme() == "system"
  end

  test "last location and collapsed sidebar state round-trip and reject junk" do
    assert UI.last_location() == nil
    assert UI.collapsed_groups() == MapSet.new()
    assert UI.collapsed_threads() == MapSet.new()

    assert UI.save_last_location(%{
             scope: :workspace,
             workspace_id: "default",
             conversation_id: "conv-1"
           }) == :ok

    assert UI.last_location() == %{
             scope: :workspace,
             workspace_id: "default",
             conversation_id: "conv-1"
           }

    assert UI.save_last_location(%{scope: :free, conversation_id: "free-1"}) == :ok
    assert UI.last_location() == %{scope: :free, conversation_id: "free-1"}
    assert UI.save_last_location(%{scope: :free, conversation_id: "../etc"}) == {:error, :invalid}
    assert UI.last_location() == %{scope: :free, conversation_id: "free-1"}

    assert UI.save_collapsed_groups(MapSet.new(["free", "ws_1", "bad id", ""])) == :ok
    assert UI.collapsed_groups() == MapSet.new(["free", "ws_1"])

    assert UI.set_thread_collapsed("parent-1", true) == :ok
    assert UI.set_thread_collapsed("parent:2", true) == :ok
    assert UI.collapsed_threads() == MapSet.new(["parent-1", "parent:2"])

    assert UI.set_thread_collapsed("parent-1", false) == :ok
    assert UI.collapsed_threads() == MapSet.new(["parent:2"])
    assert UI.set_thread_collapsed("bad id", true) == {:error, :invalid}

    assert UI.set_thread_collapsed("parent:2", false) == :ok

    for index <- 1..201 do
      assert UI.set_thread_collapsed("parent-#{index}", true) == :ok
    end

    collapsed_threads = UI.collapsed_threads()
    assert MapSet.size(collapsed_threads) == 200
    refute MapSet.member?(collapsed_threads, "parent-1")
    assert MapSet.member?(collapsed_threads, "parent-2")
    assert MapSet.member?(collapsed_threads, "parent-201")
  end
end
