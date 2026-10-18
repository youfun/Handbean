defmodule HandbeanWeb.PreviewControllerTest do
  use HandbeanWeb.ConnCase, async: false

  alias Handbean.Preview

  setup do
    root =
      Path.join(System.tmp_dir!(), "handbean-preview-http-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    File.write!(Path.join(root, "index.html"), "<h1 id=\"gen\">generated</h1>")
    File.write!(Path.join(root, "ok.txt"), "static-ok")

    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "shell is a trusted page with sandboxed iframe", %{conn: conn, root: root} do
    {:ok, record} = Preview.register_files("conv-http", root, title: "Demo")
    conn = get(conn, "/preview/#{record.id}")
    assert html_response(conn, 200) =~ "返回聊天"
    assert html_response(conn, 200) =~ ~s(sandbox="allow-scripts")
    assert html_response(conn, 200) =~ "/preview/#{record.id}/files/index.html"
    refute html_response(conn, 200) =~ "allow-same-origin"
    assert html_response(conn, 200) =~ "handbean://c/conv-http"
  end

  test "files responses carry CSP sandbox and reject traversal", %{conn: conn, root: root} do
    {:ok, record} = Preview.register_files("conv-http", root)
    conn = get(conn, "/preview/#{record.id}/files/ok.txt")
    assert response(conn, 200) == "static-ok"
    assert Plug.Conn.get_resp_header(conn, "content-security-policy") == ["sandbox allow-scripts"]

    conn = recycle(conn)
    conn = get(conn, "/preview/#{record.id}/files/../secret.txt")
    assert response(conn, 404) =~ "not found"
  end

  test "closed preview URL is explicit", %{conn: conn, root: root} do
    {:ok, record} = Preview.register_files("conv-http", root)
    {:ok, _} = Preview.close(record.id)
    conn = get(conn, "/preview/#{record.id}")
    assert response(conn, 410) =~ "closed"
  end

  test "port proxy does not forward workbench cookies", %{conn: conn} do
    bypass = start_loopback!()
    {:ok, record} = Preview.register_port("conv-http", bypass.port)

    conn =
      conn
      |> put_req_header("cookie", "_handbean_key=secret")
      |> get("/preview/#{record.id}/port/hello")

    assert response(conn, 200) == "proxied"

    refute Enum.any?(
             Plug.Conn.get_resp_header(conn, "set-cookie"),
             &String.contains?(&1, "sid=should-not-leak")
           )

    assert Plug.Conn.get_resp_header(conn, "content-security-policy") == ["sandbox allow-scripts"]
  end

  test "port proxy rewrites loopback redirects into PreviewShell", %{conn: conn} do
    bypass = start_loopback!()
    {:ok, record} = Preview.register_port("conv-http", bypass.port)

    conn = get(conn, "/preview/#{record.id}/port/local-redirect")

    assert response(conn, 302) == "local"

    assert Plug.Conn.get_resp_header(conn, "location") == [
             "/preview/#{record.id}/port/target?from=preview"
           ]
  end

  test "port proxy rejects external redirects without leaking Location", %{conn: conn} do
    bypass = start_loopback!()
    {:ok, record} = Preview.register_port("conv-http", bypass.port)

    conn = get(conn, "/preview/#{record.id}/port/external-redirect")

    assert response(conn, 502) =~ "redirected outside"
    assert Plug.Conn.get_resp_header(conn, "location") == []
  end

  defp start_loopback! do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    :ok = :gen_tcp.close(listen)

    {:ok, pid} =
      Bandit.start_link(
        plug: {HandbeanWeb.PreviewControllerTest.Upstream, []},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: port,
        thousand_island_options: [num_acceptors: 1]
      )

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    %{port: port}
  end
end

defmodule HandbeanWeb.PreviewControllerTest.Upstream do
  def init(opts), do: opts

  def call(%Plug.Conn{request_path: "/local-redirect"} = conn, _opts) do
    conn
    |> Plug.Conn.put_resp_header("location", "/target?from=preview")
    |> Plug.Conn.send_resp(302, "local")
  end

  def call(%Plug.Conn{request_path: "/external-redirect"} = conn, _opts) do
    conn
    |> Plug.Conn.put_resp_header("location", "https://example.com/escaped")
    |> Plug.Conn.send_resp(302, "external")
  end

  def call(conn, _opts) do
    cookie = Plug.Conn.get_req_header(conn, "cookie")

    conn
    |> Plug.Conn.put_resp_header("set-cookie", "sid=should-not-leak")
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.send_resp(200, if(cookie == [], do: "proxied", else: "leaked-cookie"))
  end
end
