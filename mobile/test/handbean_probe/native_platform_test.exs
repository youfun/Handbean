defmodule HandbeanProbe.NativePlatformTest do
  use ExUnit.Case, async: false

  alias HandbeanProbe.NativePlatform
  alias HandbeanProbe.NativeUI

  setup do
    previous = Application.get_env(:handbean_probe, :native_platform)
    on_exit(fn -> restore(previous) end)
    :ok
  end

  test "Mix host defaults to android so existing Compose assertions stay valid" do
    Application.delete_env(:handbean_probe, :native_platform)
    assert NativePlatform.get() == :android
    refute NativePlatform.ios?()
  end

  test "settings_button is a stock button on iOS and settings_button on Android" do
    NativePlatform.put!(:android)
    assert NativeUI.settings_button("Save", :save).type == :settings_button

    NativePlatform.put!(:ios)
    assert NativeUI.settings_button("Save", :save).type == :button
  end

  test "select is collapsed on iOS until opened" do
    NativePlatform.put!(:ios)
    option = NativeUI.select_option("GPT", :gpt, true)

    closed =
      NativeUI.select("GPT", [option],
        fill_width: false,
        on_toggle: {:composer_select, :model}
      )

    assert closed.type == :text
    assert closed.props.text == "GPT"
    assert closed.props[:accessibility_role] == "dropdown"

    open =
      NativeUI.select("GPT", [option],
        open: true,
        fill_width: true,
        on_toggle: {:composer_select, :model}
      )

    assert open.type == :column
    assert length(open.children) == 2
    trigger = hd(open.children)
    assert trigger.type == :text
    assert trigger.props.text == "GPT"
    menu = Enum.at(open.children, 1)
    assert menu.type == :column
    assert Enum.any?(menu.children, &(&1.props[:text] == "GPT" and &1.props[:selected] == true))
  end

  test "select options keep selection, accessibility, and tap semantics across platforms" do
    NativePlatform.put!(:ios)
    selected = NativeUI.select_option("medium", :medium, true)
    idle = NativeUI.select_option("off", :off, false)
    assert selected.props.selected == true
    assert selected.props[:accessibility_role] == "menuitem"
    assert selected.props[:on_tap]
    refute idle.props.selected
    assert idle.props[:on_tap]

    NativePlatform.put!(:android)
    android = NativeUI.select_option("medium", :medium, true)
    assert android.props.selected == true
    assert android.props[:on_tap]
    assert android.props[:accessibility_role] == "menuitem"
  end

  test "dist node is platform-specific" do
    assert NativePlatform.dist_node(:ios) == :"handbean_probe_ios@127.0.0.1"
    assert NativePlatform.dist_node(:android) == :"handbean_probe_android@127.0.0.1"
  end

  defp restore(nil), do: Application.delete_env(:handbean_probe, :native_platform)
  defp restore(value), do: Application.put_env(:handbean_probe, :native_platform, value)
end
