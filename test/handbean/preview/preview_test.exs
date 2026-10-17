defmodule Handbean.PreviewTest do
  use ExUnit.Case, async: false

  alias Handbean.Preview
  alias Handbean.Preview.{Files, Proxy, URL}
  alias Handbean.Tool.Builtin.PreviewServe

  setup do
    root = Path.join(System.tmp_dir!(), "handbean-preview-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "sub"))

    File.write!(
      Path.join(root, "index.html"),
      "<h1>hello</h1><script>window.parent.document.title='x'</script>"
    )

    File.write!(Path.join(root, "sub/ok.txt"), "ok")
    File.ln_s!(Path.join(root, "sub"), Path.join(root, "inside-dir"))

    outside =
      Path.join(
        System.tmp_dir!(),
        "handbean-preview-outside-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secret.txt"), "nope")
    File.ln_s!(Path.join(outside, "secret.txt"), Path.join(root, "escape.txt"))
    File.ln_s!(outside, Path.join(root, "escape-dir"))

    on_exit(fn ->
      File.rm_rf!(root)
      File.rm_rf!(outside)
    end)

    %{root: root, outside: outside}
  end

  test "files resolve stays inside the registered root", %{root: root} do
    {:ok, record} = Preview.register_files("conv-p", root, title: "demo")
    assert {:ok, path} = Files.resolve(record.root, "index.html")
    assert File.read!(path) =~ "hello"
    assert {:ok, internal_link} = Files.resolve(record.root, "inside-dir/ok.txt")
    assert File.read!(internal_link) == "ok"
    assert {:error, :not_found} = Files.resolve(record.root, "../secret.txt")
    assert {:error, :not_found} = Files.resolve(record.root, "escape.txt")
    assert {:error, :not_found} = Files.resolve(record.root, "escape-dir/secret.txt")

    assert {:error, :not_found} =
             Files.resolve(record.root, "sub/../../#{Path.basename(root)}/../secret.txt")
  end

  test "closing a record invalidates later fetches", %{root: root} do
    {:ok, record} = Preview.register_files("conv-p", root)
    assert {:ok, _} = Preview.fetch_open(record.id)
    assert {:ok, _} = Preview.close(record.id)
    assert {:error, :closed} = Preview.fetch_open(record.id)
  end

  test "proxy strips cookies and does not take a page-supplied target" do
    http = fn method, url, headers, _body ->
      send(self(), {:proxied, method, url, headers})
      {:ok, 200, [{"set-cookie", "sid=abc"}, {"content-type", "text/plain"}], "body"}
    end

    assert {:ok, result} =
             Proxy.request(:get, 4011, "/x", http: http, headers: [{"cookie", "lv=1"}])

    assert result.body == "body"
    refute Enum.any?(result.headers, fn {k, _} -> String.downcase(k) == "set-cookie" end)
    assert_received {:proxied, :get, "http://127.0.0.1:4011/x", headers}
    refute Enum.any?(headers, fn {k, _} -> String.downcase(to_string(k)) == "cookie" end)
  end

  test "websocket upgrade is a clear error, not a top-level unwrap" do
    assert {:error, :websocket_unsupported} =
             Proxy.request(:get, 4011, "/", headers: [{"upgrade", "websocket"}])
  end

  test "preview_serve registers files and returns a card payload", %{root: root} do
    assert {:ok, text, details} =
             PreviewServe.execute(
               %{"kind" => "files", "path" => root, "title" => "Demo"},
               %{conversation_id: "conv-card", working_directory: root}
             )

    assert text =~ "Demo"
    assert details.preview_id
    assert details.preview_path == "/preview/#{details.preview_id}"
    assert details.return_href == "handbean://c/conv-card"
  end

  test "shell URL matcher only accepts loopback PreviewShell paths" do
    assert URL.preview_shell?("http://127.0.0.1:4000/preview/pv_1",
             preview_id: "pv_1",
             liveview_port: 4000
           )

    refute URL.preview_shell?("http://127.0.0.1:4000/preview/pv_1/files/index.html",
             preview_id: "pv_1"
           )

    refute URL.preview_shell?("http://example.com/preview/pv_1", preview_id: "pv_1")
    refute URL.preview_shell?("file:///preview/pv_1", preview_id: "pv_1")
    assert {:ok, "abc"} = URL.return_conversation_id("handbean://c/abc")
    assert :error = URL.return_conversation_id("https://evil.example/handbean://c/abc")
  end
end
