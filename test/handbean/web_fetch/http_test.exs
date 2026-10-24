defmodule Handbean.WebFetch.HTTPTest do
  use ExUnit.Case, async: true

  alias Handbean.WebFetch.HTTP

  test "proxy mode dials the proxy with the origin hostname, not a fake-ip token" do
    {port, server} =
      serve(fn socket, _request ->
        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\nhello"
        )
      end)

    uri = URI.parse("http://docs.example/guide?q=1")

    assert {:ok, %{status: 200, body: "hello"}} =
             HTTP.get(
               uri,
               {:proxy,
                {:http, "127.0.0.1", port,
                 [proxy_headers: [{"proxy-authorization", "Basic dGVzdA=="}]]}},
               deadline()
             )

    assert_receive {:request, ^server, request}
    assert request =~ "docs.example"
    assert request =~ "/guide?q=1"
    assert request =~ "proxy-authorization: Basic dGVzdA==\r\n"
    refute request =~ "198.18"
  end

  test "connects to supplied IP with original Host, path/query and no cookies" do
    {port, server} =
      serve(fn socket, _request ->
        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\nhello"
        )
      end)

    uri = URI.parse("http://never-resolve.invalid:#{port}/guide?q=2")
    assert {:ok, %{status: 200, body: "hello"}} = HTTP.get(uri, {127, 0, 0, 1}, deadline())
    assert_receive {:request, ^server, request}
    assert request =~ "GET /guide?q=2 HTTP/1.1\r\n"
    assert request =~ "host: never-resolve.invalid:#{port}\r\n"
    assert request =~ "accept-encoding: identity\r\n"
    assert request =~ "application/pdf"
    assert request =~ "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    assert request =~ "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    assert request =~ "application/vnd.openxmlformats-officedocument.presentationml.presentation"
    refute String.downcase(request) =~ "cookie:"
    assert_receive {:closed, ^server, {:error, :closed}}
  end

  test "discards informational headers and reads the final response" do
    {port, _} =
      serve(fn socket, _ ->
        :gen_tcp.send(socket, [
          "HTTP/1.1 100 Continue\r\n\r\n",
          "HTTP/1.1 103 Early Hints\r\nLink: </style.css>; rel=preload\r\n\r\n",
          "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\nOK"
        ])
      end)

    assert {:ok, %{status: 200, body: "OK", headers: headers}} = get(port)
    assert {"content-type", "text/plain"} in headers
    refute List.keymember?(headers, "link", 0)
  end

  test "informational response without a final response still times out" do
    {port, server} =
      serve(fn socket, _ ->
        :gen_tcp.send(socket, "HTTP/1.1 103 Early Hints\r\n\r\n")
      end)

    assert {:error, _} =
             HTTP.get(URI.parse("http://docs.test:#{port}"), {127, 0, 0, 1}, deadline(100))

    assert_receive {:closed, ^server, {:error, :closed}}
  end

  test "rejects advertised and streamed bodies over 1 MiB" do
    {port, _} =
      serve(fn socket, _ ->
        :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 1048577\r\n\r\n")
      end)

    assert {:error, "Response exceeds 1 MiB limit"} = get(port)

    {port, _} =
      serve(fn socket, _ ->
        :gen_tcp.send(socket, [
          "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n100001\r\n",
          String.duplicate("a", 1_048_577),
          "\r\n0\r\n\r\n"
        ])
      end)

    assert {:error, "Response exceeds 1 MiB limit"} = get(port)
  end

  test "accepts exactly 1 MiB and rejects compressed bodies without inflating" do
    {port, _} =
      serve(fn socket, _ ->
        :gen_tcp.send(socket, [
          "HTTP/1.1 200 OK\r\nContent-Length: 1048576\r\n\r\n",
          String.duplicate("a", 1_048_576)
        ])
      end)

    assert {:ok, %{body: body}} = get(port)
    assert byte_size(body) == 1_048_576

    {port, _} =
      serve(fn socket, _ ->
        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 999999\r\n\r\n"
        )
      end)

    assert {:error, "Compressed responses are not supported"} = get(port)
  end

  test "header limits, incomplete responses, and deadlines fail closed" do
    {port, _} =
      serve(fn socket, _ ->
        :gen_tcp.send(socket, ["HTTP/1.1 200 OK\r\nX-Large: ", String.duplicate("x", 17_000)])
      end)

    assert {:error, _} = get(port)

    {port, _} =
      serve(fn socket, _ ->
        :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\nshort")
        :gen_tcp.shutdown(socket, :write)
      end)

    assert {:error, _} = get(port)

    {port, server} = serve(fn _socket, _ -> :ok end)

    assert {:error, _} =
             HTTP.get(URI.parse("http://docs.test:#{port}"), {127, 0, 0, 1}, deadline(100))

    assert_receive {:closed, ^server, {:error, :closed}}

    assert {:error, "Fetch deadline exceeded"} =
             HTTP.get(URI.parse("http://docs.test:#{port}"), {127, 0, 0, 1}, deadline(-1))
  end

  test "redirect returns headers without following or waiting for response body" do
    {port, server} =
      serve(fn socket, _ ->
        :gen_tcp.send(
          socket,
          "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1/private\r\nContent-Length: 100\r\n\r\n"
        )
      end)

    assert {:ok, %{status: 302, body: "", headers: headers}} = get(port)
    assert {"location", "http://127.0.0.1/private"} in headers
    assert_receive {:closed, ^server, {:error, :closed}}
  end

  test "socket owner death closes an in-flight connection" do
    {port, server} = serve(fn _, _ -> :ok end)
    worker = spawn(fn -> get(port) end)
    assert_receive {:request, ^server, _}, 1_000
    monitor = Process.monitor(worker)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
    assert_receive {:closed, ^server, {:error, :closed}}, 1_000
  end

  defp get(port), do: HTTP.get(URI.parse("http://docs.test:#{port}"), {127, 0, 0, 1}, deadline())
  defp deadline(ms \\ 3_000), do: System.monotonic_time(:millisecond) + ms

  # Test the internal transport with loopback; public-address policy is never
  # disabled on the tool. Each fixture serves one request and observes cleanup.
  defp serve(respond) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, {_, port}} = :inet.sockname(listener)
    parent = self()

    server =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 5_000)
        request = receive_headers(socket, "")
        send(parent, {:request, self(), request})
        respond.(socket, request)
        send(parent, {:closed, self(), :gen_tcp.recv(socket, 0, 5_000)})
        :gen_tcp.close(socket)
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      if Process.alive?(server), do: Process.exit(server, :kill)
    end)

    {port, server}
  end

  defp receive_headers(socket, buffer) do
    if String.contains?(buffer, "\r\n\r\n") do
      buffer
    else
      {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
      receive_headers(socket, buffer <> data)
    end
  end
end
