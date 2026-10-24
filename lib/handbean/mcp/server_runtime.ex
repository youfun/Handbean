defmodule Handbean.MCP.ServerRuntime do
  @moduledoc """
  Minimal MCP client runtime supporting both stdio and HTTP transports.

  * **stdio**: spawns an external command, communicates via newline-delimited JSON-RPC.
  * **HTTP**: connects to a streamable HTTP MCP endpoint via Req, communicates
    via JSON-RPC POST + SSE response.
  """

  use GenServer, restart: :temporary

  alias Handbean.MCP.{Protocol, ServerConfig}

  @stdio_request_timeout_ms 15_000
  @bootstrap_call_timeout_ms 115_000
  @max_stdio_frame_bytes 12 * 1_024 * 1_024

  @type tool_spec :: %{
          name: String.t(),
          description: String.t() | nil,
          input_schema: map()
        }

  @type http_state :: %{
          cfg: ServerConfig.t(),
          tools: [tool_spec()],
          status: :initializing | :ready | {:failed, term()},
          tools_waiters: [GenServer.from()]
        }

  @type stdio_request :: %{
          kind:
            :initialize
            | :list_tools
            | {:call_tool, GenServer.from()}
            | {:resource, GenServer.from()},
          deadline: integer(),
          timer_ref: reference()
        }

  @type stdio_state :: %{
          cfg: ServerConfig.t(),
          port: port() | nil,
          next_id: non_neg_integer(),
          tools: [tool_spec()],
          capabilities: map() | nil,
          pending: %{binary() => stdio_request()},
          stdio_buffer: binary(),
          status: :opening | :initializing | :listing_tools | :ready | {:failed, term()},
          tools_waiters: [GenServer.from()]
        }

  @type state :: {:stdio, stdio_state()} | {:http, http_state()}
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec tools(pid()) :: {:ok, [tool_spec()]} | {:error, term()}
  def tools(pid) do
    GenServer.call(pid, :tools, @bootstrap_call_timeout_ms)
  catch
    :exit, reason -> {:error, {:runtime_unavailable, reason}}
  end

  @spec call_tool(pid(), String.t(), map(), pos_integer(), keyword()) ::
          {:ok, String.t(), map()} | {:ok, String.t()} | {:error, String.t()}
  def call_tool(pid, tool_name, input, timeout_ms \\ 60_000, opts \\ [])
      when is_integer(timeout_ms) and timeout_ms > 0 do
    deadline = Keyword.get(opts, :deadline, System.monotonic_time(:millisecond) + timeout_ms)
    authorization = Keyword.get(opts, :authorization)

    GenServer.call(
      pid,
      {:call_tool, tool_name, input, deadline, authorization},
      timeout_ms + 1_000
    )
  catch
    :exit, {:timeout, _} -> {:error, format_error(timeout_reason())}
    :exit, reason -> {:error, format_error({:runtime_unavailable, reason})}
  end

  @doc "Requests one resource page or resource contents over the existing transport."
  def resource_request(pid, method, params, timeout_ms \\ 60_000, opts \\ [])
      when method in ["resources/list", "resources/templates/list", "resources/read"] and
             is_map(params) and is_integer(timeout_ms) and timeout_ms > 0 do
    deadline = Keyword.get(opts, :deadline, System.monotonic_time(:millisecond) + timeout_ms)
    authorization = Keyword.get(opts, :authorization)

    GenServer.call(
      pid,
      {:resource_request, method, params, deadline, authorization},
      timeout_ms + 1_000
    )
  catch
    :exit, {:timeout, _} -> {:error, timeout_reason()}
    :exit, _reason -> {:error, :runtime_unavailable}
  end

  @spec shutdown(pid()) :: :ok
  def shutdown(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Init — dispatch by transport kind
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    notify_candidate_started(opts)
    cfg = Keyword.fetch!(opts, :server_config)

    case transport_kind(cfg) do
      :stdio ->
        if Handbean.Host.shell?(), do: init_stdio(cfg), else: {:stop, :unsupported_transport}

      :http ->
        init_http(cfg)
    end
  end

  defp transport_kind(%ServerConfig{url: url}) when is_binary(url) and url != "", do: :http
  defp transport_kind(_), do: :stdio

  defp notify_candidate_started(opts) do
    case {Keyword.get(opts, :candidate_owner), Keyword.get(opts, :candidate_id)} do
      {owner, flight_id} when is_pid(owner) and is_reference(flight_id) ->
        send(owner, {:mcp_candidate_started, flight_id, self()})

      _ ->
        :ok
    end
  end

  # -- stdio init --

  defp init_stdio(cfg) do
    state = %{
      cfg: cfg,
      port: nil,
      next_id: 1,
      tools: [],
      capabilities: nil,
      pending: %{},
      stdio_buffer: "",
      status: :opening,
      tools_waiters: []
    }

    {:ok, {:stdio, state}, {:continue, :initialize_stdio}}
  end

  defp init_http(cfg) do
    state = %{cfg: cfg, tools: [], status: :initializing, tools_waiters: []}
    {:ok, {:http, state}, {:continue, :initialize_http}}
  end

  @impl true
  def handle_continue(:initialize_stdio, {:stdio, state}) do
    case open_port(state.cfg) do
      {:ok, port} ->
        state = %{state | port: port, status: :initializing}

        params = %{
          protocolVersion: Protocol.latest_legacy_version(),
          clientInfo: %{"name" => "Handbean", "version" => app_version()},
          capabilities: %{}
        }

        {:noreply,
         {:stdio,
          start_stdio_request(
            state,
            "initialize",
            params,
            :initialize,
            @stdio_request_timeout_ms
          )}}

      {:error, reason} ->
        stdio_transition(fail_stdio(state, reason))
    end
  end

  def handle_continue(:initialize_http, {:http, state}) do
    case initialize_http(state.cfg) do
      {:ok, cfg, tools} ->
        Enum.each(state.tools_waiters, &GenServer.reply(&1, {:ok, tools}))

        {:noreply, {:http, %{state | cfg: cfg, tools: tools, status: :ready, tools_waiters: []}}}

      {:error, reason} ->
        Enum.each(state.tools_waiters, &GenServer.reply(&1, {:error, reason}))
        {:noreply, {:http, %{state | status: {:failed, reason}, tools_waiters: []}}}
    end
  end

  defp initialize_http(cfg) do
    with {:ok, cfg, tools} <- Handbean.MCP.HTTP.initialize(cfg) do
      tools =
        Enum.flat_map(tools, fn
          %{"name" => name} = tool when is_binary(name) ->
            [
              %{
                name: name,
                description: Map.get(tool, "description", ""),
                input_schema: Map.get(tool, "inputSchema", %{})
              }
            ]

          _ ->
            []
        end)

      {:ok, cfg, tools}
    end
  end

  # ---------------------------------------------------------------------------
  # Call handlers
  # ---------------------------------------------------------------------------

  @impl true
  def handle_call(:tools, _from, {:stdio, %{status: :ready} = state}),
    do: {:reply, {:ok, state.tools}, {:stdio, state}}

  def handle_call(:tools, _from, {:stdio, %{status: {:failed, reason}} = state}),
    do: {:reply, {:error, reason}, {:stdio, state}}

  def handle_call(:tools, from, {:stdio, state}) do
    {:noreply, {:stdio, %{state | tools_waiters: [from | state.tools_waiters]}}}
  end

  def handle_call(:tools, _from, {:http, %{status: :ready} = state}),
    do: {:reply, {:ok, state.tools}, {:http, state}}

  def handle_call(:tools, _from, {:http, %{status: {:failed, reason}} = state}),
    do: {:reply, {:error, reason}, {:http, state}}

  def handle_call(:tools, from, {:http, state}) do
    {:noreply, {:http, %{state | tools_waiters: [from | state.tools_waiters]}}}
  end

  def handle_call(
        {:call_tool, tool_name, input, deadline, authorization},
        from,
        {:stdio, %{status: :ready} = state}
      ) do
    with {:ok, _effective} <- dispatch_authorized(authorization),
         {:ok, _remaining} <- resource_budget(deadline),
         params = %{name: tool_name, arguments: input || %{}},
         {:ok, state} <-
           start_stdio_request(
             state,
             "tools/call",
             params,
             {:call_tool, from},
             deadline,
             :absolute
           ) do
      {:noreply, {:stdio, state}}
    else
      {:error, reason} -> {:reply, {:error, format_error(reason)}, {:stdio, state}}
    end
  end

  def handle_call(
        {:call_tool, _tool_name, _input, _deadline, _authorization},
        _from,
        {:stdio, %{status: {:failed, reason}} = state}
      ) do
    {:reply, {:error, format_error(reason)}, {:stdio, state}}
  end

  def handle_call({:call_tool, _, _, _, _}, _from, {:stdio, state}) do
    {:reply, {:error, "MCP server is still initializing"}, {:stdio, state}}
  end

  def handle_call(
        {:call_tool, tool_name, input, deadline, authorization},
        _from,
        {:http, %{status: :ready} = state}
      ) do
    result =
      call_tool_http(
        state.cfg,
        %{name: tool_name, arguments: input || %{}},
        deadline,
        authorization
      )

    reply =
      case result do
        {:ok, value} -> normalize_tool_result(value)
        {:error, reason} -> {:error, format_error(reason)}
      end

    {:reply, reply, {:http, state}}
  end

  def handle_call(
        {:call_tool, _tool_name, _input, _deadline, _authorization},
        _from,
        {:http, %{status: {:failed, reason}} = state}
      ) do
    {:reply, {:error, format_error(reason)}, {:http, state}}
  end

  def handle_call({:call_tool, _, _, _, _}, _from, {:http, state}) do
    {:reply, {:error, "MCP server is still initializing"}, {:http, state}}
  end

  def handle_call(
        {:resource_request, method, params, deadline, authorization},
        from,
        {:stdio, %{status: :ready} = state}
      ) do
    with :ok <- resource_authorized(authorization),
         {:ok, _remaining} <- resource_budget(deadline),
         :ok <- resource_capability(state.capabilities),
         {:ok, state} <-
           start_stdio_request(
             state,
             method,
             params,
             {:resource, from},
             deadline,
             :absolute
           ) do
      {:noreply, {:stdio, state}}
    else
      {:error, _} = error -> {:reply, error, {:stdio, state}}
    end
  end

  def handle_call(
        {:resource_request, method, params, deadline, authorization},
        _from,
        {:http, %{status: :ready} = state}
      ) do
    result =
      with :ok <- resource_authorized(authorization),
           {:ok, _remaining} <- resource_budget(deadline),
           :ok <- resource_capability(Map.get(state.cfg, :runtime_capabilities)) do
        call_resource_http(state.cfg, method, params, deadline, authorization)
      end

    {:reply, result, {:http, state}}
  end

  def handle_call({:resource_request, _, _, _, _}, _from, {transport, state}) do
    {:reply, {:error, :runtime_unavailable}, {transport, state}}
  end

  @impl true
  def terminate(_reason, {:stdio, %{port: port}}), do: safe_close_port(port)
  def terminate(_reason, {:http, %{cfg: cfg}}), do: Handbean.MCP.HTTP.terminate_session(cfg)

  # ---------------------------------------------------------------------------
  # stdio transport
  # ---------------------------------------------------------------------------

  defp open_port(%ServerConfig{command: command, args: args, runtime_env: env, cwd: cwd}) do
    executable = System.find_executable(command)

    if is_nil(executable) do
      {:error, "MCP command not found: #{command}"}
    else
      port_opts = [:binary, :exit_status, :use_stdio, :hide]
      port_opts = if cwd, do: [{:cd, String.to_charlist(cwd)} | port_opts], else: port_opts

      port_opts =
        if map_size(env) > 0 do
          [
            {:env, Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)}
            | port_opts
          ]
        else
          port_opts
        end

      command_args = Enum.map(args || [], &to_string/1)

      {:ok,
       Port.open({:spawn_executable, executable}, [
         {:args, Enum.map(command_args, &String.to_charlist/1)} | port_opts
       ])}
    end
  end

  defp start_stdio_request(state, method, params, kind, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    case start_stdio_request(state, method, params, kind, deadline, :absolute) do
      {:ok, state} -> state
      {:error, reason} -> fail_stdio(state, reason)
    end
  end

  defp start_stdio_request(state, method, params, kind, deadline, :absolute) do
    id = Integer.to_string(state.next_id)
    payload = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
    bytes = encode_port_payload(payload)
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, timeout_reason()}
    else
      timer_ref = Process.send_after(self(), {:stdio_request_timeout, id, deadline}, remaining)
      Port.command(state.port, bytes)
      request = %{kind: kind, deadline: deadline, timer_ref: timer_ref}

      {:ok,
       %{
         state
         | next_id: state.next_id + 1,
           pending: Map.put(state.pending, id, request)
       }}
    end
  end

  defp stdio_notify(%{port: port}, method, params) do
    send_port(port, %{"jsonrpc" => "2.0", "method" => method, "params" => params})
    :ok
  end

  defp send_port(port, payload), do: Port.command(port, encode_port_payload(payload))

  defp encode_port_payload(payload), do: Handbean.JSON.encode!(payload) <> "\n"

  @impl true
  def handle_info({port, {:data, data}}, {:stdio, %{port: port} = state}) do
    case consume_stdio_data(state, data) do
      {:ok, messages, state} ->
        stdio_transition(Enum.reduce(messages, state, &route_stdio_message/2))

      {:error, reason, state} ->
        stdio_transition(fail_stdio(state, reason))
    end
  end

  def handle_info({port, {:exit_status, status}}, {:stdio, %{port: port} = state}) do
    reason =
      if state.stdio_buffer == "" do
        "MCP server exited with status #{status}"
      else
        {:incomplete_stdio_message, byte_size(state.stdio_buffer), status}
      end

    stdio_transition(fail_stdio(state, reason))
  end

  def handle_info({:stdio_request_timeout, id, deadline}, {:stdio, state}) do
    case Map.get(state.pending, id) do
      %{deadline: ^deadline} = request ->
        remaining_ms = deadline - System.monotonic_time(:millisecond)

        if remaining_ms > 0 do
          timer_ref =
            Process.send_after(self(), {:stdio_request_timeout, id, deadline}, remaining_ms)

          request = %{request | timer_ref: timer_ref}
          {:noreply, {:stdio, put_in(state.pending[id], request)}}
        else
          state = %{state | pending: Map.delete(state.pending, id)}
          stdio_transition(complete_stdio_request(state, request, {:error, timeout_reason()}))
        end

      _stale_or_completed_request ->
        {:noreply, {:stdio, state}}
    end
  end

  defp consume_stdio_data(state, data) do
    if byte_size(state.stdio_buffer) + byte_size(data) > @max_stdio_frame_bytes do
      {:error, :mcp_response_too_large, %{state | stdio_buffer: ""}}
    else
      {lines, stdio_buffer} = Protocol.split_lines(state.stdio_buffer <> data)
      state = %{state | stdio_buffer: stdio_buffer}

      case Protocol.decode_lines(lines) do
        {:ok, messages} -> {:ok, messages, state}
        {:error, reason} -> {:error, {:invalid_stdio_message, reason}, state}
      end
    end
  end

  defp stdio_transition(%{status: {:failed, _}} = state), do: {:stop, :normal, {:stdio, state}}
  defp stdio_transition(state), do: {:noreply, {:stdio, state}}

  defp route_stdio_message(%{"id" => id} = response, state) do
    case Map.pop(state.pending, to_string(id)) do
      {nil, _pending} ->
        state

      {request, pending} ->
        cancel_timer(request.timer_ref)
        state = %{state | pending: pending}

        result =
          if System.monotonic_time(:millisecond) >= request.deadline do
            {:error, timeout_reason()}
          else
            Protocol.parse_response(response)
          end

        complete_stdio_request(state, request, result)
    end
  end

  defp route_stdio_message(_notification_or_unknown_message, state), do: state

  defp complete_stdio_request(state, %{kind: :initialize}, {:ok, result}) when is_map(result) do
    :ok = stdio_notify(state, "notifications/initialized", %{})
    capabilities = result["capabilities"]
    state = %{state | capabilities: capabilities, status: :listing_tools}

    if is_map(capabilities) and not Map.has_key?(capabilities, "tools") do
      complete_stdio_request(state, %{kind: :list_tools}, {:ok, %{"tools" => []}})
    else
      start_stdio_request(state, "tools/list", %{}, :list_tools, @stdio_request_timeout_ms)
    end
  end

  defp complete_stdio_request(state, %{kind: :initialize}, {:ok, _result}),
    do: fail_stdio(state, :invalid_initialize_response)

  defp complete_stdio_request(state, %{kind: :initialize}, {:error, reason}),
    do: fail_stdio(state, reason)

  defp complete_stdio_request(state, %{kind: :list_tools}, {:ok, %{"tools" => tools}})
       when is_list(tools) do
    tools = normalize_tools(tools)
    Enum.each(state.tools_waiters, &GenServer.reply(&1, {:ok, tools}))
    %{state | status: :ready, tools: tools, tools_waiters: []}
  end

  defp complete_stdio_request(state, %{kind: :list_tools}, {:ok, other}),
    do: fail_stdio(state, "unexpected tools/list response: #{inspect(other)}")

  defp complete_stdio_request(state, %{kind: :list_tools}, {:error, reason}),
    do: fail_stdio(state, reason)

  defp complete_stdio_request(state, %{kind: {:call_tool, from}}, {:ok, result}) do
    GenServer.reply(from, normalize_tool_result(result))
    state
  end

  defp complete_stdio_request(state, %{kind: {:call_tool, from}}, {:error, reason}) do
    GenServer.reply(from, {:error, format_error(reason)})
    state
  end

  defp complete_stdio_request(state, %{kind: {:resource, from}}, result) do
    GenServer.reply(from, result)
    state
  end

  defp call_tool_http(cfg, params, deadline, authorization),
    do: bounded_http_call(cfg, "tools/call", params, deadline, authorization)

  defp call_resource_http(cfg, method, params, deadline, authorization),
    do: bounded_http_call(cfg, method, params, deadline, authorization)

  defp bounded_http_call(cfg, method, params, deadline, authorization) do
    task =
      Task.Supervisor.async_nolink(Handbean.AgentRunTaskSupervisor, fn ->
        with {:ok, effective} <- dispatch_authorized(authorization),
             {:ok, remaining} <- resource_budget(deadline) do
          Handbean.MCP.HTTP.call(current_http_config(cfg, effective), method, params, remaining)
        end
      end)

    # A receive timeout alone permits an endless slow stream. This deadline also
    # bounds OAuth credential locks, refreshes, connection setup and body receipt.
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    case Task.yield(task, remaining) do
      {:ok, result} ->
        result

      {:exit, _reason} ->
        {:error, :runtime_unavailable}

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, timeout_reason()}
    end
  end

  defp resource_budget(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    if remaining > 0, do: {:ok, remaining}, else: {:error, timeout_reason()}
  end

  # Low-level runtime callers are trusted application code. Model tools always
  # supply the original effective config and scope through their bridge.
  defp dispatch_authorized(nil), do: {:ok, nil}

  defp dispatch_authorized({config, opts}) do
    case Handbean.MCP.Access.current(config, opts, %{mcp_scope: opts}) do
      {:ok, effective} -> {:ok, effective}
      {:error, _} -> {:error, :mcp_access_revoked}
    end
  end

  defp resource_authorized(nil), do: :ok

  defp resource_authorized(authorization) do
    case dispatch_authorized(authorization) do
      {:ok, _effective} -> :ok
      {:error, _} -> {:error, :resource_access_revoked}
    end
  end

  defp current_http_config(runtime, nil), do: runtime

  defp current_http_config(runtime, effective) do
    transport_headers =
      Map.filter(runtime.runtime_headers, fn {key, _value} ->
        String.starts_with?(String.downcase(key), "mcp-")
      end)

    %{
      effective
      | runtime_headers: Map.merge(effective.runtime_headers, transport_headers),
        protocol_era: runtime.protocol_era,
        runtime_capabilities: runtime.runtime_capabilities
    }
  end

  defp resource_capability(capabilities) do
    if resources_supported?(capabilities), do: :ok, else: {:error, :resources_not_supported}
  end

  # Older servers sometimes omit capabilities altogether; let their RPC response
  # establish support. An explicit capability map is authoritative.
  defp resources_supported?(nil), do: true

  defp resources_supported?(capabilities) when is_map(capabilities),
    do: is_map(capabilities["resources"])

  defp resources_supported?(_), do: false

  defp normalize_tools(tools) do
    Enum.flat_map(tools, fn
      %{"name" => name} = tool ->
        [
          %{
            name: name,
            description: Map.get(tool, "description"),
            input_schema: Map.get(tool, "inputSchema", %{})
          }
        ]

      %{"name" => name, "input_schema" => schema} = tool ->
        [%{name: name, description: Map.get(tool, "description"), input_schema: schema}]

      _ ->
        []
    end)
  end

  defp fail_stdio(%{status: {:failed, _previous_reason}} = state, _reason), do: state

  defp fail_stdio(state, reason) do
    Enum.each(state.tools_waiters, &GenServer.reply(&1, {:error, reason}))

    Enum.each(state.pending, fn {_id, request} ->
      cancel_timer(request.timer_ref)

      case request.kind do
        {:call_tool, from} -> GenServer.reply(from, {:error, format_error(reason)})
        {:resource, from} -> GenServer.reply(from, {:error, reason})
        _bootstrap_request -> :ok
      end
    end)

    safe_close_port(state.port)

    %{
      state
      | port: nil,
        pending: %{},
        status: {:failed, reason},
        tools_waiters: []
    }
  end

  defp timeout_reason, do: {:mcp_timeout, "MCP request timed out"}

  defp cancel_timer(timer_ref) do
    Process.cancel_timer(timer_ref, async: true, info: false)
    :ok
  end

  # ---------------------------------------------------------------------------
  # HTTP transport
  # ---------------------------------------------------------------------------

  def parse_http_response(body) when is_binary(body) do
    case Handbean.JSON.decode(body) do
      {:ok, %{"jsonrpc" => "2.0", "id" => _id, "result" => _result} = msg} ->
        Protocol.parse_response(msg)

      {:ok, %{"jsonrpc" => "2.0", "id" => _id, "error" => error}} ->
        {:error, error}

      {:ok, %{"result" => result}} ->
        {:ok, result}

      {:ok, other} ->
        {:error, "unexpected HTTP response: #{truncate(inspect(other), 200)}"}

      {:error, reason} ->
        {:error, "Invalid JSON response: #{inspect(reason)}"}
    end
  end

  # Req auto-decodes JSON, so body may already be a map
  def parse_http_response(%{"jsonrpc" => "2.0", "id" => _id, "result" => _result} = msg) do
    Protocol.parse_response(msg)
  end

  def parse_http_response(%{"jsonrpc" => "2.0", "id" => _id, "error" => error}),
    do: {:error, error}

  def parse_http_response(%{"result" => result}), do: {:ok, result}

  def parse_http_response(other),
    do: {:error, "unexpected response body type: #{truncate(inspect(other), 200)}"}

  defp truncate(string, max_len) do
    if String.length(string) > max_len do
      String.slice(string, 0, max_len) <> "..."
    else
      string
    end
  end

  # ---------------------------------------------------------------------------
  # Shared
  # ---------------------------------------------------------------------------

  defp normalize_tool_result(%{"isError" => true} = result) do
    {:ok, text, details} = normalize_tool_result(Map.delete(result, "isError"))
    {:error, text, details}
  end

  defp normalize_tool_result(%{"content" => content} = result) when is_binary(content) do
    {:ok, content, Map.drop(result, ["content", "isError"])}
  end

  defp normalize_tool_result(%{"content" => content} = result) when is_list(content) do
    text =
      Enum.map_join(content, fn
        %{"type" => "text", "text" => text} -> text
        %{"type" => "image"} -> "[MCP image observation]"
        %{"text" => text} -> text
        %{"type" => type} -> "[Unsupported MCP content: #{type}]"
        _ -> "[Unsupported MCP content]"
      end)

    images = content |> Enum.filter(&match?(%{"type" => "image"}, &1)) |> Enum.take(2)
    {:ok, text, Map.drop(result, ["content", "isError"]) |> Map.put(:image_blocks, images)}
  end

  defp normalize_tool_result(%{"error" => error}), do: {:error, format_error(error)}
  defp normalize_tool_result(other), do: {:ok, inspect(other), %{raw: other}}

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp app_version do
    case Application.spec(:handbean, :vsn) do
      nil -> "unknown"
      vsn -> to_string(vsn)
    end
  end

  defp safe_close_port(port) do
    if is_port(port) and Port.info(port) != nil do
      Port.close(port)
    end
  rescue
    _ -> :ok
  end
end
