defmodule HandbeanWeb.AccessTest do
  use HandbeanWeb.ConnCase, async: false

  @moduletag :unauthenticated

  setup do
    old = Application.get_env(:handbean, :access)

    Application.put_env(:handbean, :access,
      mode: :password,
      username: "owner",
      password: "correct horse battery staple"
    )

    on_exit(fn ->
      if old,
        do: Application.put_env(:handbean, :access, old),
        else: Application.delete_env(:handbean, :access)
    end)

    :ok
  end

  test "actual browser route is fail-closed and forged proxy headers do not bypass it", %{
    conn: conn
  } do
    conn =
      conn
      |> put_req_header("x-forwarded-for", "127.0.0.1")
      |> put_req_header("x-real-ip", "127.0.0.1")
      |> get("/")

    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") != []
  end

  test "credentials permit browser and privileged controller routes", %{conn: conn} do
    authorization = "Basic " <> Base.encode64("owner:correct horse battery staple")

    assert conn |> put_req_header("authorization", authorization) |> get("/") |> response(200)

    # The preview controller may return not-found, but must pass the access
    # boundary rather than return its 401 challenge.
    privileged =
      build_conn()
      |> put_req_header("authorization", authorization)
      |> get("/preview/not-present")

    refute privileged.status == 401
  end

  test "direct LiveView websocket and longpoll transport requests are protected", %{conn: conn} do
    websocket =
      conn
      |> put_req_header("connection", "upgrade")
      |> put_req_header("upgrade", "websocket")
      |> put_req_header("x-forwarded-for", "127.0.0.1")
      |> get("/live/websocket?vsn=2.0.0")

    assert websocket.status in [401, 403]

    longpoll = build_conn() |> post("/live/longpoll?vsn=2.0.0", %{})
    # Phoenix longpoll reports transport rejection in its JSON envelope.
    assert longpoll.status == 200
    assert Jason.decode!(longpoll.resp_body) == %{"status" => 410}
  end

  test "password rotation invalidates the signed authenticated session", %{conn: conn} do
    authorization = "Basic " <> Base.encode64("owner:correct horse battery staple")

    authenticated =
      conn
      |> put_req_header("authorization", authorization)
      |> get("/")

    assert authenticated.status == 200

    Application.put_env(:handbean, :access,
      mode: :password,
      username: "owner",
      password: "rotated password"
    )

    stale_session =
      authenticated
      |> recycle()
      |> delete_req_header("authorization")
      |> get("/")

    assert stale_session.status == 401
  end

  test "invalid mode rejects HTTP and socket connections", %{conn: conn} do
    Application.put_env(:handbean, :access, mode: :misspelled)

    assert conn |> get("/") |> response(503)

    assert :error =
             HandbeanWeb.LiveSocket.connect(%{}, %Phoenix.Socket{}, %{
               session: %{},
               peer_data: %{address: {127, 0, 0, 1}},
               uri: URI.parse("http://localhost/live/websocket")
             })
  end

  test "local mode requires a loopback peer, local Host, and same Origin", %{conn: conn} do
    Application.put_env(:handbean, :access, mode: :local)

    assert conn |> Map.put(:host, "localhost") |> get("/") |> response(200)

    assert conn
           |> Map.put(:host, "localhost")
           |> Map.put(:remote_ip, {192, 0, 2, 10})
           |> Plug.Test.put_peer_data(%{address: {192, 0, 2, 10}, port: 12_345, ssl_cert: nil})
           |> get("/")
           |> response(403)

    assert conn |> Map.put(:host, "evil.example") |> get("/") |> response(403)

    assert conn
           |> Map.put(:host, "localhost")
           |> put_req_header("origin", "http://evil.example")
           |> get("/")
           |> response(403)
  end

  test "local mode rejects a remote LiveView transport request" do
    Application.put_env(:handbean, :access, mode: :local)

    websocket =
      build_conn()
      |> Map.put(:host, "localhost")
      |> Map.put(:remote_ip, {192, 0, 2, 10})
      |> Plug.Test.put_peer_data(%{address: {192, 0, 2, 10}, port: 12_345, ssl_cert: nil})
      |> put_req_header("connection", "upgrade")
      |> put_req_header("upgrade", "websocket")
      |> get("/live/websocket?vsn=2.0.0")

    assert websocket.status in [403, 401]
  end

  test "LAN HTTP opt-in skips the production HTTPS redirect but not authentication" do
    endpoint = HandbeanWeb.Endpoint
    original = Application.fetch_env!(:handbean, endpoint)
    on_exit(fn -> endpoint.config_change([{endpoint, original}], []) end)

    ssl_options =
      Config.Reader.read!(Path.expand("../../config/prod.exs", __DIR__), env: :prod)
      |> get_in([:handbean, endpoint, :force_ssl])
      |> Plug.SSL.init()

    remote_request = fn ->
      Plug.Test.conn(:get, "http://192.0.2.10:5008/")
      |> Map.put(:remote_ip, {192, 0, 2, 20})
      |> Plug.Test.put_peer_data(%{address: {192, 0, 2, 20}, port: 12_345, ssl_cert: nil})
    end

    assert remote_request.() |> Plug.SSL.call(ssl_options) |> Map.fetch!(:status) == 301

    assert remote_request.()
           |> Map.put(:host, "localhost")
           |> Plug.SSL.call(ssl_options)
           |> Map.fetch!(:status) == 301

    assert remote_request.()
           |> put_req_header("x-forwarded-proto", "https")
           |> Plug.SSL.call(ssl_options)
           |> Map.fetch!(:status) == 301

    loopback = Plug.Test.conn(:get, "http://localhost:5008/") |> Plug.SSL.call(ssl_options)
    refute loopback.halted

    endpoint.config_change([{endpoint, Keyword.put(original, :allow_http, true)}], [])

    conn = remote_request.() |> Plug.SSL.call(ssl_options)
    refute conn.halted

    conn = conn |> Plug.Test.init_test_session(%{}) |> HandbeanWeb.Access.call([])
    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") != []
  end
end
