defmodule Handbean.MCP.HTTP do
  @moduledoc """
  Streamable HTTP MCP client.

  Probes `2026-07-28` first. A modern JSON-RPC error stays on that revision;
  any other rejection falls back to the `initialize` handshake.
  """
  alias Handbean.MCP.{Protocol, ServerConfig}

  @modern_error_codes [-32_022, -32_020, -32_603]

  def initialize(%ServerConfig{} = cfg) do
    case discover(cfg) do
      {:ok, modern_cfg, versions} ->
        connect_modern(modern_cfg, versions)

      :legacy ->
        initialize_legacy(cfg)

      {:error, _} = error ->
        error
    end
  end

  def call(cfg, method, params, timeout_ms \\ 60_000)

  def call(%ServerConfig{protocol_era: :modern} = cfg, method, params, timeout_ms) do
    id = Protocol.generate_id()
    params = Map.put(params, "_meta", client_meta())

    with {:ok, response} <- post(cfg, request(id, method, params), method, timeout_ms),
         do: response(response.body, id)
  end

  def call(%ServerConfig{} = cfg, method, params, timeout_ms) do
    id = Protocol.generate_id()

    with {:ok, response} <- post(cfg, request(id, method, params), nil, timeout_ms),
         do: response(response.body, id)
  end

  defp connect_modern(cfg, versions) do
    version = Enum.find(versions, &Protocol.supported_version?/1)

    if version == Protocol.modern_version() do
      cfg = %{cfg | protocol_era: :modern}

      with {:ok, tools} <- list_tools(cfg, nil, [], MapSet.new()) do
        {:ok, cfg, tools}
      end
    else
      {:error, "Server returned an unsupported MCP protocol version"}
    end
  end

  defp discover(cfg) do
    id = Protocol.generate_id()
    payload = request(id, "server/discover", %{"_meta" => client_meta()})

    case post(cfg, payload, "server/discover") do
      {:ok, response} ->
        with {:ok, result} <- response(response.body, id),
             versions when is_list(versions) <- result["supportedVersions"],
             true <- Enum.all?(versions, &is_binary/1) do
          {:ok, cfg, versions}
        else
          _ -> {:error, "Invalid server/discover response"}
        end

      {:error, {:http, status, body}} when status in [400, 404, 405] ->
        if modern_error?(body), do: {:error, modern_error_message(body)}, else: :legacy

      {:error, _} = error ->
        error
    end
  end

  defp initialize_legacy(cfg) do
    id = Protocol.generate_id()

    payload =
      request(id, "initialize", %{
        protocolVersion: Protocol.latest_legacy_version(),
        clientInfo: %{name: "Handbean", version: client_version()},
        capabilities: %{}
      })

    with {:ok, response} <- post(cfg, payload),
         {:ok, result} <- response(response.body, id),
         version when is_binary(version) <- result["protocolVersion"],
         true <- Protocol.legacy_version?(version) do
      session = List.first(Req.Response.get_header(response, "mcp-session-id"))
      headers = Map.put(cfg.runtime_headers, "mcp-protocol-version", version)
      headers = if session, do: Map.put(headers, "mcp-session-id", session), else: headers
      cfg = %{cfg | runtime_headers: headers, protocol_era: :legacy}

      with {:ok, _} <- post(cfg, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}),
           {:ok, tools} <- list_tools(cfg, nil, [], MapSet.new()) do
        {:ok, cfg, tools}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, "Server returned an unsupported MCP protocol version"}
    end
  end

  defp list_tools(cfg, cursor, acc, seen) do
    params = if cursor, do: %{cursor: cursor}, else: %{}

    with {:ok, %{"tools" => tools} = result} when is_list(tools) <-
           call(cfg, "tools/list", params) do
      next = result["nextCursor"]

      cond do
        is_nil(next) ->
          {:ok, acc ++ tools}

        not is_binary(next) or MapSet.member?(seen, next) or MapSet.size(seen) >= 100 ->
          {:error, "Invalid tools/list pagination"}

        true ->
          list_tools(cfg, next, acc ++ tools, MapSet.put(seen, next))
      end
    else
      {:error, _} = error -> error
      _ -> {:error, "Invalid tools/list response"}
    end
  end

  defp request(id, method, params),
    do: %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

  defp client_meta do
    %{
      "io.modelcontextprotocol/protocolVersion" => Protocol.modern_version(),
      "io.modelcontextprotocol/clientInfo" => %{
        "name" => "Handbean",
        "version" => client_version()
      },
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }
  end

  defp client_version, do: to_string(Application.spec(:handbean, :vsn))

  defp post(cfg, payload, method \\ nil, timeout_ms \\ 60_000) do
    headers =
      cfg.runtime_headers
      |> Map.new(fn {key, value} -> {String.downcase(key), value} end)
      |> Map.merge(%{
        "content-type" => "application/json",
        "accept" => "application/json, text/event-stream"
      })
      |> maybe_put_modern_headers(cfg, payload, method)

    req = Application.get_env(:handbean, :mcp_http_req, Req)

    case req.post(cfg.url,
           body: Handbean.JSON.encode!(payload),
           headers: headers,
           decode_body: false,
           redirect: false,
           retry: false,
           receive_timeout: timeout_ms
         ) do
      {:ok, %{status: status} = response} when status in 200..299 -> {:ok, response}
      {:ok, %{status: status, body: body}} -> {:error, {:http, status, body}}
      {:error, _} -> {:error, "MCP HTTP request failed"}
    end
  end

  defp maybe_put_modern_headers(headers, %ServerConfig{protocol_era: :legacy}, _payload, _method),
    do: headers

  defp maybe_put_modern_headers(headers, _cfg, payload, method) do
    method = method || payload["method"]

    headers
    |> Map.put("mcp-protocol-version", Protocol.modern_version())
    |> Map.put("mcp-method", method)
    |> maybe_put_name(payload)
  end

  defp maybe_put_name(headers, %{"params" => params}) when is_map(params) do
    name = Handbean.Utils.SafeMap.get_any(params, "name", :name)
    uri = Handbean.Utils.SafeMap.get_any(params, "uri", :uri)

    cond do
      is_binary(name) -> Map.put(headers, "mcp-name", name)
      is_binary(uri) -> Map.put(headers, "mcp-name", uri)
      true -> headers
    end
  end

  defp maybe_put_name(headers, _), do: headers

  defp modern_error?(body) do
    case decode_message(body) do
      {:ok, %{"error" => %{"code" => code}}} -> code in @modern_error_codes
      _ -> false
    end
  end

  defp modern_error_message(body) do
    case decode_message(body) do
      {:ok, %{"error" => %{"code" => -32_022, "data" => %{"supported" => versions}}}}
      when is_list(versions) ->
        "Unsupported MCP protocol version. Server supports: #{Enum.join(versions, ", ")}"

      {:ok, %{"error" => %{"message" => message}}} when is_binary(message) ->
        message

      _ ->
        "MCP server rejected the protocol version"
    end
  end

  defp decode_message(body) when is_binary(body) do
    case Handbean.JSON.decode(body) do
      {:ok, message} when is_map(message) -> {:ok, message}
      _ -> sse_message(body)
    end
  end

  defp decode_message(message) when is_map(message), do: {:ok, message}
  defp decode_message(_), do: :error

  defp sse_message(body) do
    body
    |> String.replace("\r\n", "\n")
    |> String.split("\n")
    |> Enum.find_value(:error, fn line ->
      with "data:" <> data <- line,
           {:ok, message} when is_map(message) <- Handbean.JSON.decode(String.trim(data)) do
        {:ok, message}
      else
        _ -> nil
      end
    end)
  end

  defp response(body, id) do
    case Handbean.JSON.decode(body) do
      {:ok, %{"id" => ^id} = message} -> rpc_result(message)
      {:ok, _} -> {:error, "MCP response ID mismatch"}
      {:error, _} -> sse_response(body, id)
    end
  end

  defp sse_response(body, id) do
    body
    |> String.replace("\r\n", "\n")
    |> String.split("\n\n")
    |> Enum.find_value({:error, "No matching MCP response in event stream"}, fn event ->
      data =
        event
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "data:"))
        |> Enum.map_join("\n", &(String.replace_prefix(&1, "data:", "") |> String.trim_leading()))

      case Handbean.JSON.decode(data) do
        {:ok, %{"id" => ^id} = message} -> rpc_result(message)
        _ -> nil
      end
    end)
  end

  defp rpc_result(%{"error" => error}), do: {:error, error_text(error)}
  defp rpc_result(message), do: Protocol.parse_response(message)

  defp error_text(%{"message" => message}) when is_binary(message), do: message
  defp error_text(error), do: "MCP server returned a JSON-RPC error: #{inspect(error)}"
end
