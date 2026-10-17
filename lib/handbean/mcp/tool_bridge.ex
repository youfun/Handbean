defmodule Handbean.MCP.ToolBridge do
  @moduledoc """
  Bridges MCP server tools into Handbean.Tool.Registry as virtual tools.
  """

  alias Handbean.MCP.ServerConfig

  @spec discover_server_tools(pid()) ::
          {:ok, [Handbean.MCP.ServerRuntime.tool_spec()]} | {:error, term()}
  def discover_server_tools(runtime_pid), do: Handbean.MCP.ServerRuntime.tools(runtime_pid)

  @spec register_server_tools(pid(), ServerConfig.t(), keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def register_server_tools(runtime_pid, server_config, opts \\ [])

  def register_server_tools(runtime_pid, %ServerConfig{} = config, opts) do
    with {:ok, tools} <- discover_server_tools(runtime_pid) do
      register_discovered_tools(runtime_pid, config, tools, opts)
    end
  end

  @spec register_discovered_tools(
          pid(),
          ServerConfig.t(),
          [Handbean.MCP.ServerRuntime.tool_spec()],
          keyword()
        ) ::
          {:ok, [String.t()]} | {:error, term()}
  def register_discovered_tools(
        runtime_pid,
        %ServerConfig{name: server_name} = config,
        tools,
        opts \\ []
      )
      when is_list(tools) do
    scope = Handbean.MCP.Access.scope(opts)

    Enum.reduce_while(tools, {:ok, []}, fn tool, {:ok, registered} ->
      name = namespaced_name(server_name <> "_" <> String.slice(scope, 0, 12), tool.name)

      namespaced =
        if byte_size(name) > 64,
          do:
            String.slice(name, 0, 43) <>
              "_" <> String.slice(Handbean.MCP.Access.fingerprint(name), 0, 20),
          else: name

      executor = fn input, context ->
        if Handbean.MCP.Access.allowed?(config, opts, context) do
          timeout_ms = mcp_timeout(context)
          Handbean.MCP.ServerRuntime.call_tool(runtime_pid, tool.name, input, timeout_ms)
        else
          {:error, "MCP server is disabled, changed, or not allowed in this workspace"}
        end
      end

      result =
        Handbean.Tool.Registry.register_virtual(
          namespaced,
          tool.description,
          tool.input_schema,
          executor,
          deferred?: config.exposure != "direct",
          meta: %{
            source: :mcp,
            server: server_name,
            remote_name: tool.name,
            scope: scope,
            exposure: config.exposure,
            server_description: config.description,
            fingerprint: Handbean.MCP.Access.fingerprint(config),
            runtime_pid: runtime_pid
          }
        )

      case result do
        :ok ->
          {:cont, {:ok, [namespaced | registered]}}

        {:error, reason} ->
          Enum.each(registered, &Handbean.Tool.Registry.unregister/1)
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, registered} -> {:ok, Enum.reverse(registered)}
      {:error, _reason} = error -> error
    end
  end

  def unregister_server_tools(_server_name, tool_names \\ nil) do
    case tool_names do
      nil ->
        :ok

      names when is_list(names) ->
        Enum.each(names, &Handbean.Tool.Registry.unregister/1)
        :ok
    end
  end

  defp mcp_timeout(context) when is_map(context) do
    remaining =
      case context[:run_deadline] do
        deadline when is_integer(deadline) ->
          max(deadline - System.monotonic_time(:millisecond), 1)

        _ ->
          nil
      end

    tool_cap = context[:tool_timeout] || 60_000
    if is_integer(remaining), do: min(tool_cap, remaining), else: tool_cap
  end

  defp mcp_timeout(_context), do: 60_000

  def namespaced_name(server_name, tool_name) do
    "mcp__#{server_name}__#{tool_name}"
  end
end
