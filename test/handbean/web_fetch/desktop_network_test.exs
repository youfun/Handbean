defmodule Handbean.WebFetch.DesktopNetworkTest do
  use ExUnit.Case, async: true

  # Failure list. 198.18.0.0/15 is not a public destination.
  # 1. Hostname answers are only 198.18/15 and takeover is :none → error, no dial.
  # 2. The same answers with takeover :tun → dial that token, not a rewritten public IP.
  # 3. The same answers with a system HTTP proxy and no TUN → dial {:proxy, ...}
  #    with the hostname. The token is not the dial target.
  # 4. Literal 198.18/15, loopback, private and metadata hosts stay rejected
  #    even when takeover is :tun. A lying resolver cannot launder them.
  # 5. A redirect to a private host or literal is rejected and not dialed.
  # 6. Mixed fake-ip and public, or fake-ip and private, is rejected.
  # 7. Public answers stay pinned and do not consult takeover.
  # 8. A default or physical route is not TUN ownership. A /15 via utun is.
  #    An HTTP(S) proxy URL is a proxy. socks5:// is not.
  # 9. A resolver that returns only 198.18/15 for an unrelated name is Fake-IP
  #    and may dial the token. A public, mixed, empty, or failed canary is not.

  alias Handbean.WebFetch
  alias Handbean.WebFetch.Address
  alias Handbean.WebFetch.Desktop.{Proxy, Route}

  @desktop [network: Handbean.WebFetch.Desktop]

  test "fake-ip tokens are not public and are dialed only when the tun owns them" do
    {:ok, token} = :inet.parse_address(~c"198.18.4.5")
    refute Address.public?(token)
    assert Address.fake_ip?(token)
    {:ok, edge} = :inet.parse_address(~c"198.19.255.255")
    assert Address.fake_ip?(edge)
    {:ok, outside} = :inet.parse_address(~c"198.20.0.0")
    refute Address.fake_ip?(outside)

    assert {:error, reason} =
             fetch("https://docs.example/start", {:ok, [token]}, fn _ -> :none end, fn _, _, _ ->
               flunk("unconfirmed fake-ip was dialed")
             end)

    assert reason =~ "public"

    assert {:ok, %{content: "tun"}} =
             fetch("https://docs.example/start", {:ok, [token]}, fn _ -> :tun end, fn uri,
                                                                                      ip,
                                                                                      _ ->
               assert uri.host == "docs.example"
               assert ip == token
               {:ok, %{status: 200, headers: [{"content-type", "text/plain"}], body: "tun"}}
             end)
  end

  test "a system proxy carries the hostname and does not dial the fake-ip token" do
    token = {198, 18, 1, 9}
    proxy = {:http, "127.0.0.1", 7890, []}

    assert {:ok, %{content: "proxied"}} =
             fetch("https://docs.example/a", {:ok, [token]}, fn _ -> {:proxy, proxy} end, fn uri,
                                                                                             target,
                                                                                             _ ->
               assert target == {:proxy, proxy}
               assert uri.host == "docs.example"
               {:ok, %{status: 200, headers: [{"content-type", "text/plain"}], body: "proxied"}}
             end)
  end

  test "literals and mixed answers stay blocked, and public answers stay pinned" do
    takeover = fn _ -> flunk("takeover consulted for a non-fake-ip destination") end

    request = fn _, _, _ -> flunk("blocked destination was dialed") end

    for url <- [
          "http://198.18.0.5/token",
          "http://127.0.0.1/",
          "http://10.1.2.3/a",
          "http://169.254.169.254/",
          "http://[::1]/"
        ] do
      assert {:error, _} =
               WebFetch.fetch(
                 url,
                 100,
                 @desktop ++
                   [resolve: lying_public(), takeover: fn _ -> :tun end, request: request]
               )
    end

    assert {:error, _} =
             fetch(
               "https://docs.example/",
               {:ok, [{198, 18, 0, 2}, {8, 8, 8, 8}]},
               fn _ -> :tun end,
               request
             )

    assert {:error, _} =
             fetch(
               "https://docs.example/",
               {:ok, [{198, 18, 0, 2}, {10, 0, 0, 1}]},
               fn _ -> :tun end,
               request
             )

    assert {:ok, _} =
             fetch("https://docs.example/", {:ok, [{1, 1, 1, 1}, {8, 8, 8, 8}]}, takeover, fn _,
                                                                                              ip,
                                                                                              _ ->
               assert ip == {1, 1, 1, 1}
               {:ok, %{status: 200, headers: [{"content-type", "text/plain"}], body: "pinned"}}
             end)
  end

  test "redirects are checked again and cannot enter a private host" do
    resolve = fn host, _ ->
      case host do
        "docs.example" -> {:ok, [{198, 18, 0, 4}]}
        "next.example" -> {:ok, [{10, 0, 0, 9}]}
      end
    end

    request = fn uri, ip, _ ->
      assert uri.host == "docs.example"
      assert ip == {198, 18, 0, 4}
      {:ok, %{status: 302, headers: [{"location", "https://next.example/secret"}], body: ""}}
    end

    assert {:error, reason} =
             WebFetch.fetch(
               "https://docs.example/start",
               100,
               @desktop ++ [resolve: resolve, takeover: fn _ -> :tun end, request: request]
             )

    assert reason =~ "public"

    request = fn _, _, _ ->
      {:ok, %{status: 302, headers: [{"location", "http://198.18.0.9/"}], body: ""}}
    end

    assert {:error, reason} =
             WebFetch.fetch(
               "https://docs.example/start",
               100,
               @desktop ++
                 [
                   resolve: fn _, _ -> {:ok, [{198, 18, 0, 4}]} end,
                   takeover: fn _ -> :tun end,
                   request: request
                 ]
             )

    assert reason =~ "public"
  end

  test "route and proxy parsers do not treat the benchmarking range as ownership by themselves" do
    refute Route.darwin?("""
           destination: default
                  mask: default
             interface: utun3
           """)

    refute Route.darwin?("""
           destination: 198.18.0.0
                  mask: 255.254.0.0
             interface: en1
           """)

    assert Route.darwin?("""
           destination: 198.18.0.0
                  mask: 255.254.0.0
             interface: utun4
           """)

    refute Route.linux?("default via 10.0.0.1 dev utun0\n")

    assert Route.linux?("198.18.0.0/15 dev utun0 proto static\n")

    refute Route.linux?("""
           198.18.0.0/15 dev utun0
           198.18.0.1 via 10.0.0.1 dev en0
           """)

    assert {:ok, {:http, "127.0.0.1", 7890, []}} = Proxy.parse("http://127.0.0.1:7890")

    assert {:ok,
            {:http, "127.0.0.1", 7890, [proxy_headers: [{"proxy-authorization", "Basic " <> _}]]}} =
             Proxy.parse("http://user:secret@127.0.0.1:7890")

    assert :error = Proxy.parse("socks5://127.0.0.1:7890")
    assert :error = Proxy.parse("http://user:sec\nret@127.0.0.1:7890")

    scutil = """
    HTTPEnable : 1
    HTTPProxy : 127.0.0.1
    HTTPPort : 7890
    HTTPSEnable : 0
    """

    assert {:ok, {:http, "127.0.0.1", 7890, []}} = Proxy.from_scutil(scutil, "https")
    assert {:ok, {:http, "127.0.0.1", 7890, []}} = Proxy.from_scutil(scutil, "http")

    assert Proxy.from_scutil("HTTPEnable : 0\nHTTPSEnable : 0\n", "https") == nil

    assert WebFetch.Desktop.resolver_fake_ip?(fn -> {:ok, [{198, 18, 1, 9}]} end)
    refute WebFetch.Desktop.resolver_fake_ip?(fn -> {:ok, [{1, 1, 1, 1}]} end)
    refute WebFetch.Desktop.resolver_fake_ip?(fn -> {:ok, [{198, 18, 0, 1}, {8, 8, 8, 8}]} end)
    refute WebFetch.Desktop.resolver_fake_ip?(fn -> {:ok, []} end)
    refute WebFetch.Desktop.resolver_fake_ip?(fn -> {:error, :nxdomain} end)
  end

  defp fetch(url, resolved, takeover, request) do
    WebFetch.fetch(
      url,
      100,
      @desktop ++ [resolve: fn _, _ -> resolved end, takeover: takeover, request: request]
    )
  end

  defp lying_public, do: fn _, _ -> {:ok, [{8, 8, 8, 8}]} end
end
