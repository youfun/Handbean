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
         do: response(response.body, id, method)
  end

  def call(%ServerConfig{} = cfg, method, params, timeout_ms) do
    id = Protocol.generate_id()

    with {:ok, response} <- post(cfg, request(id, method, params), nil, timeout_ms),
         do: response(response.body, id, method)
  end

  @doc "Best-effort, bounded termination for legacy Streamable HTTP sessions."
  def terminate_session(%ServerConfig{protocol_era: :legacy} = cfg) do
    if session_header?(cfg.runtime_headers) do
      headers =
        cfg.runtime_headers
        |> normalize_headers()
        |> Map.put("accept", "application/json, text/event-stream")

      task = Task.async(fn -> send_termination_request(cfg, headers, 750) end)

      if is_nil(Task.yield(task, 1_000)), do: Task.shutdown(task, :brutal_kill)
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def terminate_session(%ServerConfig{}), do: :ok

  defp connect_modern(cfg, versions) do
    if Protocol.modern_version() in versions do
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
          {:ok, %{cfg | runtime_capabilities: capabilities(result)}, versions}
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

      cfg = %{
        cfg
        | runtime_headers: headers,
          protocol_era: :legacy,
          runtime_capabilities: capabilities(result)
      }

      with {:ok, _} <- post(cfg, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}),
           {:ok, tools} <- list_tools(cfg, nil, [], MapSet.new()) do
        {:ok, cfg, tools}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, "Server returned an unsupported MCP protocol version"}
    end
  end

  defp list_tools(%ServerConfig{runtime_capabilities: caps} = cfg, cursor, acc, seen)
       when is_map(caps) do
    if Map.has_key?(caps, "tools"), do: fetch_tools(cfg, cursor, acc, seen), else: {:ok, []}
  end

  defp list_tools(cfg, cursor, acc, seen), do: fetch_tools(cfg, cursor, acc, seen)

  defp capabilities(%{"capabilities" => caps}) when is_map(caps), do: caps
  defp capabilities(_), do: nil

  defp fetch_tools(cfg, cursor, acc, seen) do
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
      |> normalize_headers()
      |> Map.merge(%{
        "content-type" => "application/json",
        "accept" => "application/json, text/event-stream"
      })
      |> maybe_put_modern_headers(cfg, payload, method)

    case send_request(cfg, :post, payload, headers, timeout_ms) do
      {:ok, %{status: 599}} ->
        {:error, "MCP HTTP response exceeded size limit"}

      {:ok, %{status: status} = response} when status in 200..299 ->
        {:ok, response}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, reason}
      when reason in [
             :authorization_required,
             :oauth_scope_required,
             :oauth_configuration_changed
           ] ->
        {:error, "MCP OAuth authorization required. Connect this server in Plugins settings."}

      {:error, _} ->
        {:error, "MCP HTTP request failed"}
    end
  end

  defp send_termination_request(%ServerConfig{oauth: oauth} = cfg, headers, timeout_ms)
       when is_map(oauth),
       do: Handbean.MCP.OAuth.cleanup_delete(cfg, headers, timeout_ms)

  defp send_termination_request(cfg, headers, timeout_ms),
    do: send_request(cfg, :delete, nil, headers, timeout_ms)

  defp send_request(%ServerConfig{oauth: oauth} = cfg, method, payload, headers, timeout_ms)
       when is_map(oauth),
       do: Handbean.MCP.OAuth.request(cfg, method, payload, headers, timeout_ms)

  defp send_request(cfg, method, payload, headers, timeout_ms) do
    req = Application.get_env(:handbean, :mcp_http_req, Req)

    options = [
      method: method,
      url: cfg.url,
      body: if(is_nil(payload), do: nil, else: Handbean.JSON.encode!(payload)),
      headers: headers,
      decode_body: false,
      redirect: false,
      retry: false,
      into: &receive_chunk/2,
      request_timeout: timeout_ms,
      receive_timeout: timeout_ms
    ]

    if req == Req, do: Req.request(options), else: apply(req, method, [cfg.url, options])
  end

  defp normalize_headers(headers),
    do: Map.new(headers, fn {key, value} -> {String.downcase(key), value} end)

  defp session_header?(headers),
    do:
      Enum.any?(headers, fn {key, value} ->
        String.downcase(key) == "mcp-session-id" and value != ""
      end)

  defp receive_chunk({:data, chunk}, {request, response}) do
    body = (response.body || "") <> chunk

    if byte_size(body) <= 12 * 1024 * 1024,
      do: {:cont, {request, %{response | body: body}}},
      else: {:halt, {request, %{response | status: 599, body: ""}}}
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

  defp response(body, id, method \\ nil) do
    case Handbean.JSON.decode(body) do
      {:ok, %{"id" => ^id} = message} -> rpc_result(message, method)
      {:ok, _} -> {:error, "MCP response ID mismatch"}
      {:error, _} -> sse_response(body, id, method)
    end
  end

  defp sse_response(body, id, method) do
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
        {:ok, %{"id" => ^id} = message} -> rpc_result(message, method)
        _ -> nil
      end
    end)
  end

  defp rpc_result(%{"error" => error}, "resources/" <> _), do: {:error, error}
  defp rpc_result(%{"error" => error}, _method), do: {:error, error_text(error)}
  defp rpc_result(message, _method), do: Protocol.parse_response(message)

  defp error_text(%{"message" => message}) when is_binary(message), do: message
  defp error_text(error), do: "MCP server returned a JSON-RPC error: #{inspect(error)}"
end
