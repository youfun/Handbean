defmodule HandbeanWeb.ErrorJSONTest do
  use HandbeanWeb.ConnCase, async: true

  test "renders 404" do
    assert HandbeanWeb.ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "renders 500" do
    assert HandbeanWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
