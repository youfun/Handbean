defmodule Handbean.MCP.Settings do
  @moduledoc "Shared MCP catalog editing for native and web settings. Credentials never leave read APIs."

  alias Handbean.MCP.{ConfigLoader, ServerRuntime}

  def path(opts \\ []) do
    Keyword.get(
      opts,
      :user_config_path,
      Application.get_env(:handbean, :mcp_user_config_path) ||
        Path.join([Handbean.Home.path(), ".handbean", "mcp.json"])
    )
  end

  def read(opts \\ []) do
    case File.read(path(opts)) do
      {:ok, bytes} ->
        case Handbean.JSON.decode(bytes) do
          {:ok, %{"mcpServers" => servers} = data} when is_map(servers) ->
            if Enum.all?(servers, fn {id, value} -> valid_entry?(id, value) end),
              do: {:ok, data},
              else: {:error, "Invalid MCP server entry; fix the source file before editing"}

          _ ->
            {:error, "Invalid MCP configuration; fix the file before editing"}
        end

      {:error, :enoent} ->
        {:ok, %{"mcpServers" => %{}}}

      {:error, _} ->
        {:error, "Cannot read MCP configuration"}
    end
  end

  defp valid_entry?(id, value) when is_map(value) do
    valid_access =
      case value["workspace_access"] do
        nil ->
          true

        %{"mode" => "all"} ->
          true

        %{"mode" => "selected", "workspace_ids" => ids} when is_list(ids) ->
          Enum.all?(ids, &is_binary/1)

        _ ->
          false
      end

    valid_access and match?({:ok, _}, ConfigLoader.validate_server(id, value, :user))
  end

  defp valid_entry?(_, _), do: false

  def list(opts \\ []) do
    with {:ok, data} <- read(opts) do
      entries = Handbean.Tool.Registry.tool_fns() |> Map.values()

      {:ok,
       data["mcpServers"]
       |> Enum.sort_by(&elem(&1, 0))
       |> Enum.map(fn {id, raw} ->
         tools = connected_tools(entries, id, raw, path(opts))

         %{
           id: id,
           name: raw["name"] || id,
           url: raw["url"],
           description: raw["description"],
           transport: if(is_binary(raw["url"]), do: :http, else: :stdio),
           auth: auth(raw),
           oauth_configured: is_map(raw["oauth"]),
           disabled: raw["disabled"] == true,
           workspace_access:
             Map.get(raw, "workspace_access", %{"mode" => "all", "workspace_ids" => []}),
           status: if(tools == [], do: :not_connected, else: :connected),
           tool_count: length(tools),
           source: path(opts)
         }
       end)}
    end
  end

  defp connected_tools(entries, id, raw, source) do
    case ConfigLoader.validate_server(id, raw, source) do
      {:ok, cfg} ->
        fingerprint = Handbean.MCP.Access.fingerprint(cfg)

        entries
        |> Enum.filter(fn entry ->
          meta = entry.meta

          meta[:server] == id and meta[:fingerprint] == fingerprint and
            is_pid(meta[:runtime_pid]) and Process.alive?(meta.runtime_pid) and not cfg.disabled
        end)
        |> Enum.uniq_by(& &1.meta.remote_name)

      {:error, _} ->
        []
    end
  end

  def new_form(workspace_id) do
    %{
      "id" => nil,
      "name" => "",
      "url" => "",
      "auth" => "none",
      "token" => "",
      "headers_json" => "",
      "oauth_client_id" => "",
      "oauth_issuer" => "",
      "oauth_scopes" => "",
      "has_credentials" => false,
      "disabled" => false,
      "access_mode" => "selected",
      "workspace_ids" => List.wrap(workspace_id)
    }
  end

  def edit(id, opts \\ []) do
    with {:ok, data} <- read(opts),
         {:ok, raw} <- fetch(data, id),
         :ok <- editable(raw) do
      access = Map.get(raw, "workspace_access", %{"mode" => "all", "workspace_ids" => []})

      {:ok,
       Map.merge(new_form(nil), %{
         "id" => id,
         "name" => raw["name"] || id,
         "url" => raw["url"],
         "auth" => auth(raw),
         "oauth_client_id" => get_in(raw, ["oauth", "client_id"]) || "",
         "oauth_issuer" => get_in(raw, ["oauth", "issuer"]) || "",
         "oauth_scopes" => Enum.join(get_in(raw, ["oauth", "scopes"]) || [], " "),
         "has_credentials" => map_size(Map.get(raw, "headers", %{})) > 0,
         "disabled" => raw["disabled"] == true,
         "access_mode" => access["mode"],
         "workspace_ids" => Map.get(access, "workspace_ids", [])
       })}
    end
  end

  def save(form, opts \\ []) do
    update(opts, fn data ->
      with {:ok, id, raw} <- prepare(form, data) do
        {:ok, put_in(data, ["mcpServers", id], raw), {:ok, id}}
      end
    end)
  end

  def delete(id, opts \\ []) do
    update(opts, fn data ->
      with {:ok, _} <- fetch(data, id) do
        {:ok, update_in(data["mcpServers"], &Map.delete(&1, id)), :ok}
      end
    end)
  end

  def toggle_disabled(id, disabled, opts \\ []) when is_boolean(disabled) do
    update(opts, fn data ->
      with {:ok, raw} <- fetch(data, id),
           :ok <- editable(raw) do
        updated = Map.put(raw, "disabled", disabled)
        {:ok, put_in(data, ["mcpServers", id], updated), {:ok, id}}
      end
    end)
  end

  def test_connection(form, opts \\ [])

  def test_connection(%{"auth" => "oauth"}, _opts),
    do:
      {:error,
       "Save this server and authorize it in Plugins settings, then use it from the selected workspace."}

  def test_connection(form, opts) do
    with {:ok, data} <- read(opts),
         {:ok, id, raw} <- prepare(form, data),
         {:ok, cfg} <- ConfigLoader.validate_server(id, raw, :user) do
      # A temporary, unregistered runtime: testing must not grant tool access.
      case Handbean.MCP.start_runtime(server_config: cfg) do
        {:ok, pid} ->
          try do
            with {:ok, tools} <- ServerRuntime.tools(pid), do: {:ok, %{tool_count: length(tools)}}
          after
            ServerRuntime.shutdown(pid)
          end

        {:error, _} ->
          {:error, "Connection failed. Check the URL, authentication and server availability."}
      end
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, _} -> {:error, "Invalid MCP server configuration"}
    end
  catch
    :exit, _ -> {:error, "Connection failed or timed out"}
  end

  defp prepare(form, data) do
    id = form["id"]
    existing = if id in [nil, ""], do: {:ok, %{}}, else: fetch(data, id)

    with {:ok, old} <- existing,
         :ok <- editable(old),
         :ok <- validate_form(form),
         {:ok, headers} <- headers(form, old) do
      id = if id in [nil, ""], do: "server-" <> Ecto.UUID.generate(), else: id

      raw =
        Map.merge(old, %{
          "name" => String.trim(form["name"]),
          "url" => String.trim(form["url"]),
          "transport" => "http",
          "headers" => headers,
          "auth" => form["auth"],
          "disabled" => form["disabled"] == true,
          "workspace_access" => %{
            "mode" => form["access_mode"],
            "workspace_ids" => Enum.uniq(form["workspace_ids"])
          }
        })

      raw =
        if form["auth"] == "oauth",
          do: Map.put(raw, "oauth", oauth_config(form, old)),
          else: Map.delete(raw, "oauth")

      case Handbean.MCP.OAuth.Config.validate(raw) do
        :ok -> {:ok, id, raw}
        error -> error
      end
    end
  end

  defp oauth_config(form, old) do
    old
    |> Map.get("oauth", %{})
    |> Map.take(["resource_metadata_url"])
    |> Map.put("client_id", String.trim(form["oauth_client_id"] || ""))
    |> maybe_oauth_field("issuer", String.trim(form["oauth_issuer"] || ""))
    |> maybe_oauth_field("scopes", String.split(form["oauth_scopes"] || ""))
  end

  defp maybe_oauth_field(map, _key, value) when value in ["", []], do: map
  defp maybe_oauth_field(map, key, value), do: Map.put(map, key, value)

  defp validate_form(form) do
    uri = URI.parse(String.trim(form["url"] || ""))

    cond do
      not is_binary(form["name"]) or String.trim(form["name"]) == "" ->
        {:error, "Name is required"}

      uri.scheme not in ["http", "https"] or uri.host in [nil, ""] or uri.userinfo != nil or
          uri.fragment != nil ->
        {:error, "Enter an HTTP(S) URL without embedded credentials or a fragment"}

      form["auth"] not in ["none", "bearer", "headers", "oauth"] ->
        {:error, "Invalid authentication mode"}

      form["access_mode"] not in ["selected", "all"] ->
        {:error, "Invalid workspace access mode"}

      not is_list(form["workspace_ids"]) ->
        {:error, "Select valid workspaces"}

      not Enum.all?(form["workspace_ids"], &(is_binary(&1) and &1 != "")) ->
        {:error, "Invalid workspace ID"}

      true ->
        :ok
    end
  end

  defp headers(%{"auth" => mode}, _) when mode in ["none", "oauth"], do: {:ok, %{}}

  defp headers(%{"auth" => mode} = form, old) do
    value = if mode == "bearer", do: form["token"] || "", else: form["headers_json"] || ""

    cond do
      value == "" and auth(old) == mode and map_size(Map.get(old, "headers", %{})) > 0 ->
        old_url = URI.parse(old["url"])
        new_url = URI.parse(String.trim(form["url"]))

        if {old_url.scheme, old_url.host, old_url.port} ==
             {new_url.scheme, new_url.host, new_url.port},
           do: {:ok, old["headers"]},
           else: {:error, "Server origin changed. Re-enter credentials for the new server."}

      mode == "bearer" and String.trim(value) != "" and not String.contains?(value, ["\r", "\n"]) ->
        {:ok, %{"authorization" => "Bearer " <> String.trim(value)}}

      mode == "headers" ->
        decode_headers(value)

      true ->
        {:error, "Enter a token or choose no authentication"}
    end
  end

  defp decode_headers(value) do
    case Handbean.JSON.decode(value) do
      {:ok, headers} when is_map(headers) ->
        if Enum.all?(headers, fn {k, v} ->
             is_binary(v) and String.match?(k, ~r/^[A-Za-z0-9_-]+$/) and
               not String.contains?(v, ["\r", "\n"]) and
               String.downcase(k) not in [
                 "host",
                 "content-length",
                 "content-type",
                 "accept",
                 "mcp-session-id",
                 "mcp-protocol-version"
               ]
           end),
           do: {:ok, Map.new(headers, fn {k, v} -> {String.downcase(k), v} end)},
           else:
             {:error,
              "Headers must contain valid string values; protocol headers cannot be overridden"}

      _ ->
        {:error, "Headers must be a JSON object of strings"}
    end
  end

  defp auth(%{"oauth" => oauth}) when is_map(oauth), do: "oauth"

  defp auth(raw) do
    headers = Map.get(raw, "headers", %{})

    raw["auth"] ||
      cond do
        map_size(headers) == 0 ->
          "none"

        map_size(headers) == 1 and
            Enum.any?(headers, fn {k, v} ->
              String.downcase(k) == "authorization" and String.starts_with?(v, "Bearer ")
            end) ->
          "bearer"

        true ->
          "headers"
      end
  end

  defp editable(raw) do
    if Map.has_key?(raw, "command"),
      do: {:error, "Edit stdio servers in the source configuration file"},
      else: :ok
  end

  defp fetch(data, id) do
    case Map.fetch(data["mcpServers"], id) do
      {:ok, raw} -> {:ok, raw}
      :error -> {:error, "MCP server no longer exists"}
    end
  end

  defp update(opts, fun) do
    file = path(opts)

    :global.trans({{__MODULE__, file}, self()}, fn ->
      with {:ok, data} <- read(opts),
           {:ok, updated, result} <- fun.(data),
           :ok <- write(file, updated) do
        result
      end
    end)
  end

  defp write(file, data) do
    temporary = file <> "." <> Ecto.UUID.generate() <> ".tmp"

    try do
      with :ok <- File.mkdir_p(Path.dirname(file)),
           {:ok, io} <- File.open(temporary, [:write, :exclusive, :binary]) do
        result =
          with :ok <- File.chmod(temporary, 0o600),
               :ok <- IO.binwrite(io, Handbean.JSON.encode!(data)),
               :ok <- :file.sync(io),
               do: :ok

        File.close(io)
        with :ok <- result, do: File.rename(temporary, file)
      end
      |> case do
        :ok -> :ok
        {:error, _} -> {:error, "Cannot save MCP configuration"}
      end
    after
      File.rm(temporary)
    end
  end
end
