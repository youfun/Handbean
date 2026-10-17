defmodule Handbean.Preview.Proxy do
  @moduledoc """
  Loopback-only reverse proxy for registered preview ports.

  Does not accept a page-supplied target URL. Workbench credentials and
  upstream Set-Cookie are stripped. Unsupported WS/HMR is a clear error,
  not a fallback to a top-level agent port.
  """

  @blocked_request_headers ~w(cookie authorization host origin referer)
  @blocked_response_headers ~w(set-cookie set-cookie2 www-authenticate content-security-policy)

  @spec request(atom(), pos_integer(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def request(method, port, path, opts \\ []) do
    with :ok <- Handbean.Preview.Store.validate_loopback_port(port),
         :ok <- reject_websocket(opts) do
      url = loopback_url(port, path, Keyword.get(opts, :query))

      headers =
        opts
        |> Keyword.get(:headers, [])
        |> sanitize_request_headers()

      body = Keyword.get(opts, :body)

      case http_request(method, url, headers, body, opts) do
        {:ok, status, resp_headers, resp_body} ->
          {:ok,
           %{
             status: status,
             headers: sanitize_response_headers(resp_headers),
             body: resp_body,
             incompatible?: incompatible?(resp_headers, resp_body)
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec rewrite_location(String.t(), String.t(), pos_integer()) ::
          {:ok, String.t()} | {:error, :unsupported_redirect}
  def rewrite_location(location, preview_id, port)
      when is_binary(location) and is_binary(preview_id) and is_integer(port) do
    uri = URI.parse(location)

    cond do
      uri.scheme in [nil, "http", "https"] and loopback_host?(uri.host) and
          (is_nil(uri.port) or uri.port == port) ->
        {:ok, join_port_path(preview_id, uri.path || "/", uri.query)}

      is_nil(uri.scheme) and is_nil(uri.host) ->
        {:ok, join_port_path(preview_id, uri.path || "/", uri.query)}

      true ->
        {:error, :unsupported_redirect}
    end
  end

  defp reject_websocket(opts) do
    upgrade =
      opts
      |> Keyword.get(:headers, [])
      |> header_value("upgrade")

    if upgrade && String.downcase(upgrade) == "websocket" do
      {:error, :websocket_unsupported}
    else
      :ok
    end
  end

  defp loopback_url(port, path, query) do
    path = "/" <> String.trim_leading(path || "", "/")
    URI.to_string(%URI{scheme: "http", host: "127.0.0.1", port: port, path: path, query: query})
  end

  defp sanitize_request_headers(headers) do
    Enum.reject(headers, fn {name, _} ->
      String.downcase(to_string(name)) in @blocked_request_headers
    end)
  end

  defp sanitize_response_headers(headers) do
    Enum.reject(headers, fn {name, _} ->
      String.downcase(to_string(name)) in @blocked_response_headers
    end)
  end

  defp incompatible?(headers, body) do
    location = header_value(headers, "location")
    body = IO.iodata_to_binary(body || "")

    cond do
      is_binary(location) and String.contains?(location, ":4001") -> true
      String.contains?(body, "localhost:4001") -> true
      true -> false
    end
  end

  defp header_value(headers, name) do
    target = String.downcase(name)

    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(to_string(key)) == target, do: to_string(value)
    end)
  end

  defp loopback_host?(nil), do: true
  defp loopback_host?("127.0.0.1"), do: true
  defp loopback_host?("localhost"), do: true
  defp loopback_host?("::1"), do: true
  defp loopback_host?(_), do: false

  defp join_port_path(preview_id, path, query) do
    rest = String.trim_leading(path || "/", "/")
    base = "/preview/#{preview_id}/port/#{rest}"
    if query, do: base <> "?" <> query, else: base
  end

  defp http_request(method, url, headers, body, opts) do
    case Keyword.get(opts, :http) do
      fun when is_function(fun, 4) ->
        fun.(method, url, headers, body)

      _ ->
        req_request(method, url, headers, body)
    end
  end

  defp req_request(method, url, headers, body) do
    case Req.request(
           method: method,
           url: url,
           headers: headers,
           body: body || "",
           retry: false,
           redirect: false,
           receive_timeout: 15_000
         ) do
      {:ok, %{status: status, headers: resp_headers, body: resp_body}} ->
        {:ok, status, flatten_headers(resp_headers), resp_body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp flatten_headers(headers) when is_map(headers) do
    Enum.flat_map(headers, fn {k, values} ->
      Enum.map(List.wrap(values), fn v -> {to_string(k), to_string(v)} end)
    end)
  end

  defp flatten_headers(headers) when is_list(headers), do: headers
end
