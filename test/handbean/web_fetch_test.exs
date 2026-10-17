defmodule Handbean.WebFetchTest do
  use ExUnit.Case, async: true

  alias Handbean.WebFetch
  alias Handbean.WebFetch.{Address, Document}

  test "rejects non-public IPv4/IPv6, disguised loopback and mixed DNS answers" do
    for ip <- ~w(0.1.2.3 10.1.2.3 100.64.0.1 100.127.255.255 127.0.0.1
                 169.254.169.254 172.16.0.1 172.31.255.255 192.168.0.1 192.0.0.8
                 198.19.255.255 192.0.2.1 198.51.100.4 203.0.113.9 224.0.0.1 255.255.255.255
                 :: ::1 ::ffff:8.8.8.8 64:ff9b::808:808 fc00::1 fe80::1 ff02::1
                 2001::1 2001:db8::1 2002:0808:0808::1 3fff::1) do
      {:ok, address} = :inet.parse_address(String.to_charlist(ip))
      refute Address.public?(address), ip
    end

    for ip <- ~w(8.8.8.8 100.63.255.255 100.128.0.0 172.15.255.255 172.32.0.0
                 198.17.255.255 198.20.0.0 223.255.255.255 2606:4700:4700::1111) do
      {:ok, address} = :inet.parse_address(String.to_charlist(ip))
      assert Address.public?(address), ip
    end

    assert {:error, _} = Address.select_public([{8, 8, 8, 8}, {127, 0, 0, 1}])
    assert {:error, _} = Address.select_public([])

    for url <- ["http://127.1/", "http://2130706433/", "http://0x7f000001/", "http://[::1]/"] do
      assert {:error, _} = WebFetch.fetch(url)
    end
  end

  test "validates URL and output size before any resolver or request is invoked" do
    no_resolve = fn _, _ -> flunk("invalid input reached DNS") end

    for url <- [
          "file:///etc/passwd",
          "ftp://example.com",
          "http://user:secret@example.com",
          "http://example.com:0",
          "http://example.com:65536",
          "http://example.com/\r\nx:y",
          "http://example.com\\@127.0.0.1",
          "http://",
          nil,
          <<255>>
        ] do
      assert {:error, _} = WebFetch.fetch(url, 100, resolve: no_resolve)
    end

    for limit <- [0, -1, 50_001, "20", nil] do
      assert {:error, _} = WebFetch.fetch("https://example.com", limit, resolve: no_resolve)
    end
  end

  test "relative redirects re-resolve and pin each destination; sources remain visible" do
    resolve = fn host, _ ->
      send(self(), {:resolved, host})
      {:ok, [{93, 184, 215, 14}]}
    end

    request = fn uri, ip, _ ->
      assert ip == {93, 184, 215, 14}
      assert uri.host == "docs.example"

      case uri.path do
        "/start" -> {:ok, %{status: 302, headers: [{"location", "/guide#heading"}], body: ""}}
        "/guide" -> {:ok, %{status: 200, headers: [{"content-type", "text/plain"}], body: "你好世界"}}
      end
    end

    assert {:ok, result} =
             WebFetch.fetch("https://docs.example/start", 3, resolve: resolve, request: request)

    assert result.requested_url == "https://docs.example/start"
    assert result.final_url == "https://docs.example/guide"
    assert result.content == "你好世"
    assert result.truncated
    assert {:ok, _, 0} = DateTime.from_iso8601(result.fetched_at)
    assert_received {:resolved, "docs.example"}
    assert_received {:resolved, "docs.example"}
  end

  test "same hostname changing to private DNS on redirect never reaches transport" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    on_exit(fn -> if Process.alive?(counter), do: Agent.stop(counter) end)

    resolve = fn _, _ ->
      case Agent.get_and_update(counter, &{&1, &1 + 1}) do
        0 -> {:ok, [{8, 8, 8, 8}]}
        1 -> {:ok, [{10, 0, 0, 1}]}
      end
    end

    request = fn _, ip, _ ->
      assert ip == {8, 8, 8, 8}
      {:ok, %{status: 302, headers: [{"location", "/next"}], body: ""}}
    end

    assert {:error, reason} =
             WebFetch.fetch("http://example.test/start", 100, resolve: resolve, request: request)

    assert reason =~ "public"
    assert Agent.get(counter, & &1) == 2
  end

  test "rejects unsafe redirect schemes and bounded redirect loops" do
    resolve = fn _, _ -> {:ok, [{8, 8, 8, 8}]} end

    for location <- ["file:///etc/passwd", "https://name:secret@example.com/"] do
      request = fn _, _, _ ->
        {:ok, %{status: 302, headers: [{"location", location}], body: ""}}
      end

      assert {:error, "Invalid redirect destination"} =
               WebFetch.fetch("http://example.test", 100, resolve: resolve, request: request)
    end

    request = fn _, _, _ ->
      send(self(), :requested)
      {:ok, %{status: 302, headers: [{"location", "/loop"}], body: ""}}
    end

    assert {:error, "Too many redirects (maximum 3)"} =
             WebFetch.fetch("http://example.test", 100, resolve: resolve, request: request)

    for _ <- 1..4, do: assert_received(:requested)
    refute_received :requested
  end

  test "HTML extracts main text, code indentation, entities and relative links without scripts" do
    html = """
    <!doctype html><html><head><title>文档 &amp; API</title><style>hidden CSS</style></head>
    <body><nav>navigation noise</nav><main><h1>Read API</h1>
    <p>Hello <b>world</b> &amp; 中文</p><a href="../reference?q=1">Details</a>
    <a href="javascript:alert(1)">not executable</a>
    <pre><code>if ready do\n  call(&quot;```&quot;)\nend</code></pre>
    <script>maliciousScript()</script><div hidden>secret menu</div></main><footer>outside main</footer></body></html>
    """

    assert {:ok, result} =
             Document.extract(
               html,
               [{"content-type", "text/html; charset=utf-8"}],
               URI.parse("https://docs.example/guide/page"),
               10_000
             )

    assert result.title == "文档 & API"
    assert result.content =~ "Hello world & 中文"
    assert result.content =~ "Details (https://docs.example/reference?q=1)"
    assert result.content =~ "````\nif ready do\n  call(\"```\")\nend\n````"

    for noise <- [
          "navigation noise",
          "maliciousScript",
          "secret menu",
          "outside main",
          "javascript:"
        ],
        do: refute(result.content =~ noise)

    refute result.truncated
  end

  test "highlighted code preserves whitespace between spans and entity escaping" do
    html = """
    <title>Literal &amp;lt;</title><main>
    <pre><code><span>fn</span> <span>x</span> <span>-&gt;</span>\n  <span>x</span> <span>*</span> <span>2</span>\n<span>end</span></code></pre>
    <p><b>one</b> <b>two</b> &amp;lt;</p>
    <a href="/path?q=a&amp;x=1" title='> <'>quoted link</a>
    </main>
    """

    assert {:ok, result} =
             Document.extract(
               html,
               [{"content-type", "text/html"}],
               URI.parse("https://example.com"),
               10_000
             )

    assert result.title == "Literal &lt;"
    assert result.content =~ "fn x ->\n  x * 2\nend"
    assert result.content =~ "one two &lt;"
    assert result.content =~ "https://example.com/path?q=a&x=1"
  end

  test "plain text preserves whitespace, charset handling and exact truncation boundary" do
    assert {:ok, result} = Document.extract(" a\n  b", [{"content-type", "text/plain"}], nil, 6)
    assert result.content == " a\n  b"
    refute result.truncated

    assert {:ok, result} =
             Document.extract(
               <<99, 97, 102, 233>>,
               [{"content-type", "text/plain; charset=ISO-8859-1"}],
               nil,
               4
             )

    assert result.content == "café"
    refute result.truncated
    assert {:error, _} = Document.extract(<<255>>, [{"content-type", "text/plain"}], nil, 100)

    assert {:error, _} =
             Document.extract("x", [{"content-type", "text/plain; charset=gbk"}], nil, 100)

    assert {:error, _} = Document.extract("%PDF", [{"content-type", "application/pdf"}], nil, 100)
    assert {:error, _} = Document.extract("missing type", [], nil, 100)
  end
end
