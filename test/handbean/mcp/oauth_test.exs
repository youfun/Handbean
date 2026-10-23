defmodule Handbean.MCP.OAuthTest do
  use Handbean.DataCase, async: false
  import Phoenix.ConnTest
  @endpoint HandbeanWeb.Endpoint

  alias Handbean.MCP.{ConfigLoader, HTTP, OAuth, Settings}
  alias Handbean.MCP.OAuth.{Discovery, Network, Store}

  defmodule Fixture do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, opts) do
      conn = fetch_query_params(conn)
      state = opts[:state]
      config = Agent.get(state, & &1)
      base = "http://127.0.0.1:#{conn.port}"

      case {conn.method, conn.request_path} do
        {"POST", "/oversize"} ->
          send_resp(conn, 200, String.duplicate("x", 13 * 1024 * 1024))

        {"GET", "/mcp"} when is_map_key(config, :no_challenge) ->
          send_resp(conn, 401, "")

        {"GET", "/mcp"} ->
          conn
          |> put_resp_header(
            "www-authenticate",
            ~s(Bearer resource_metadata="#{base}/metadata", scope="read")
          )
          |> send_resp(401, "")

        {"GET", path} when path in ["/metadata", "/.well-known/oauth-protected-resource/mcp"] ->
          json(
            conn,
            Map.merge(
              %{
                "resource" => base <> "/mcp",
                "authorization_servers" => [base],
                "scopes_supported" => ["read"]
              },
              config[:resource] || %{}
            )
          )

        {"GET", "/.well-known/oauth-authorization-server"} when is_map_key(config, :oidc) ->
          send_resp(conn, 404, "")

        {"GET", path}
        when path in [
               "/.well-known/oauth-authorization-server",
               "/.well-known/openid-configuration"
             ] ->
          json(
            conn,
            Map.merge(
              %{
                "issuer" => base,
                "authorization_endpoint" => base <> "/authorize",
                "token_endpoint" => base <> "/token",
                "revocation_endpoint" => base <> "/revoke",
                "code_challenge_methods_supported" => ["S256"],
                "response_types_supported" => ["code"],
                "token_endpoint_auth_methods_supported" => ["none"],
                "authorization_response_iss_parameter_supported" => true
              },
              config[:metadata] || %{}
            )
          )

        {"GET", "/authorize"} ->
          params = conn.query_params
          Agent.update(state, &Map.put(&1, :authorization, params))

          conn
          |> put_resp_header(
            "location",
            params["redirect_uri"] <>
              "?" <>
              URI.encode_query(%{
                "code" => "fixture-code",
                "state" => params["state"],
                "iss" => base
              })
          )
          |> send_resp(302, "")

        {"POST", "/token"} ->
          {:ok, body, conn} = read_body(conn)
          params = URI.decode_query(body)
          send(config.owner, {:token_request, params})

          if config[:block_refresh] == true and params["grant_type"] == "refresh_token" do
            send(config.owner, {:refresh_blocked, self()})

            receive do
              :continue -> :ok
            end
          end

          cond do
            config[:token_redirect] ->
              conn |> put_resp_header("location", base <> "/leak") |> send_resp(307, "")

            config[:invalid_grant] ->
              conn
              |> put_status(400)
              |> json(%{
                "error" => "invalid_grant",
                "error_description" => "sensitive-server-message"
              })

            params["resource"] != base <> "/mcp" ->
              conn |> put_status(400) |> json(%{"error" => "invalid_target"})

            params["grant_type"] == "authorization_code" ->
              challenge =
                :crypto.hash(:sha256, params["code_verifier"])
                |> Base.url_encode64(padding: false)

              if challenge == config.authorization["code_challenge"] and
                   params["redirect_uri"] == config.authorization["redirect_uri"],
                 do: token(conn, config[:expires] || 3600, "access-secret", "refresh-secret"),
                 else: send_resp(conn, 400, "bad pkce")

            true ->
              Agent.update(state, &Map.update(&1, :refreshes, 1, fn n -> n + 1 end))
              token(conn, 3600, "new-access-secret", nil)
          end

        {"POST", "/revoke"} ->
          {:ok, body, conn} = read_body(conn)
          send(config.owner, {:revoked, URI.decode_query(body)})
          send_resp(conn, 200, "")

        {"POST", "/mcp"} when is_map_key(config, :slow) ->
          send(config.owner, :streaming)
          conn |> send_chunked(200) |> trickle()

        {"POST", "/mcp"} ->
          {:ok, body, conn} = read_body(conn)
          message = Handbean.JSON.decode!(body)
          auth = get_req_header(conn, "authorization")
          send(config.owner, {:resource_request, auth})

          send(
            config.owner,
            {:resource_rpc, message["method"], get_in(message, ["params", "uri"])}
          )

          result = %{
            "jsonrpc" => "2.0",
            "id" => message["id"],
            "result" => %{"content" => [%{"type" => "text", "text" => "ok"}]}
          }

          result =
            if config[:echo],
              do:
                put_in(
                  result,
                  ["result", "content", Access.at(0), "text"],
                  "access-secret refresh-secret"
                ),
              else: result

          result = if config[:resource_mode], do: resource_result(message), else: result
          encoded = Handbean.JSON.encode!(result)

          encoded =
            if config[:escape],
              do: String.replace(encoded, "access-secret", "\\u0061ccess-secret"),
              else: encoded

          encoded =
            if config[:multiline],
              do: String.replace(encoded, ",", ",\ndata: ", global: false),
              else: encoded

          encoded = if config[:sse], do: "data: " <> encoded <> "\n\n", else: encoded
          conn |> put_resp_header("mcp-session-id", "access-secret") |> send_resp(200, encoded)

        {_, "/leak"} ->
          send(config.owner, :leaked)
          send_resp(conn, 200, "")

        _ ->
          send_resp(conn, 404, "")
      end
    end

    defp resource_result(message) do
      result =
        case message["method"] do
          "server/discover" ->
            %{
              "resultType" => "complete",
              "supportedVersions" => ["2026-07-28"],
              "capabilities" => %{"resources" => %{}}
            }

          "resources/read" ->
            %{"contents" => [%{"uri" => message["params"]["uri"], "text" => "ok"}]}
        end

      %{"jsonrpc" => "2.0", "id" => message["id"], "result" => result}
    end

    defp trickle(conn) do
      Process.send_after(self(), :tick, 20)

      receive do
        :tick ->
          case chunk(conn, ": heartbeat\n\n") do
            {:ok, conn} -> trickle(conn)
            {:error, _} -> conn
          end
      end
    end

    defp token(conn, expires, access, refresh),
      do:
        json(conn, %{
          "access_token" => access,
          "refresh_token" => refresh,
          "token_type" => "Bearer",
          "expires_in" => expires
        })

    defp json(conn, data),
      do:
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(conn.status || 200, Handbean.JSON.encode!(data))
  end

  setup do
    root = Path.join(System.tmp_dir!(), "mcp-oauth-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)

    env =
      Map.new(
        [
          :mcp_oauth_directory,
          :mcp_user_config_path,
          :workspaces_file,
          :trust_project_code,
          :host
        ],
        &{&1, Application.fetch_env(:handbean, &1)}
      )

    old_ws = System.get_env("HANDBEAN_WORKSPACES_FILE")
    System.put_env("HANDBEAN_WORKSPACES_FILE", Path.join(root, "workspaces.json"))
    Application.put_env(:handbean, :workspaces_file, Path.join(root, "workspaces.json"))

    Application.put_env(
      :handbean,
      :mcp_oauth_directory,
      Path.join([root, ".handbean", "mcp-oauth"])
    )

    Application.put_env(
      :handbean,
      :host,
      Map.put(Application.get_env(:handbean, :host, %{}), :mcp, true)
    )

    Application.put_env(:handbean, :mcp_user_config_path, Path.join(root, "mcp.json"))
    Application.put_env(:handbean, :trust_project_code, false)
    {:ok, workspace} = Handbean.WorkspaceStore.add(root, name: "OAuth test")
    owner = self()
    state = start_supervised!({Agent, fn -> %{owner: owner} end})

    server =
      start_supervised!(
        {Bandit,
         plug: {Fixture, [state: state]},
         ip: {127, 0, 0, 1},
         port: 0,
         thousand_island_options: [num_acceptors: 1]}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    base = "http://127.0.0.1:#{port}"

    form =
      Settings.new_form(workspace["id"])
      |> Map.merge(%{
        "name" => "OAuth fixture",
        "url" => base <> "/mcp",
        "auth" => "oauth",
        "oauth_client_id" => "handbean-test",
        "oauth_issuer" => base
      })

    {:ok, id} = Settings.save(form)
    {:ok, cfg} = OAuth.config(workspace["id"], id)

    on_exit(fn ->
      Enum.each(env, fn
        {key, {:ok, value}} -> Application.put_env(:handbean, key, value)
        {key, :error} -> Application.delete_env(:handbean, key)
      end)

      if old_ws,
        do: System.put_env("HANDBEAN_WORKSPACES_FILE", old_ws),
        else: System.delete_env("HANDBEAN_WORKSPACES_FILE")

      File.rm_rf!(root)
    end)

    %{root: root, state: state, cfg: cfg, base: base, workspace: workspace, id: id}
  end

  test "real HTTP discovery, PKCE consent callback, encrypted storage and MCP call", ctx do
    assert ctx.cfg.oauth_scope[:project] == nil
    assert OAuth.status(ctx.cfg) == :authorization_required
    assert {:error, message} = HTTP.call(ctx.cfg, "tools/call", %{})
    assert message =~ "authorization required"
    params = authorize(ctx.cfg)
    assert {:ok, _, _} = OAuth.complete(params["state"], "browser", params)
    assert OAuth.status(ctx.cfg) == :authorized
    assert {:ok, %{"content" => [%{"text" => "ok"}]}} = HTTP.call(ctx.cfg, "tools/call", %{})
    assert_receive {:token_request, token_request}
    assert token_request["resource"] == ctx.cfg.url
    assert token_request["code_verifier"] != ""
    assert_receive {:resource_request, ["Bearer access-secret"]}
    refute inspect(ctx.cfg) =~ "access-secret"

    for file <- Path.wildcard(Path.join(Store.directory(), "*")) do
      refute File.read!(file) =~ "access-secret"
      assert Bitwise.band(File.stat!(file).mode, 0o777) == 0o600
    end

    assert Bitwise.band(File.stat!(Store.directory()).mode, 0o777) == 0o700
    assert {:error, _} = OAuth.complete(params["state"], "browser", params)
  end

  test "wrong browser, issuer, denied authorization and replay fail closed", ctx do
    params = authorize(ctx.cfg)
    assert {:error, _} = OAuth.complete(params["state"], "other-browser", params)
    assert {:error, _} = OAuth.complete(params["state"], "browser", Map.delete(params, "iss"))
    assert {:error, _} = OAuth.complete(params["state"], "browser", params)
    params = authorize(ctx.cfg)

    assert {:error, _} =
             OAuth.complete(params["state"], "browser", Map.put(params, "error", "access_denied"))

    assert OAuth.status(ctx.cfg) == :authorization_required
    refute_receive {:token_request, _}
  end

  test "configuration edits and cross-workspace calls cannot reuse authorization", ctx do
    params = authorize(ctx.cfg)
    {:ok, edit} = Settings.edit(ctx.id)
    {:ok, _} = Settings.save(Map.put(edit, "oauth_client_id", "changed"))
    assert {:error, _} = OAuth.complete(params["state"], "browser", params)
    assert {:error, _} = HTTP.call(ctx.cfg, "tools/call", %{})
    {:ok, _} = Settings.save(edit)
    params = authorize(ctx.cfg)
    assert {:ok, _, _} = OAuth.complete(params["state"], "browser", params)
    other = Path.join(ctx.root, "other")
    File.mkdir_p!(other)
    {:ok, workspace} = Handbean.WorkspaceStore.add(other)
    scope = Keyword.put(ctx.cfg.oauth_scope, :workspace_id, workspace["id"])
    assert {:error, _} = HTTP.call(%{ctx.cfg | oauth_scope: scope}, "tools/call", %{})
    assert {:ok, _} = ConfigLoader.load(scope)
    assert :ok = OAuth.disconnect(ctx.workspace["id"], ctx.id)
    assert_receive {:revoked, %{"token" => "refresh-secret"}}
    assert OAuth.status(ctx.cfg) == :authorization_required
  end

  test "concurrent refresh rotates once and disconnect prevents resurrection", ctx do
    Agent.update(ctx.state, &Map.put(&1, :expires, 1))
    params = authorize(ctx.cfg)
    assert {:ok, _, _} = OAuth.complete(params["state"], "browser", params)

    results =
      1..4
      |> Task.async_stream(fn _ -> HTTP.call(ctx.cfg, "tools/call", %{}) end, max_concurrency: 4)
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, {:ok, _}}, &1))
    assert Agent.get(ctx.state, & &1.refreshes) == 1
    assert :ok = OAuth.disconnect(ctx.cfg)
    assert_receive {:revoked, %{"token" => "refresh-secret"}}
    assert {:error, _} = HTTP.call(ctx.cfg, "tools/call", %{})
  end

  test "revoked refresh credentials require user authorization without response leakage", ctx do
    Agent.update(ctx.state, &Map.put(&1, :expires, 1))
    params = authorize(ctx.cfg)
    assert {:ok, _, _} = OAuth.complete(params["state"], "browser", params)
    Agent.update(ctx.state, &Map.put(&1, :invalid_grant, true))
    assert {:error, error} = HTTP.call(ctx.cfg, "tools/call", %{})
    refute error =~ "sensitive-server-message"
    assert OAuth.status(ctx.cfg) == :authorization_required
  end

  test "decoded JSON, SSE and header token reflection are scrubbed", ctx do
    params = authorize(ctx.cfg)
    assert {:ok, _, _} = OAuth.complete(params["state"], "browser", params)
    Agent.update(ctx.state, &Map.merge(&1, %{echo: true, escape: true}))
    assert {:ok, result} = HTTP.call(ctx.cfg, "tools/call", %{})
    refute inspect(result) =~ "access-secret"
    refute inspect(result) =~ "refresh-secret"
    Agent.update(ctx.state, &Map.merge(&1, %{sse: true, multiline: true}))
    assert {:ok, result} = HTTP.call(ctx.cfg, "tools/call", %{})
    refute inspect(result) =~ "access-secret"
    assert {:ok, response} = OAuth.request(ctx.cfg, %{"id" => 1}, %{}, 5000)
    refute inspect(response.headers) =~ "access-secret"
  end

  test "unsafe discovery, malformed metadata, missing issuer support and redirect token endpoint fail closed",
       ctx do
    for metadata <- [
          %{"token_endpoint_auth_methods_supported" => "none"},
          %{"authorization_response_iss_parameter_supported" => false},
          %{"token_endpoint" => "http://169.254.169.254/latest"}
        ] do
      Agent.update(ctx.state, &Map.put(&1, :metadata, metadata))
      assert {:error, _} = Discovery.discover(ctx.cfg)
    end

    Agent.update(ctx.state, &Map.put(&1, :metadata, %{}))
    Agent.update(ctx.state, &Map.put(&1, :resource, %{"resource" => ctx.base <> "/other"}))
    assert {:error, _} = Discovery.discover(ctx.cfg)
    Agent.update(ctx.state, &Map.put(&1, :resource, %{"scopes_supported" => "read"}))
    assert {:error, _} = Discovery.discover(ctx.cfg)
    Agent.update(ctx.state, &Map.merge(&1, %{resource: %{}, token_redirect: true}))
    params = authorize(ctx.cfg)
    assert {:error, _} = OAuth.complete(params["state"], "browser", params)
    refute_receive :leaked

    assert {:error, _} =
             Network.destination("http://127.0.0.1:1/private", "https://example.com/mcp")

    assert {:error, _} =
             Network.destination("https://169.254.169.254/private", "https://example.com/mcp")
  end

  test "disconnect clears authorization even after disabling and changing configuration", ctx do
    params = authorize(ctx.cfg)
    assert {:ok, _, _} = OAuth.complete(params["state"], "browser", params)
    {:ok, edit} = Settings.edit(ctx.id)

    {:ok, _} =
      Settings.save(Map.merge(edit, %{"disabled" => true, "oauth_client_id" => "changed"}))

    assert :ok = OAuth.disconnect(ctx.workspace["id"], ctx.id)
    {:ok, _} = Settings.save(edit)
    assert OAuth.status(ctx.cfg) == :authorization_required
  end

  test "browser start and callback routes complete consent without exposing token or code logs",
       ctx do
    conn = browser_conn()

    conn =
      post(
        conn,
        HandbeanWeb.Endpoint.url() <> "/mcp/oauth/#{ctx.workspace["id"]}/#{ctx.id}/start"
      )

    [url] = Plug.Conn.get_resp_header(conn, "location")
    assert String.starts_with?(url, ctx.base <> "/authorize?")
    {:ok, consent} = Req.get(url, redirect: false)
    [callback] = Req.Response.get_header(consent, "location")
    params = URI.parse(callback).query |> URI.decode_query()

    logs =
      ExUnit.CaptureLog.capture_log(fn ->
        done = conn |> recycle() |> get("/mcp/oauth/callback?" <> URI.encode_query(params))
        assert redirected_to(done) == "/settings?tab=plugins&workspace_id=" <> ctx.workspace["id"]
        assert Plug.Conn.get_resp_header(done, "cache-control") == ["no-store"]
      end)

    refute logs =~ "fixture-code"
    refute logs =~ params["state"]
    refute logs =~ "access-secret"
    assert OAuth.status(ctx.cfg) == :authorized
  end

  test "expired state is consumed, and workspace removal invalidates pending authorization",
       ctx do
    params = authorize(ctx.cfg)
    key = "credential:" <> Store.digest({ctx.workspace["id"], ctx.id})
    {:ok, saved} = Store.get(key)
    :ok = Store.put(key, put_in(saved, ["pending", "expires"], 0))
    assert {:error, _} = OAuth.complete(params["state"], "browser", params)
    :ok = Store.put(key, saved)
    assert {:error, _} = OAuth.complete(params["state"], "browser", params)
    params = authorize(ctx.cfg)
    assert {:ok, _} = Handbean.WorkspaceStore.remove(ctx.workspace["id"])
    assert {:error, _} = OAuth.complete(params["state"], "browser", params)
    refute_receive {:token_request, _}
  end

  test "disconnect waits for in-flight refresh and permanently removes the rotated grant", ctx do
    Agent.update(ctx.state, &Map.merge(&1, %{expires: 1, block_refresh: true}))
    params = authorize(ctx.cfg)
    assert {:ok, _, _} = OAuth.complete(params["state"], "browser", params)
    request = Task.async(fn -> HTTP.call(ctx.cfg, "tools/call", %{}) end)
    assert_receive {:refresh_blocked, fixture}, 1000
    parent = self()

    disconnect =
      Task.async(fn ->
        send(parent, :disconnect_entered)
        OAuth.disconnect(ctx.cfg)
      end)

    assert_receive :disconnect_entered
    assert Task.yield(disconnect, 0) == nil
    send(fixture, :continue)
    assert {:ok, _} = Task.await(request)
    assert :ok = Task.await(disconnect)
    assert OAuth.status(ctx.cfg) == :authorization_required
    assert {:error, _} = HTTP.call(ctx.cfg, "tools/call", %{})
  end

  test "global grants work across project-trust modes but project overrides cannot reuse them",
       ctx do
    params = authorize(ctx.cfg)
    assert {:ok, _, _} = OAuth.complete(params["state"], "browser", params)
    opts = Keyword.put(ctx.cfg.oauth_scope, :project, ctx.workspace["path"])
    {:ok, loaded} = ConfigLoader.load(opts)
    assert {:ok, _} = HTTP.call(loaded.servers[ctx.id], "tools/call", %{})
    raw = %{"mcpServers" => %{ctx.id => %{"url" => ctx.cfg.url, "oauth" => ctx.cfg.oauth}}}
    File.write!(Path.join(ctx.workspace["path"], ".mcp.json"), Handbean.JSON.encode!(raw))
    {:ok, overridden} = ConfigLoader.load(opts)
    assert {:error, _} = HTTP.call(overridden.servers[ctx.id], "tools/call", %{})
  end

  test "routes reject missing CSRF and disabled host, and canonicalize origin before consent",
       ctx do
    conn = browser_conn()

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      conn
      |> Plug.Conn.delete_req_header("x-csrf-token")
      |> post("/mcp/oauth/#{ctx.workspace["id"]}/#{ctx.id}/start")
    end

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      conn
      |> Plug.Conn.delete_req_header("x-csrf-token")
      |> post("/mcp/oauth/#{ctx.workspace["id"]}/#{ctx.id}/disconnect")
    end

    redirected =
      conn
      |> Map.put(:host, "127.0.0.1")
      |> post("/mcp/oauth/#{ctx.workspace["id"]}/#{ctx.id}/start")

    assert redirected_to(redirected) ==
             HandbeanWeb.Endpoint.url() <>
               "/settings?tab=plugins&workspace_id=" <> ctx.workspace["id"]

    assert OAuth.status(ctx.cfg) == :authorization_required
    params = authorize(ctx.cfg)

    Application.put_env(
      :handbean,
      :host,
      Map.put(Application.get_env(:handbean, :host), :mcp, false)
    )

    assert {:error, _} = OAuth.complete(params["state"], "browser", params)
    assert {:error, _} = OAuth.begin(ctx.cfg, "browser", "http://localhost/mcp/oauth/callback")
    refute_receive {:token_request, _}
  end

  test "well-known protected-resource and OIDC discovery fallback work", ctx do
    Agent.update(ctx.state, &Map.merge(&1, %{no_challenge: true, oidc: true}))
    assert {:ok, metadata} = Discovery.discover(ctx.cfg)
    assert metadata["issuer"] == ctx.base
    params = authorize(ctx.cfg)
    assert {:ok, _, _} = OAuth.complete(params["state"], "browser", params)
  end

  test "HTTP bodies are bounded during receive before JSON decoding", ctx do
    cfg = %{ctx.cfg | url: ctx.base <> "/oversize", oauth: nil}

    assert {:error, "MCP HTTP response exceeded size limit"} =
             HTTP.call(cfg, "resources/read", %{})

    assert {:error, :response_too_large} =
             Network.request(:post, ctx.base <> "/oversize", ctx.cfg.url)
  end

  test "configuration revoked during refresh prevents the resource RPC", ctx do
    Agent.update(ctx.state, &Map.merge(&1, %{expires: 1, block_refresh: true}))
    params = authorize(ctx.cfg)
    assert {:ok, _, _} = OAuth.complete(params["state"], "browser", params)
    request = Task.async(fn -> HTTP.call(ctx.cfg, "tools/call", %{}) end)
    assert_receive {:refresh_blocked, fixture}, 1000
    assert {:ok, _} = Settings.toggle_disabled(ctx.id, true)
    send(fixture, :continue)
    assert {:error, _} = Task.await(request)
    refute_receive {:resource_request, _}
  end

  test "stream heartbeats cannot hold the credential lock beyond the request deadline", ctx do
    params = authorize(ctx.cfg)
    assert {:ok, _, _} = OAuth.complete(params["state"], "browser", params)
    Agent.update(ctx.state, &Map.put(&1, :slow, true))
    request = Task.async(fn -> HTTP.call(ctx.cfg, "tools/call", %{}, 100) end)
    assert_receive :streaming, 1000
    disconnect = Task.async(fn -> OAuth.disconnect(ctx.cfg) end)
    assert {:error, _} = Task.await(request, 1500)
    assert :ok = Task.await(disconnect, 1500)
  end

  test "settings edits preserve explicit metadata discovery configuration", ctx do
    {:ok, data} = Settings.read()

    data =
      put_in(
        data,
        ["mcpServers", ctx.id, "oauth", "resource_metadata_url"],
        ctx.base <> "/metadata"
      )

    File.write!(Settings.path(), Handbean.JSON.encode!(data))
    {:ok, form} = Settings.edit(ctx.id)
    assert {:ok, _} = Settings.save(Map.put(form, "name", "Renamed"))
    {:ok, updated} = Settings.read()

    assert get_in(updated, ["mcpServers", ctx.id, "oauth", "resource_metadata_url"]) ==
             ctx.base <> "/metadata"
  end

  test "Resources deadline cancels a credential-lock waiter without a late RPC", ctx do
    context = warm_resources(ctx)
    parent = self()
    key = "credential:" <> Store.digest({ctx.workspace["id"], ctx.id})

    blocker =
      Task.async(fn ->
        Store.lock(key, fn ->
          send(parent, :credential_locked)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :credential_locked

    assert {:error, "MCP resource request timed out"} =
             Handbean.MCP.Resources.read_resource(
               %{"server" => ctx.id, "uri" => "memo://expired-lock"},
               Map.put(context, :tool_timeout, 100)
             )

    send(blocker.pid, :release)
    assert :ok = Task.await(blocker)

    assert {:ok, _} =
             Handbean.MCP.Resources.read_resource(
               %{"server" => ctx.id, "uri" => "memo://after-lock"},
               context
             )

    refute_received {:resource_rpc, "resources/read", "memo://expired-lock"}
    assert_received {:resource_rpc, "resources/read", "memo://after-lock"}
  end

  test "Resources deadline cancels an in-flight refresh without a late RPC", ctx do
    context = warm_resources(ctx)
    key = "credential:" <> Store.digest({ctx.workspace["id"], ctx.id})
    {:ok, saved} = Store.get(key)
    :ok = Store.put(key, put_in(saved, ["token", "expires_at"], 1))
    Agent.update(ctx.state, &Map.put(&1, :block_refresh, true))

    request =
      Task.async(fn ->
        Handbean.MCP.Resources.read_resource(
          %{"server" => ctx.id, "uri" => "memo://expired-refresh"},
          Map.put(context, :tool_timeout, 100)
        )
      end)

    assert_receive {:refresh_blocked, fixture}, 1000
    assert {:error, "MCP resource request timed out"} = Task.await(request, 1500)
    Agent.update(ctx.state, &Map.delete(&1, :block_refresh))
    send(fixture, :continue)

    assert {:ok, _} =
             Handbean.MCP.Resources.read_resource(
               %{"server" => ctx.id, "uri" => "memo://after-refresh"},
               context
             )

    refute_received {:resource_rpc, "resources/read", "memo://expired-refresh"}
    assert_received {:resource_rpc, "resources/read", "memo://after-refresh"}
  end

  defp warm_resources(ctx) do
    start_supervised!(Handbean.MCP.RuntimeSupervisor)
    start_supervised!(Handbean.MCP)
    params = authorize(ctx.cfg)
    assert {:ok, _, _} = OAuth.complete(params["state"], "browser", params)
    Agent.update(ctx.state, &Map.put(&1, :resource_mode, true))
    context = %{mcp_scope: ctx.cfg.oauth_scope, tool_timeout: 3000}

    assert {:ok, _} =
             Handbean.MCP.Resources.read_resource(
               %{"server" => ctx.id, "uri" => "memo://warm"},
               context
             )

    context
  end

  defp browser_conn do
    uri = URI.parse(HandbeanWeb.Endpoint.url())

    page =
      build_conn()
      |> Map.put(:host, uri.host)
      |> Map.put(:port, uri.port)
      |> HandbeanWeb.ConnCase.authenticate()
      |> get("/settings?tab=ui")

    [token] =
      page.resp_body
      |> Floki.parse_document!()
      |> Floki.attribute("meta[name='csrf-token']", "content")

    page
    |> recycle()
    |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
    |> Plug.Conn.put_req_header("x-csrf-token", token)
  end

  defp authorize(cfg) do
    assert {:ok, url} = OAuth.begin(cfg, "browser", "http://localhost/mcp/oauth/callback")
    query = URI.parse(url).query |> URI.decode_query()
    assert query["resource"] == cfg.url
    assert query["code_challenge_method"] == "S256"
    assert {:ok, response} = Req.get(url, redirect: false, retry: false)
    [location] = Req.Response.get_header(response, "location")
    URI.parse(location).query |> URI.decode_query()
  end
end
