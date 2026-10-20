defmodule HandbeanWeb.ErrorDiagnosticsControllerTest do
  use HandbeanWeb.ConnCase, async: false

  test "downloads a decodable JSON attachment without caching", %{conn: conn} do
    conn = get(conn, ~p"/settings/error-diagnostics")
    assert response(conn, 200)
    assert get_resp_header(conn, "content-type") == ["application/json"]
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "attachment"
    assert disposition =~ "handbean-error-diagnostics.json"
    assert %{"schema_version" => 1, "errors" => []} = Handbean.JSON.decode!(conn.resp_body)
  end

  test "invalid filters show a useful error on settings", %{conn: conn} do
    conn = get(conn, ~p"/settings/error-diagnostics?range=invalid")
    assert redirected_to(conn) == "/settings?tab=local_webgpu"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "valid diagnostic"
  end

  test "database failures return a clear settings error without exception details", %{conn: conn} do
    Ecto.Adapters.SQL.query!(
      Handbean.Repo,
      "ALTER TABLE error_tracker_occurrences RENAME TO fixture_unavailable_occurrences"
    )

    conn = get(conn, ~p"/settings/error-diagnostics")
    assert redirected_to(conn) == "/settings?tab=local_webgpu"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Could not export error diagnostics"
    refute conn.resp_body =~ "fixture_unavailable"
  end

  test "local endpoint rejects non-loopback clients", %{conn: conn} do
    previous = Application.get_env(:handbean, :access)
    Application.put_env(:handbean, :access, mode: :local)
    on_exit(fn -> Application.put_env(:handbean, :access, previous) end)
    conn = %{conn | remote_ip: {192, 0, 2, 1}} |> get(~p"/settings/error-diagnostics")
    assert response(conn, 403)
    refute conn.resp_body =~ "schema_version"
  end

  @tag :unauthenticated
  test "password mode requires authentication and permits the authenticated user", %{conn: conn} do
    previous = Application.get_env(:handbean, :access)

    Application.put_env(:handbean, :access,
      mode: :password,
      username: "fixture",
      password: "fixture-password"
    )

    on_exit(fn -> Application.put_env(:handbean, :access, previous) end)
    assert conn |> get(~p"/settings/error-diagnostics") |> response(401)
    authenticated = conn |> authenticate() |> get(~p"/settings/error-diagnostics")
    assert response(authenticated, 200)
  end
end
