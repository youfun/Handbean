defmodule HandbeanWeb.WorkspaceLive.ComposerTest do
  use ExUnit.Case, async: true

  alias HandbeanWeb.WorkspaceLive.Composer

  test "prefill_text appends to an existing draft and refreshes skill suggestions" do
    socket = socket("Keep this draft", [%{name: "review"}])

    updated = Composer.prefill_text(socket, "Add the widget choices")

    assert updated.assigns.input_value == "Keep this draft\nAdd the widget choices"
    assert updated.assigns.skill_suggestions == nil

    assert [["composer:set-input", %{value: "Keep this draft\nAdd the widget choices"}]] =
             updated.private.live_temp[:push_events]

    suggested = Composer.prefill_text(socket("", [%{name: "review"}]), "/")
    assert suggested.assigns.skill_suggestions == [%{name: "review"}]
  end

  test "prefill_text replaces a blank draft" do
    updated = Composer.prefill_text(socket("  \n", []), "Visible follow-up")

    assert updated.assigns.input_value == "Visible follow-up"
  end

  defp socket(input_value, skills) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        input_value: input_value,
        available_skills: skills,
        skill_suggestions: nil
      },
      private: %{live_temp: %{}}
    }
  end
end
