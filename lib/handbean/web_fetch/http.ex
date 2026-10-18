defmodule Handbean.WebFetch.HTTP do
  @moduledoc false

  @max_bytes 1_048_576
  @headers [
    {"user-agent", "Handbean/web_fetch"},
    {"accept", "text/html, text/plain, text/markdown, application/xhtml+xml"},
    {"accept-encoding", "identity"},
    {"connection", "close"}
  ]

  # Caller validates the destination. A tuple address is pinned. `{:proxy, _}`
  # dials that proxy with the URL hostname and does not dial a resolved origin
  # address. No pooling, cookies, automatic redirects or Req plugins.
  def get(uri, {:proxy, {scheme, address, port, proxy_opts}}, deadline)
      when scheme in [:http, :https] and is_list(proxy_opts) do
    timeout = remaining(deadline)
    {headers, proxy_opts} = Keyword.pop(proxy_opts, :proxy_headers, [])

    proxy_opts =
      proxy_opts
      |> Keyword.put(:tunnel_timeout, timeout)
      |> Keyword.put(:mode, :passive)
      |> Keyword.put(:transport_opts, proxy_transport_opts(scheme, proxy_opts, timeout))

    extra = [proxy: {scheme, address, port, proxy_opts}]
    extra = if headers == [], do: extra, else: [{:proxy_headers, headers} | extra]

    connect(uri, uri.host, extra, deadline, inet6?(address))
  end

  def get(uri, ip, deadline) when is_tuple(ip) do
    connect(uri, ip, [], deadline, tuple_size(ip) == 8)
  end

  defp connect(uri, address, extra, deadline, inet6?) do
    timeout = remaining(deadline)

    if timeout <= 0 do
      {:error, "Fetch deadline exceeded"}
    else
      scheme = if uri.scheme == "https", do: :https, else: :http

      tls =
        if scheme == :https,
          do: [cacerts: :public_key.cacerts_get(), verify: :verify_peer],
          else: []

      opts =
        [
          hostname: uri.host,
          protocols: [:http1],
          mode: :passive,
          max_header_list_size: 16_384,
          transport_opts: [timeout: min(timeout, 5_000), inet6: inet6?] ++ tls
        ] ++ extra

      case Mint.HTTP.connect(scheme, address, uri.port, opts) do
        {:ok, conn} ->
          try do
            request(conn, uri, deadline)
          after
            Mint.HTTP.close(conn)
          end

        {:error, _} ->
          {:error, "Connection or TLS verification failed"}
      end
    end
  end

  defp inet6?(address) when is_binary(address), do: String.contains?(address, ":")
  defp inet6?(address) when is_tuple(address), do: tuple_size(address) == 8
  defp inet6?(_), do: false

  defp proxy_transport_opts(scheme, proxy_opts, timeout) do
    opts =
      proxy_opts
      |> Keyword.get(:transport_opts, [])
      |> Keyword.put_new(:timeout, min(max(timeout, 0), 5_000))

    if scheme == :https do
      opts
      |> Keyword.put_new(:cacerts, :public_key.cacerts_get())
      |> Keyword.put_new(:verify, :verify_peer)
    else
      opts
    end
  end

  defp request(conn, uri, deadline) do
    path = if uri.path in [nil, ""], do: "/", else: uri.path
    target = if uri.query, do: path <> "?" <> uri.query, else: path

    case Mint.HTTP.request(conn, "GET", target, @headers, nil) do
      {:ok, conn, ref} ->
        receive_response(conn, ref, deadline, %{status: nil, headers: [], chunks: [], bytes: 0})

      {:error, _, _} ->
        {:error, "HTTP request failed"}
    end
  end

  defp receive_response(conn, ref, deadline, response) do
    if remaining(deadline) <= 0 do
      {:error, "Fetch deadline exceeded"}
    else
      case Mint.HTTP.recv(conn, 0, remaining(deadline)) do
        {:ok, conn, events} ->
          case consume(events, ref, response) do
            {:more, response} -> receive_response(conn, ref, deadline, response)
            result -> result
          end

        {:error, _, _, _} ->
          {:error, "Response timed out, was incomplete or exceeded HTTP header limits"}
      end
    end
  end

  defp consume([], _ref, response), do: {:more, response}

  defp consume([{:status, ref, status} | events], ref, response) do
    consume(events, ref, %{response | status: status})
  end

  defp consume([{:headers, ref, _headers} | events], ref, %{status: status} = response)
       when status in 100..199 and status != 101 do
    consume(events, ref, %{response | status: nil})
  end

  defp consume([{:headers, ref, headers} | events], ref, response) do
    response = %{response | headers: response.headers ++ headers}

    cond do
      response.status not in 200..299 -> finish(response)
      not identity_encoding?(headers) -> {:error, "Compressed responses are not supported"}
      oversized?(headers) -> {:error, "Response exceeds 1 MiB limit"}
      true -> consume(events, ref, response)
    end
  end

  defp consume([{:data, ref, chunk} | events], ref, response) do
    bytes = response.bytes + byte_size(chunk)

    if bytes > @max_bytes do
      {:error, "Response exceeds 1 MiB limit"}
    else
      consume(events, ref, %{response | bytes: bytes, chunks: [chunk | response.chunks]})
    end
  end

  defp consume([{:done, ref} | _], ref, response), do: finish(response)
  defp consume([{:error, ref, _} | _], ref, _response), do: {:error, "Invalid HTTP response"}

  defp finish(response) do
    {:ok,
     %{
       status: response.status,
       headers: response.headers,
       body: response.chunks |> Enum.reverse() |> IO.iodata_to_binary()
     }}
  end

  defp identity_encoding?(headers) do
    Enum.all?(headers, fn
      {"content-encoding", value} -> String.downcase(String.trim(value)) == "identity"
      _ -> true
    end)
  end

  defp oversized?(headers) do
    Enum.any?(headers, fn
      {"content-length", value} ->
        case Integer.parse(value) do
          {n, ""} -> n > @max_bytes
          _ -> true
        end

      _ ->
        false
    end)
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
