defmodule Handbean.Workspace.HexHttp do
  @moduledoc """
  Hex 2.4.1 HTTP adapter that uses the host Req stack.

  Hex 2.4.1 hardcodes `{Hex.HTTP, %{}}` and that module talks to `:httpc`.
  On mobile we load packaged Hex without `Hex.HTTP.beam` and install a
  thin `Hex.HTTP` delegate to this module. Desktop Mix keeps its own Hex.

  Only public HTTPS GET/HEAD to Hex hosts is supported. Registry and
  tarball verification stay in Hex; this adapter does not disable TLS.
  """

  @allowed_hosts MapSet.new([
                   "repo.hex.pm",
                   "hex.pm",
                   "www.hex.pm",
                   "cm.hex.pm"
                 ])

  @type adapter_config :: map()

  @spec config() :: map()
  def config do
    %{http_adapter: {Hex.HTTP, %{}}}
  end

  @spec request(term(), term(), term(), term()) ::
          {:ok, {integer(), map(), term()}} | {:error, term()}
  def request(method, url, headers, body), do: request(method, url, headers, body, %{})

  @spec request(term(), term(), term(), term(), adapter_config()) ::
          {:ok, {integer(), map(), term()}} | {:error, term()}
  def request(method, url, headers, body, adapter_config) do
    method = normalize_method(method)
    url = to_string(url)
    timeout = request_timeout(adapter_config)

    with :ok <- require_online(),
         :ok <- validate(method, url, body),
         {:ok, response} <- dispatch(method, url, headers, timeout, adapter_config) do
      {:ok, {response.status, response_headers(response), response.body}}
    end
  end

  @spec request_to_file(term(), term(), term(), term(), Path.t(), adapter_config()) ::
          {:ok, {integer(), map()}} | {:error, term()}
  def request_to_file(method, url, headers, body, filename, adapter_config \\ %{}) do
    with {:ok, {status, response_headers, bytes}} <-
           request(method, url, headers, body, adapter_config),
         :ok <- File.write(filename, bytes) do
      {:ok, {status, response_headers}}
    end
  end

  defp validate(method, url, body) do
    uri = URI.parse(url)

    cond do
      method not in [:get, :head] ->
        {:error, {:unsupported_hex_request, method}}

      not empty_body?(body) ->
        {:error, {:unsupported_hex_request, :body}}

      uri.scheme != "https" ->
        {:error, {:unsupported_hex_request, :scheme}}

      uri.host not in @allowed_hosts ->
        {:error, {:unsupported_hex_host, uri.host}}

      true ->
        :ok
    end
  end

  defp dispatch(method, url, headers, timeout, adapter_config) do
    opts =
      [
        headers: normalize_headers(headers),
        decode_body: false,
        retry: false,
        redirect: false,
        receive_timeout: timeout
      ] ++ Map.get(adapter_config, :req_options, [])

    result =
      case method do
        :get -> Req.get(url, opts)
        :head -> Req.head(url, opts)
      end

    case result do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_method(method) when is_atom(method), do: method

  defp normalize_method(method) when is_binary(method) do
    case String.downcase(method) do
      "get" -> :get
      "head" -> :head
      "post" -> :post
      "put" -> :put
      "delete" -> :delete
      other -> {:unsupported, other}
    end
  end

  defp empty_body?(body) when body in [nil, :undefined, "", []], do: true
  defp empty_body?(body) when is_binary(body), do: body == ""
  defp empty_body?(_), do: false

  defp normalize_headers(headers) when is_map(headers) do
    Enum.map(headers, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp normalize_headers(headers) when is_list(headers) do
    Enum.map(headers, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp normalize_headers(_), do: []

  defp response_headers(%{headers: headers}) do
    Map.new(headers, fn {key, value} ->
      {to_string(key), header_value(value)}
    end)
  end

  defp header_value(value) when is_list(value), do: Enum.join(value, ", ")
  defp header_value(value), do: to_string(value)

  defp request_timeout(%{timeout: timeout}) when is_integer(timeout) and timeout > 0, do: timeout
  defp request_timeout(_), do: 30_000

  defp require_online do
    if System.get_env("HEX_OFFLINE") in ["1", "true"], do: {:error, :offline}, else: :ok
  end
end
