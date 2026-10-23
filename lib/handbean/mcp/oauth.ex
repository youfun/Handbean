defmodule Handbean.MCP.OAuth do
  @moduledoc "Workspace-bound OAuth for MCP HTTP public clients. Tokens never enter server configuration."

  alias Handbean.MCP.{ConfigLoader, ServerConfig}
  alias Handbean.MCP.OAuth.{Discovery, Network, Store}

  @state_ttl 600

  def status(%ServerConfig{oauth: nil}), do: :not_configured

  def status(%ServerConfig{} = cfg) do
    case load(cfg) do
      {:ok, %{"token" => token}} ->
        if token["expires_at"] > now() or is_binary(token["refresh_token"]),
          do: :authorized,
          else: :authorization_required

      _ ->
        :authorization_required
    end
  end

  def begin(%ServerConfig{} = cfg, browser, redirect_uri) when is_binary(browser) do
    with :ok <- current(cfg),
         true <- callback_uri?(redirect_uri),
         {:ok, metadata} <- Discovery.discover(cfg) do
      Store.lock(credential_key(cfg), fn ->
        with :ok <- current(cfg),
             {:ok, existing} <- load(cfg),
             {:ok, previous} <- stored_or_empty(credential_key(cfg)) do
          if previous["binding"] != config_binding(cfg) do
            if pending = previous["pending"], do: Store.delete("state:" <> pending["state"])
            revoke_stored(previous)
          end

          state = random()
          verifier = random()

          pending = %{
            "state" => state,
            "verifier" => verifier,
            "browser" => Store.digest(browser),
            "expires" => now() + @state_ttl,
            "redirect_uri" => redirect_uri,
            "metadata" => metadata
          }

          pointer = %{
            "scope" => Map.new(cfg.oauth_scope, fn {k, v} -> {Atom.to_string(k), v} end),
            "server" => cfg.name,
            "binding" => config_binding(cfg)
          }

          with :ok <- Store.put("state:" <> state, pointer),
               :ok <- save(cfg, Map.put(existing, "pending", pending)) do
            if old = existing["pending"], do: Store.delete("state:" <> old["state"])
            challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

            query = %{
              "response_type" => "code",
              "client_id" => cfg.oauth["client_id"],
              "redirect_uri" => redirect_uri,
              "state" => state,
              "code_challenge" => challenge,
              "code_challenge_method" => "S256",
              "resource" => cfg.url,
              "scope" => Enum.join(metadata["scopes"], " ")
            }

            {:ok, metadata["authorization_endpoint"] <> "?" <> URI.encode_query(query)}
          end
        end
      end)
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_callback}
    end
  end

  def complete(state, browser, params)
      when is_binary(state) and byte_size(state) <= 128 and is_binary(browser) do
    Store.lock("state:" <> state, fn ->
      with {:ok, pointer} <- Store.get("state:" <> state),
           {:ok, cfg} <- from_pointer(pointer) do
        Store.lock(credential_key(cfg), fn ->
          with {:ok, data} <- load(cfg),
               %{"state" => ^state} = pending <- data["pending"],
               true <- pending["browser"] == Store.digest(browser),
               :ok <- Store.delete("state:" <> state),
               :ok <- save(cfg, Map.delete(data, "pending")),
               true <- pending["expires"] > now(),
               :ok <- current(cfg),
               :ok <- callback_result(params, pending),
               {:ok, token} <-
                 exchange(cfg, pending["metadata"], %{
                   "grant_type" => "authorization_code",
                   "code" => params["code"],
                   "code_verifier" => pending["verifier"],
                   "redirect_uri" => pending["redirect_uri"]
                 }),
               :ok <- current(cfg),
               :ok <-
                 save(cfg, %{"token" => token, "metadata" => pending["metadata"]}) do
            {:ok, cfg.oauth_scope[:workspace_id], cfg.name}
          else
            _ -> {:error, :authorization_failed}
          end
        end)
      else
        _ -> {:error, :invalid_authorization_state}
      end
    end)
  end

  def complete(_, _, _), do: {:error, :invalid_authorization_state}

  def disconnect(%ServerConfig{} = cfg), do: disconnect(cfg.oauth_scope[:workspace_id], cfg.name)

  def disconnect(workspace_id, server) do
    key = identity_key(workspace_id, server)

    Store.lock(key, fn ->
      with {:ok, data} <- stored_or_empty(key), :ok <- Store.delete(key) do
        if pending = data["pending"], do: Store.delete("state:" <> pending["state"])
        revoke_stored(data)
      end
    end)
  end

  # Keeps credentials inside the transport owner and scrubs reflected credentials
  # before either success data or error bodies reach the MCP runtime/trajectory.
  def request(%ServerConfig{} = cfg, payload, headers, timeout) do
    Store.lock(credential_key(cfg), fn ->
      with :ok <- current(cfg),
           {:ok, token} <- access_token(cfg),
           :ok <- current(cfg),
           {:ok, response} <-
             Network.request(:post, cfg.url, cfg.url,
               body: Handbean.JSON.encode!(payload),
               headers: Map.put(headers, "authorization", "Bearer " <> token["access_token"]),
               receive_timeout: timeout,
               max_response_bytes: 12 * 1024 * 1024
             ) do
        response = %{
          response
          | body: scrub_body(response.body, token),
            headers: scrub(response.headers, token)
        }

        if response.status == 401, do: {:error, :authorization_required}, else: {:ok, response}
      end
    end)
  end

  def config(workspace_id, server) do
    with {:ok, workspace} <- Handbean.WorkspaceStore.get(workspace_id) do
      opts =
        Handbean.MCP.Access.options(
          workspace_id: workspace_id,
          working_directory: workspace["path"]
        )

      lookup(opts, server)
    end
  end

  defp credential_key(cfg), do: identity_key(cfg.oauth_scope[:workspace_id], cfg.name)

  defp identity_key(workspace_id, server),
    do: "credential:" <> Store.digest({workspace_id, server})

  defp config_binding(cfg),
    do: Store.digest({cfg.oauth_scope[:workspace_id], cfg.name, cfg.url, cfg.source, cfg.oauth})

  defp current(%ServerConfig{oauth: oauth, oauth_scope: scope} = cfg)
       when is_map(oauth) and is_list(scope) do
    with true <- Handbean.Host.mcp?(),
         true <- is_binary(scope[:workspace_id]),
         :ok <- workspace_scope(scope),
         true <- cfg.source == scope[:user_config_path] or Handbean.ProjectTrust.enabled?(),
         {:ok, effective} <- lookup(scope, cfg.name),
         true <- config_binding(effective) == config_binding(cfg) do
      :ok
    else
      _ -> {:error, :oauth_configuration_changed}
    end
  end

  defp current(_), do: {:error, :oauth_scope_required}

  defp workspace_scope(scope) do
    with {:ok, workspace} <- Handbean.WorkspaceStore.get(scope[:workspace_id]) do
      project = scope[:project]

      cond do
        is_nil(project) or project == workspace["path"] ->
          :ok

        true ->
          case Handbean.WorkspaceStore.get_by_path(project) do
            {:ok, %{"id" => id}} ->
              if id == scope[:workspace_id], do: :ok, else: {:error, :workspace_scope_changed}

            _ ->
              {:error, :workspace_scope_changed}
          end
      end
    end
  end

  defp lookup(opts, server) do
    with {:ok, loaded} <- ConfigLoader.load(opts),
         false <- Enum.any?(loaded.diagnostics, &(&1.type == :error)),
         %ServerConfig{oauth: oauth} = cfg when is_map(oauth) <- loaded.servers[server] do
      {:ok, cfg}
    else
      _ -> {:error, :oauth_server_unavailable}
    end
  end

  defp from_pointer(pointer) do
    scope = pointer["scope"]

    opts = [
      project: scope["project"],
      workspace_id: scope["workspace_id"],
      user_config_path: scope["user_config_path"]
    ]

    with {:ok, cfg} <- lookup(opts, pointer["server"]),
         true <- config_binding(cfg) == pointer["binding"],
         do: {:ok, cfg}
  end

  defp load(cfg) do
    with {:ok, data} <- stored_or_empty(credential_key(cfg)) do
      if data["binding"] == config_binding(cfg), do: {:ok, data}, else: {:ok, %{}}
    end
  end

  defp save(cfg, data) do
    Store.put(
      credential_key(cfg),
      Map.merge(data, %{
        "binding" => config_binding(cfg),
        "resource" => cfg.url,
        "client_id" => cfg.oauth["client_id"]
      })
    )
  end

  defp stored_or_empty(key) do
    case Store.get(key) do
      {:error, :not_found} -> {:ok, %{}}
      result -> result
    end
  end

  defp access_token(cfg) do
    with {:ok, data} <- load(cfg) do
      case data["token"] do
        %{"expires_at" => expiry} = token when expiry > 0 ->
          cond do
            expiry > now() + 30 -> {:ok, token}
            is_binary(token["refresh_token"]) -> refresh(cfg, data)
            expiry > now() -> {:ok, token}
            true -> {:error, :authorization_required}
          end

        _ ->
          {:error, :authorization_required}
      end
    end
  end

  defp refresh(cfg, data) do
    case exchange(cfg, data["metadata"], %{
           "grant_type" => "refresh_token",
           "refresh_token" => data["token"]["refresh_token"]
         }) do
      {:ok, token} ->
        token = Map.put_new(token, "refresh_token", data["token"]["refresh_token"])

        with :ok <- current(cfg),
             :ok <- save(cfg, Map.put(data, "token", token)),
             do: {:ok, token}

      {:error, :invalid_grant} ->
        save(cfg, Map.delete(data, "token"))
        {:error, :authorization_required}

      _ ->
        {:error, :oauth_refresh_failed}
    end
  end

  defp exchange(cfg, metadata, fields) do
    fields = Map.merge(fields, %{"client_id" => cfg.oauth["client_id"], "resource" => cfg.url})

    with {:ok, response} <-
           Network.request(:post, metadata["token_endpoint"], cfg.url,
             headers: %{
               "content-type" => "application/x-www-form-urlencoded",
               "accept" => "application/json"
             },
             body: URI.encode_query(fields)
           ) do
      case Handbean.JSON.decode(response.body) do
        {:ok, %{"error" => "invalid_grant"}} -> {:error, :invalid_grant}
        {:ok, token} when response.status == 200 -> validate_token(token)
        _ -> {:error, :token_exchange_failed}
      end
    end
  end

  defp validate_token(
         %{"access_token" => access, "token_type" => type, "expires_in" => expires} = token
       )
       when is_binary(access) and is_binary(type) and is_integer(expires) and expires > 0 do
    if String.downcase(type) == "bearer" and valid_token?(access) and
         (is_nil(token["refresh_token"]) or valid_token?(token["refresh_token"])) do
      {:ok,
       token
       |> Map.take(["access_token", "refresh_token"])
       |> Map.reject(fn {_key, value} -> is_nil(value) end)
       |> Map.put("expires_at", now() + expires)}
    else
      {:error, :invalid_token_response}
    end
  end

  defp validate_token(_), do: {:error, :invalid_token_response}

  defp valid_token?(value),
    do:
      is_binary(value) and byte_size(value) in 1..16_384 and
        not String.match?(value, ~r/[\x00-\x20\x7f]/)

  defp callback_result(%{"code" => code} = params, pending)
       when is_binary(code) and byte_size(code) in 1..8192 do
    if is_nil(params["error"]) and
         params["iss"] == pending["metadata"]["issuer"],
       do: :ok,
       else: {:error, :authorization_denied}
  end

  defp callback_result(_, _), do: {:error, :authorization_denied}

  defp revoke_stored(data) do
    cfg = %ServerConfig{url: data["resource"], oauth: %{"client_id" => data["client_id"]}}
    revoke(cfg, data)
  end

  defp revoke(cfg, %{"token" => token, "metadata" => %{"revocation_endpoint" => endpoint}})
       when is_binary(endpoint) do
    result =
      Network.request(:post, endpoint, cfg.url,
        headers: %{"content-type" => "application/x-www-form-urlencoded"},
        body:
          URI.encode_query(%{
            "token" => token["refresh_token"] || token["access_token"],
            "client_id" => cfg.oauth["client_id"]
          })
      )

    case result do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      _ -> {:ok, :local_disconnect_only}
    end
  end

  defp revoke(_, _), do: {:ok, :local_disconnect_only}

  defp callback_uri?(url) do
    case URI.new(url) do
      {:ok, %URI{path: "/mcp/oauth/callback", query: nil, fragment: nil, userinfo: nil} = uri} ->
        uri.scheme == "https" or
          (uri.scheme == "http" and uri.host in ["localhost", "127.0.0.1", "::1"])

      _ ->
        false
    end
  end

  defp scrub_body(body, token) do
    case Handbean.JSON.decode(body) do
      {:ok, json} ->
        Handbean.JSON.encode!(scrub(json, token))

      _ ->
        body
        |> String.replace("\r\n", "\n")
        |> String.split("\n\n")
        |> Enum.map_join("\n\n", fn event ->
          data =
            event
            |> String.split("\n")
            |> Enum.filter(&String.starts_with?(&1, "data:"))
            |> Enum.map_join("\n", &String.trim_leading(String.replace_prefix(&1, "data:", "")))

          case Handbean.JSON.decode(data) do
            {:ok, json} -> "data: " <> Handbean.JSON.encode!(scrub(json, token))
            _ -> ""
          end
        end)
    end
  end

  defp scrub(value, token) when is_binary(value), do: redact(value, token)
  defp scrub(value, token) when is_list(value), do: Enum.map(value, &scrub(&1, token))

  defp scrub(value, token) when is_map(value),
    do: Map.new(value, fn {k, v} -> {scrub(k, token), scrub(v, token)} end)

  defp scrub(value, _token), do: value

  defp redact(body, token) when is_binary(body) do
    Enum.reduce([token["access_token"], token["refresh_token"]], body, fn
      value, acc when is_binary(value) and value != "" -> String.replace(acc, value, "[REDACTED]")
      _, acc -> acc
    end)
  end

  defp random, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  defp now, do: System.system_time(:second)
end
