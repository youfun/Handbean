defmodule HandbeanWeb.Router do
  use HandbeanWeb, :router
  use ErrorTracker.Web, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug HandbeanWeb.Access
    plug :fetch_live_flash
    plug :put_root_layout, html: {HandbeanWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :put_locale
    plug :put_theme
  end

  # query param > SQLite preference > session > Accept-Language > default
  defp put_locale(conn, _opts) do
    conn = Plug.Conn.fetch_query_params(conn)

    locale =
      HandbeanWeb.Locale.resolve(
        conn.query_params,
        get_session(conn, :locale),
        List.first(get_req_header(conn, "accept-language"))
      )

    Gettext.put_locale(Handbean.Gettext, locale)
    put_session(conn, :locale, locale)
  end

  defp put_theme(conn, _opts) do
    assign(conn, :theme, Handbean.Settings.UI.theme())
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :browser_api do
    plug :accepts, ["json"]
    plug :fetch_session
    plug HandbeanWeb.Access
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :put_locale
  end

  # The worker is a static script with no session data. Service worker requests
  # cannot add the XHR header required by Plug's JavaScript-response CSRF check.
  pipeline :service_worker do
    plug :fetch_session
    plug HandbeanWeb.Access
    plug :put_secure_browser_headers
  end

  scope "/", HandbeanWeb do
    pipe_through :service_worker
    get "/sw.js", WebPushController, :service_worker
  end

  scope "/api/web-push", HandbeanWeb do
    pipe_through :browser_api

    get "/config", WebPushController, :config
    post "/subscription", WebPushController, :create
    delete "/subscription", WebPushController, :delete
    post "/test", WebPushController, :test
  end

  scope "/", HandbeanWeb do
    get "/desktop-health", DesktopHealthController, :show
  end

  scope "/", HandbeanWeb do
    pipe_through :browser

    live "/", WorkspaceLive, :index
    live "/c/:conversation_id", WorkspaceLive, :free
    live "/w/:workspace_id/c/:conversation_id", WorkspaceLive, :index
    get "/settings/error-diagnostics", ErrorDiagnosticsController, :download
    live "/settings", SettingsLive, :index
    live "/settings/available-models", AvailableModelsLive, :index
    post "/mcp/oauth/:workspace_id/:server/start", MCPOAuthController, :start
    get "/mcp/oauth/callback", MCPOAuthController, :callback, log: false
    post "/mcp/oauth/:workspace_id/:server/disconnect", MCPOAuthController, :disconnect
    error_tracker_dashboard("/errors")

    get "/uploads/:conversation_id/:file", UploadsController, :show
    get "/media/:conversation_id/:media_id/content", MediaController, :show
    get "/workspace-files/:workspace_id/*path", WorkspaceMediaController, :show

    get "/preview/:id", PreviewController, :show
    get "/preview/:id/files", PreviewController, :files
    get "/preview/:id/files/*path", PreviewController, :files
    get "/preview/:id/port", PreviewController, :port
    get "/preview/:id/port/*path", PreviewController, :port
  end

  # Other scopes may use custom stacks.
  # scope "/api", HandbeanWeb do
  #   pipe_through :api
  # end
end
