defmodule HandbeanWeb.MCPOAuthController do
  use HandbeanWeb, :controller

  alias Handbean.MCP.OAuth

  def start(conn, %{"workspace_id" => workspace, "server" => server}) do
    canonical = URI.parse(HandbeanWeb.Endpoint.url())

    if {Atom.to_string(conn.scheme), conn.host, conn.port} ==
         {canonical.scheme, canonical.host, canonical.port} do
      start_authorization(conn, workspace, server)
    else
      conn
      |> private_response()
      |> redirect(
        external:
          HandbeanWeb.Endpoint.url() <>
            "/settings?tab=plugins&workspace_id=" <> URI.encode_www_form(workspace)
      )
    end
  end

  defp start_authorization(conn, workspace, server) do
    browser = get_session(conn, :mcp_oauth_browser) || random()
    callback = HandbeanWeb.Endpoint.url() <> "/mcp/oauth/callback"

    with {:ok, cfg} <- OAuth.config(workspace, server),
         {:ok, url} <- OAuth.begin(cfg, browser, callback) do
      conn
      |> private_response()
      |> put_session(:mcp_oauth_browser, browser)
      |> redirect(external: url)
    else
      _ ->
        failure(
          conn,
          "Cannot start authorization. Check the OAuth client registration and server metadata."
        )
    end
  end

  def callback(conn, params) do
    case OAuth.complete(params["state"], get_session(conn, :mcp_oauth_browser), params) do
      {:ok, workspace, _} ->
        conn
        |> private_response()
        |> put_flash(:info, "MCP authorization completed.")
        |> redirect(to: "/settings?tab=plugins&workspace_id=" <> URI.encode_www_form(workspace))

      _ ->
        failure(
          conn,
          "Authorization failed, expired or was denied. Start again from Plugins settings."
        )
    end
  end

  def disconnect(conn, %{"workspace_id" => workspace, "server" => server}) do
    case OAuth.disconnect(workspace, server) do
      :ok ->
        disconnected(conn, workspace, "MCP authorization disconnected and revoked.")

      {:ok, :local_disconnect_only} ->
        disconnected(
          conn,
          workspace,
          "MCP disconnected locally. Remote authorization may remain; revoke it in your provider account if needed."
        )

      _ ->
        failure(conn, "Could not disconnect MCP authorization.")
    end
  end

  defp disconnected(conn, workspace, message),
    do:
      conn
      |> private_response()
      |> put_flash(:info, message)
      |> redirect(to: "/settings?tab=plugins&workspace_id=" <> URI.encode_www_form(workspace))

  defp failure(conn, message),
    do:
      conn
      |> private_response()
      |> put_flash(:error, message)
      |> redirect(to: "/settings?tab=plugins")

  defp private_response(conn),
    do:
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("referrer-policy", "no-referrer")

  defp random, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
end
