defmodule Handbean.MCP.OAuth.Network do
  @moduledoc false

  alias Handbean.MCP.OAuth.Config
  alias Handbean.WebFetch.Address

  @max_bytes 1_048_576

  # Resolve and pin every request, including authenticated resource requests.
  # No proxy, cookies, redirects or automatic retries cross this boundary.
  def request(method, url, resource, opts \\ []) do
    with {:ok, uri, ip} <- destination(url, resource) do
      target = URI.to_string(%{uri | host: ip |> :inet.ntoa() |> to_string()})

      host =
        URI.to_string(%{uri | scheme: nil, path: nil, query: nil, fragment: nil})
        |> String.trim_leading("//")

      headers = Map.new(Keyword.get(opts, :headers, [])) |> Map.put("host", host)

      options = [
        method: method,
        url: target,
        headers: headers,
        body: Keyword.get(opts, :body),
        redirect: false,
        retry: false,
        decode_body: false,
        compressed: false,
        receive_timeout: Keyword.get(opts, :receive_timeout, 15_000),
        request_timeout: Keyword.get(opts, :receive_timeout, 15_000),
        connect_options: [
          hostname: uri.host,
          timeout: 5_000,
          transport_opts: [inet6: tuple_size(ip) == 8]
        ],
        into: fn {:data, chunk}, {request, response} ->
          body = (response.body || "") <> chunk

          if byte_size(body) <= Keyword.get(opts, :max_response_bytes, @max_bytes),
            do: {:cont, {request, %{response | body: body}}},
            else: {:halt, {request, %{response | status: 599, body: ""}}}
        end
      ]

      case Req.request(options) do
        {:ok, %{status: 599}} -> {:error, :response_too_large}
        {:ok, response} -> {:ok, response}
        {:error, _} -> {:error, :oauth_network_failed}
      end
    end
  end

  def destination(url, resource) do
    with {:ok, uri} <- Address.parse(url),
         true <- URI.parse(url).fragment == nil,
         {:ok, resource_uri} <- Address.parse(resource),
         true <-
           uri.scheme == "https" or
             (Config.loopback?(resource_uri) and Config.origin(uri) == Config.origin(resource_uri)),
         {:ok, addresses} <-
           Address.resolve(uri.host, System.monotonic_time(:millisecond) + 5_000),
         {:ok, ip} <- select(addresses, uri, resource_uri) do
      {:ok, uri, ip}
    else
      _ -> {:error, :unsafe_oauth_destination}
    end
  end

  defp select(addresses, uri, resource) do
    if Config.loopback?(resource) and Config.origin(uri) == Config.origin(resource),
      do: {:ok, hd(addresses)},
      else: Address.select_public(addresses)
  end
end
