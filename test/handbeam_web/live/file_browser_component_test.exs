defmodule HandbeamWeb.FileBrowserComponentTest do
  use HandbeamWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "hides dot folders and generated directories by default" do
    root = unique_dir()
    visible = Path.join(root, "src")
    hidden = Path.join(root, ".hidden")
    git = Path.join(root, ".git")
    deps = Path.join(root, "deps")
    Enum.each([visible, hidden, git, deps], &File.mkdir_p!/1)

    {:ok, view, _html} =
      live_isolated(build_conn(), HandbeamWeb.FileBrowserHarness,
        session: %{"path" => root, "show" => true}
      )

    html = render(view)
    assert html =~ "src"
    refute html =~ ".hidden"
    refute html =~ ".git"
    refute html =~ ">deps<"
  end

  test "still lists ordinary folders" do
    root = unique_dir()
    File.mkdir_p!(Path.join(root, "apps"))

    {:ok, _view, html} =
      live_isolated(build_conn(), HandbeamWeb.FileBrowserHarness,
        session: %{"path" => root, "show" => true}
      )

    assert html =~ "apps"
  end

  defp unique_dir do
    path = Path.join(System.tmp_dir!(), "handbeam-browser-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end
end
