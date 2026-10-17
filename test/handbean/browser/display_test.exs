defmodule Handbean.Browser.DisplayTest do
  use ExUnit.Case, async: false

  alias Handbean.Browser.Display

  setup do
    Display.reset!()
    :ok
  end

  test "switching preview parks the browser session instead of destroying it" do
    assert :ok = Display.show(:browser, "b1", %{conversation_id: "c1", control: :agent})
    assert %{kind: :browser, id: "b1", visible: true} = Display.current()
    assert :ok = Display.show(:preview, "p1", %{conversation_id: "c1"})
    assert %{kind: :preview, id: "p1"} = Display.current()
    assert :ok = Display.hide(:preview, "p1")
    assert Display.current() == nil
  end

  test "another conversation cannot steal a user-controlled foreground" do
    assert :ok = Display.show(:browser, "b1", %{conversation_id: "c1", control: :user})

    assert {:error, :other_conversation_takeover} =
             Display.show(:browser, "b2", %{conversation_id: "c2", control: :user})

    assert %{id: "b1"} = Display.current()
  end
end
