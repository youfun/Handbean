defmodule Handbean.MCP.ConfigLoader do
  @moduledoc """
  Loads MCP server configurations from project and user-level JSON files.

  Handles JSON parsing, validation, merging across sources, env resolution,
  and secret-safe diagnostics. Returns a `Handbean.MCP.Config` struct.

  ## Usage

      {:ok, config} = ConfigLoader.load(project: "/path/to/project")
      {:ok, config} = ConfigLoader.load(user_config_path: "/path/to/mcp.json", project: "/path/to/project")

  ## Merge Priority (low to high)

      1. User config      (`~/.handbean/mcp.json` or explicit `:user_config_path`)
      2. `.mcp.json`      (project root)
      3. `.handbean/mcp.json` (Handbean-specific project config)

  Same-named servers are fully replaced by the higher-priority source.
  """

  alias Handbean.MCP.{Config, ServerConfig, Diagnostic}

  @source_user :user
  @source_project_mcp :project_mcp
  @source_project_sigil :project_sigil

  @valid_name_re ~r/^[a-z0-9_-]+$/

  @doc """
  Load MCP server configurations.

  ## Options

    * `:project` — project directory path (required for project-level config)
    * `:user_config_path` — path to user-level MCP JSON config (defaults to `~/.handbean/mcp.json`;
      pass `nil` explicitly to disable user-level config)
    * `:user_home` — home directory used to resolve the default user config path (optional)
  """
  @spec load(keyword()) :: {:ok, Config.t()}
  def load(opts) do
    project = Keyword.get(opts, :project)
    user_path = user_config_path(opts)

    sources = build_sources(user_path, project)
    {servers, diagnostics} = load_sources(sources)
    {user_servers, _} = if user_path, do: load_one_source(:user, user_path), else: {%{}, []}
    workspace_id = Keyword.get(opts, :workspace_id)

    active =
      servers
      |> Enum.reject(fn {name, cfg} ->
        global = Map.get(user_servers, name)

        cfg.disabled or not workspace_allowed?(cfg, workspace_id) or
          (global != nil and (global.disabled or not workspace_allowed?(global, workspace_id))) or
          (not Handbean.Host.shell?() and is_nil(cfg.url))
      end)
      |> Map.new(fn {name, cfg} ->
        scope =
          if cfg.oauth,
            do: [project: project, workspace_id: workspace_id, user_config_path: user_path]

        {name, %{cfg | oauth_scope: scope}}
      end)

    {:ok, %Config{servers: active, diagnostics: diagnostics}}
  end

  # ---------------------------------------------------------------------------
  # Source Collection
  # ---------------------------------------------------------------------------

  defp user_config_path(opts) do
    if Keyword.has_key?(opts, :user_config_path) do
      Keyword.get(opts, :user_config_path)
    else
      if Keyword.has_key?(opts, :user_home),
        do: Path.join(Keyword.fetch!(opts, :user_home), ".handbean/mcp.json"),
        else: Handbean.MCP.Settings.path()
    end
  end

  defp workspace_allowed?(cfg, workspace_id) do
    case Map.get(cfg.raw, "workspace_access") do
      nil ->
        true

      %{"mode" => "all"} ->
        true

      %{"mode" => "selected", "workspace_ids" => ids} when is_list(ids) ->
        is_binary(workspace_id) and workspace_id in ids

      _ ->
        false
    end
  end

  defp build_sources(nil, nil), do: []

  defp build_sources(user_path, project) do
    []
    |> maybe_add_user(user_path)
    |> maybe_add_mcp(project, ".mcp.json", @source_project_mcp)
    |> maybe_add_mcp(project, ".handbean/mcp.json", @source_project_sigil)
    |> Enum.reverse()
  end

  defp maybe_add_user(sources, nil), do: sources
  defp maybe_add_user(sources, path), do: [{@source_user, path} | sources]

  defp maybe_add_mcp(sources, nil, _rel, _tag), do: sources
  defp maybe_add_mcp(sources, project, rel, tag), do: [{tag, Path.join(project, rel)} | sources]

  # ---------------------------------------------------------------------------
  # Loading & Parsing
  # ---------------------------------------------------------------------------

  defp load_sources(sources) do
    {servers, acc_diags} =
      Enum.reduce(sources, {%{}, []}, fn {tag, path}, {acc_servers, acc_diags} ->
        {servers, diags} = load_one_source(tag, path)
        merged = Map.merge(acc_servers, servers)
        {merged, [diags | acc_diags]}
      end)

    {servers, acc_diags |> Enum.reverse() |> List.flatten()}
  end

  defp load_one_source(_tag, path) do
    case read_json(path) do
      {:ok, data} -> extract_servers(data, path)
      {:error, reason} -> {%{}, [diagnostic(:error, reason, path)]}
      :not_found -> {%{}, []}
    end
  end

  defp read_json(path) do
    case File.read(path) do
      {:ok, content} ->
        case Handbean.JSON.decode(content) do
          {:ok, data} -> {:ok, data}
          {:error, _} -> {:error, "Invalid JSON in #{path}"}
        end

      {:error, :enoent} ->
        :not_found

      {:error, _reason} ->
        {:error, "Cannot read MCP configuration: #{path}"}
    end
  end

  # ---------------------------------------------------------------------------
  # Extraction & Validation
  # ---------------------------------------------------------------------------

  defp extract_servers(data, source) do
    case data do
      %{"mcpServers" => servers} when is_map(servers) ->
        validate_servers(servers, source)

      %{"mcpServers" => _} ->
        {%{}, [diagnostic(:error, "mcpServers must be a map in #{source}", source)]}

      _ ->
        {%{}, [diagnostic(:warning, "No mcpServers key in #{source}", source)]}
    end
  end

  defp validate_servers(servers, source) do
    {servers, acc_diags} =
      Enum.reduce(servers, {%{}, []}, fn {name, raw_cfg}, {acc_servers, acc_diags} ->
        case validate_server(name, raw_cfg, source) do
          {:ok, server_config} -> {Map.put(acc_servers, name, server_config), acc_diags}
          {:error, diags} -> {acc_servers, [diags | acc_diags]}
        end
      end)

    {servers, acc_diags |> Enum.reverse() |> List.flatten()}
  end

  @doc "Validate one catalog entry using the same contract as file configuration."
  def validate_server(name, raw_cfg, source) when is_map(raw_cfg) do
    transport_kind = transport_kind(raw_cfg)

    errors =
      validate_name(name, source) ++
        validate_server_type(raw_cfg, name, source, transport_kind) ++
        validate_maps(raw_cfg, name, source) ++
        validate_exposure(raw_cfg, name, source) ++
        validate_oauth(raw_cfg, name, source)

    if errors != [] do
      {:error, errors}
    else
      case validate_args(raw_cfg, name, source) do
        {:ok, args} -> {:ok, build_server_config(name, raw_cfg, args, source)}
        errors when is_list(errors) -> {:error, errors}
      end
    end
  end

  def validate_server(name, _raw_cfg, source),
    do: {:error, [diagnostic(:error, "Server configuration must be an object", source, name)]}

  defp validate_oauth(raw, name, source) do
    case Handbean.MCP.OAuth.Config.validate(raw) do
      :ok -> []
      {:error, message} -> [diagnostic(:error, message, source, name)]
    end
  end

  defp validate_maps(raw, name, source) do
    Enum.flat_map(["headers", "env"], fn key ->
      value = Map.get(raw, key, %{})

      if is_map(value) and Enum.all?(value, fn {k, v} -> is_binary(k) and is_binary(v) end),
        do: [],
        else: [diagnostic(:error, "#{key} must be an object of strings", source, name)]
    end)
  end

  # ---------------------------------------------------------------------------
  # Transport / Server Type Detection
  # ---------------------------------------------------------------------------

  defp transport_kind(raw_cfg) do
    cond do
      is_binary(raw_cfg["url"]) and raw_cfg["url"] != "" -> :http
      is_binary(raw_cfg["command"]) and raw_cfg["command"] != "" -> :stdio
      true -> :unknown
    end
  end

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

  defp validate_server_type(_raw_cfg, _name, _source, :http), do: []

  defp validate_server_type(raw_cfg, name, source, :stdio) do
    validate_command(raw_cfg, name, source)
  end

  defp validate_server_type(raw_cfg, name, source, :unknown) do
    missing = if raw_cfg["command"] == nil, do: ["command"], else: []
    missing = if raw_cfg["url"] == nil, do: ["url" | missing], else: missing

    if missing != [] do
      [
        diagnostic(
          :error,
          "Server must have command or url: #{Enum.join(missing, ", ")}",
          source,
          name
        )
      ]
    else
      []
    end
  end

  defp validate_args(raw_cfg, name, source) do
    args = raw_cfg["args"]

    cond do
      is_nil(args) -> {:ok, []}
      is_list(args) -> {:ok, args}
      true -> [diagnostic(:error, "args must be a list for server \"#{name}\"", source, name)]
    end
  end

  defp validate_name(name, source) do
    cond do
      not is_binary(name) or name == "" ->
        [diagnostic(:error, "Server name must be a non-empty string", source)]

      not String.match?(name, @valid_name_re) ->
        [
          diagnostic(
            :error,
            "Invalid server name \"#{name}\": only lowercase letters, digits, hyphens, underscores allowed",
            source,
            name
          )
        ]

      true ->
        []
    end
  end

  @exposures ["direct", "deferred", "nested"]

  defp validate_exposure(raw_cfg, name, source) do
    case Map.get(raw_cfg, "exposure", "deferred") do
      exposure when exposure in @exposures ->
        []

      _ ->
        [
          diagnostic(
            :error,
            "Invalid exposure for server \"#{name}\": expected \"direct\" or \"deferred\"",
            source,
            name
          )
        ]
    end
  end

  defp normalize_exposure("direct"), do: "direct"
  defp normalize_exposure(_exposure), do: "deferred"

  defp validate_command(raw_cfg, name, source) do
    cmd = raw_cfg["command"]

    if is_binary(cmd) and cmd != "" do
      []
    else
      [diagnostic(:error, "Missing or invalid command for server \"#{name}\"", source, name)]
    end
  end

  defp build_server_config(name, raw_cfg, args, source) do
    env = normalize_string_map(raw_cfg["env"])
    headers = normalize_string_map(raw_cfg["headers"])

    known = [
      "command",
      "args",
      "env",
      "disabled",
      "cwd",
      "transport",
      "type",
      "url",
      "headers",
      "oauth",
      "exposure",
      "description"
    ]

    %ServerConfig{
      name: name,
      command: raw_cfg["command"],
      args: args,
      env: env,
      runtime_env: resolve_placeholders(env),
      disabled: raw_cfg["disabled"] == true,
      cwd: raw_cfg["cwd"],
      transport: raw_cfg["transport"] || "stdio",
      type: raw_cfg["type"],
      url: raw_cfg["url"],
      headers: headers,
      oauth: raw_cfg["oauth"],
      runtime_headers: resolve_placeholders(headers),
      source: source,
      exposure: normalize_exposure(Map.get(raw_cfg, "exposure", "deferred")),
      description: server_description(raw_cfg["description"]),
      raw: Map.drop(raw_cfg, known)
    }
  end

  # ---------------------------------------------------------------------------
  # Env Resolution
  # ---------------------------------------------------------------------------

  defp server_description(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp server_description(_text), do: nil

  defp resolve_placeholders(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      {k, resolve_value(v)}
    end)
  end

  defp resolve_value("env:" <> var) do
    System.get_env(var) || ""
  end

  defp resolve_value(value), do: value

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp normalize_string_map(nil), do: %{}
  defp normalize_string_map(map) when is_map(map), do: map
  defp normalize_string_map(_), do: %{}

  defp diagnostic(type, message, source, server \\ nil) do
    %Diagnostic{
      type: type,
      message: message,
      source: source,
      server: server
    }
  end
end
