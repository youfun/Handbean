defmodule Handbean.MCP.Access do
  @moduledoc "Workspace-scoped MCP discovery and invocation. Rechecks the effective file policy."

  alias Handbean.MCP.ConfigLoader

  def options(opts) do
    context = Keyword.get(opts, :context, %{})

    [
      project:
        if(Handbean.ProjectTrust.enabled?(opts) and Keyword.get(opts, :chat_scope) != :free,
          do: Keyword.get(opts, :working_directory, File.cwd!())
        ),
      workspace_id: Keyword.get(opts, :workspace_id, context[:workspace_id]),
      user_config_path: Keyword.get(opts, :mcp_user_config_path, Handbean.MCP.Settings.path())
    ]
  end

  def scope(opts),
    do: digest(Keyword.take(opts, [:project, :workspace_id, :user_config_path]) |> Enum.sort())

  # UI metadata/access edits must not invalidate connections still allowed elsewhere.
  def fingerprint(%Handbean.MCP.ServerConfig{} = config),
    do: config |> Map.drop([:raw, :oauth_scope, :runtime_capabilities]) |> digest()

  def fingerprint(value), do: digest(value)

  def config(opts) do
    {:ok, config} = ConfigLoader.load(opts)

    if Enum.any?(config.diagnostics, &(&1.type == :error)),
      do: %{config | servers: %{}},
      else: config
  end

  def filter(defs, context) do
    opts = context[:mcp_scope]
    servers = if opts, do: config(opts).servers, else: %{}
    entries = Handbean.Tool.Registry.tool_fns()

    Enum.filter(defs, fn definition ->
      if String.starts_with?(definition.name, "mcp__") do
        meta = get_in(entries, [definition.name, :meta]) || %{}

        opts != nil and meta[:scope] == scope(opts) and
          matches?(servers[meta[:server]], meta[:fingerprint])
      else
        true
      end
    end)
  end

  def allowed?(server, opts, context) do
    caller = context[:mcp_scope]

    caller != nil and scope(caller) == scope(opts) and
      matches?(config(opts).servers[server.name], fingerprint(server))
  end

  defp matches?(nil, _), do: false
  defp matches?(server, fingerprint), do: fingerprint(server) == fingerprint

  defp digest(value),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(value)) |> Base.encode16(case: :lower)
end
