defmodule HandbeanWeb.DesktopHealthControllerTest do
  use HandbeanWeb.ConnCase, async: true

  test "identifies a Handbean backend to the desktop shell", %{conn: conn} do
    conn = get(conn, "/desktop-health")

    assert response(conn, 200) == "handbean-desktop-health:v1"
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end
end
