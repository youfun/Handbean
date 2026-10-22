defmodule HandbeanWeb.WorkspaceLive.DiffResponsivenessTest do
  use HandbeanWeb.WorkspaceLiveCase

  test "a large recorded creation opens a bounded diff and still accepts subsequent events", %{
    conn: conn
  } do
    root = Handbean.Workspace.ensure_root!()
    path = Path.join(root, "large-diff.txt")
    content = Enum.map_join(1..12_000, "\n", &"recorded line #{&1}") <> "\n"
    File.write!(path, content)
    change = Handbean.ChangeSnapshot.build_write_snapshot(path, nil, content)
    {:ok, view, _html} = live(conn, "/")

    send_recorded_edit(view, "large-diff", path, change)

    view
    |> element("button[phx-click='select_right_panel_view'][phx-value-view='changes']")
    |> render_click()

    view
    |> element("#workspace-changes [id^='changes-file-net-'][id$='-toggle']")
    |> render_click()

    assert has_element?(view, "#workspace-changes", "recorded line 1")
    assert has_element?(view, "#workspace-changes", "+12000")
    assert has_element?(view, "#workspace-changes", "Diff preview truncated")
    refute has_element?(view, "#workspace-changes", "recorded line 12000")

    view
    |> element("button[phx-click='select_right_panel_view'][phx-value-view='files']")
    |> render_click()

    assert has_element?(view, "#workspace-files")
    assert Process.alive?(view.pid)
  end
end
