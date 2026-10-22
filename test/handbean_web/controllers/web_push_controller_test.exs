defmodule HandbeanWeb.WebPushControllerTest do
  use HandbeanWeb.ConnCase, async: false

  alias Handbean.Repo
  alias Handbean.WebPush
  alias Handbean.WebPush.Protocol
  alias Handbean.WebPush.Subscription

  setup do
    previous = Application.get_env(:handbean, :web_push)
    previous_access = Application.get_env(:handbean, :access)

    Application.put_env(:handbean, :web_push,
      subject: "mailto:push@example.com",
      dispatch: false,
      req_options: [plug: {Req.Test, __MODULE__}]
    )

    on_exit(fn ->
      Application.put_env(:handbean, :web_push, previous)
      Application.put_env(:handbean, :access, previous_access)
    end)

    :ok
  end

  test "config persists browser identity, exposes only the public key, and resolves UI locale", %{
    conn: conn
  } do
    :ok = Handbean.Settings.UI.save_locale("zh_CN")
    first = get(conn, "/api/web-push/config")

    assert %{"configured" => true, "public_key" => public, "locale" => "zh_CN"} =
             json_response(first, 200)

    assert is_binary(public)
    refute first.resp_body =~ "private_key"
    assert get_resp_header(first, "cache-control") == ["no-store"]
    identity = get_session(first, "handbean_push_client")
    assert is_binary(identity)
    next = first |> recycle() |> get("/api/web-push/config")
    assert get_session(next, "handbean_push_client") == identity
    assert json_response(next, 200)["public_key"] == public
  end

  test "unconfigured service is explicit and does not generate a key", %{conn: conn} do
    Application.put_env(:handbean, :web_push, dispatch: false)

    assert %{"configured" => false, "public_key" => nil} =
             json_response(get(conn, "/api/web-push/config"), 200)

    assert Repo.aggregate(Handbean.WebPush.Keys, :count) == 0
  end

  test "subscribe, test, and unsubscribe use the authenticated browser identity", %{conn: conn} do
    {conn, token} = browser(conn)
    subscription = subscription()

    created =
      request(conn, token, :post, "/api/web-push/subscription", %{
        subscription: subscription,
        locale: "en"
      })

    assert json_response(created, 200) == %{"ok" => true}
    [saved] = WebPush.subscriptions()
    assert saved.client_id == get_session(conn, "handbean_push_client")

    Req.Test.stub(__MODULE__, fn push_conn ->
      assert push_conn.request_path == "/fcm/send/controller"
      assert get_req_header(push_conn, "content-type") == ["application/octet-stream"]
      assert ["vapid " <> _] = get_req_header(push_conn, "authorization")
      send_resp(push_conn, 201, "")
    end)

    assert json_response(
             request(conn, token, :post, "/api/web-push/test", %{
               endpoint: subscription["endpoint"]
             }),
             200
           ) == %{"ok" => true}

    assert json_response(
             request(conn, token, :delete, "/api/web-push/subscription", %{
               endpoint: subscription["endpoint"]
             }),
             200
           ) == %{"ok" => true}

    assert WebPush.subscriptions() == []
  end

  test "another browser cannot take over, test, or remove an enrolled endpoint", %{conn: conn} do
    {owner, owner_token} = browser(conn)
    {other, other_token} = browser(build_conn() |> Map.put(:host, "localhost"))
    subscription = subscription()

    assert json_response(
             request(owner, owner_token, :post, "/api/web-push/subscription", %{
               subscription: subscription
             }),
             200
           )["ok"]

    assert json_response(
             request(other, other_token, :post, "/api/web-push/subscription", %{
               subscription: subscription
             }),
             409
           )["error"] == "subscription_conflict"

    assert json_response(
             request(other, other_token, :post, "/api/web-push/test", %{
               endpoint: subscription["endpoint"]
             }),
             410
           )["error"] == "subscription_expired"

    assert json_response(
             request(other, other_token, :delete, "/api/web-push/subscription", %{
               endpoint: subscription["endpoint"]
             }),
             200
           )["ok"]

    assert [_] = WebPush.subscriptions()
  end

  test "all mutation routes reject missing CSRF tokens", %{conn: conn} do
    {conn, _token} = browser(conn)

    for {method, path, body} <- [
          {:post, "/api/web-push/subscription", %{subscription: subscription()}},
          {:delete, "/api/web-push/subscription",
           %{endpoint: "https://fcm.googleapis.com/fcm/send/controller"}},
          {:post, "/api/web-push/test",
           %{endpoint: "https://fcm.googleapis.com/fcm/send/controller"}}
        ] do
      assert_error_sent 403, fn -> request(conn, nil, method, path, body) end
    end

    assert Repo.aggregate(Subscription, :count) == 0
  end

  test "password access protects configuration, worker and mutations before any enrollment", %{
    conn: conn
  } do
    Application.put_env(:handbean, :access,
      mode: :password,
      username: "tester",
      password: "test-only-password"
    )

    assert response(get(conn, "/api/web-push/config"), 401)
    assert response(get(recycle(conn), "/sw.js"), 401)

    assert response(
             post(recycle(conn), "/api/web-push/subscription", %{subscription: subscription()}),
             401
           )

    assert Repo.aggregate(Subscription, :count) == 0
  end

  test "invalid endpoints return a bounded error without sending a request", %{conn: conn} do
    {conn, token} = browser(conn)
    bad = Map.put(subscription(), "endpoint", "http://127.0.0.1/admin")
    result = request(conn, token, :post, "/api/web-push/subscription", %{subscription: bad})
    assert json_response(result, 422) == %{"error" => "invalid_subscription"}
    assert WebPush.subscriptions() == []
  end

  test "provider rejection does not report test notification success", %{conn: conn} do
    {conn, token} = browser(conn)
    subscription = subscription()
    request(conn, token, :post, "/api/web-push/subscription", %{subscription: subscription})
    Req.Test.stub(__MODULE__, &send_resp(&1, 503, "temporary"))

    result =
      request(conn, token, :post, "/api/web-push/test", %{endpoint: subscription["endpoint"]})

    assert json_response(result, 503) == %{"error" => "delivery_failed"}
  end

  test "service worker is served at root with an update-safe cache policy", %{conn: conn} do
    result = conn |> put_private(:plug_skip_csrf_protection, false) |> get("/sw.js")
    assert response(result, 200) =~ "notificationclick"
    assert get_resp_header(result, "content-type") == ["application/javascript; charset=utf-8"]
    assert get_resp_header(result, "cache-control") == ["no-store"]
    assert get_resp_header(result, "service-worker-allowed") == ["/"]
  end

  defp browser(conn) do
    page = conn |> authenticate() |> get("/settings?tab=ui")

    [token] =
      page.resp_body
      |> Floki.parse_document!()
      |> Floki.attribute("meta[name='csrf-token']", "content")

    config = page |> recycle() |> get("/api/web-push/config")
    {config, token}
  end

  defp request(conn, token, method, path, body) do
    conn =
      conn
      |> recycle()
      |> put_private(:plug_skip_csrf_protection, false)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json")

    conn =
      if token,
        do: put_req_header(conn, "x-csrf-token", token),
        else: delete_req_header(conn, "x-csrf-token")

    dispatch(conn, @endpoint, method, path, Handbean.JSON.encode!(body))
  end

  defp subscription do
    %{
      "endpoint" => "https://fcm.googleapis.com/fcm/send/controller",
      "keys" => %{
        "p256dh" => Protocol.generate_key_pair().public_key,
        "auth" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
      }
    }
  end
end
