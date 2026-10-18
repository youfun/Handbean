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

  test "last location and collapsed groups round-trip and reject junk" do
    assert UI.last_location() == nil
    assert UI.collapsed_groups() == MapSet.new()

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
  end
end
