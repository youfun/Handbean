# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :handbean,
  ecto_repos: [Handbean.Repo],
  endpoint_adapter: HandbeanWeb.Endpoint,
  generators: [timestamp_type: :utc_datetime],
  session_store: Handbean.SessionStore.SQLite,
  telemetry_adapter: HandbeanWeb.Telemetry,
  chrome_relay_port: 17_643

config :error_tracker,
  repo: Handbean.Repo,
  otp_app: :handbean,
  filter: Handbean.ErrorTrackerFilter,
  enabled: true

# IANA zones ship inside Tz. No network and no disk writes at runtime.
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

# Configure the endpoint
config :handbean, HandbeanWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: HandbeanWeb.ErrorHTML, json: HandbeanWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Handbean.PubSub,
  live_view: [signing_salt: "Wkzn+39Y"]

# Keep the existing stylesheet order in the layout; build each source separately.
config :esbuild,
  version: "0.25.12",
  handbean: [
    args:
      ~w(js/app.js js/webgpu_probe_worker.js js/streaming_markdown/pele.worker.js css/app.css css/theme-system.css css/theme-light.css css/theme-dark.css css/workspace.css css/composer.css css/motion.css default.css --bundle --target=es2020 --outbase=. --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Erlang/OTP's built-in JSON implementation through Handbean's Phoenix adapter.
config :phoenix, :json_library, Handbean.JSON

# Keep browser capability URLs and OAuth credentials out of request parameter logs.
config :phoenix, :filter_parameters, [
  "password",
  "subscription",
  "endpoint",
  "p256dh",
  "auth",
  "code",
  "state",
  "access_token",
  "refresh_token",
  "code_verifier"
]

# ── Gettext i18n 配置 ──
config :handbean, Handbean.Gettext,
  default_locale: "zh_CN",
  locales: ~w(zh_CN en)

# ── HTTP client (Req/Finch): force HTTP/1.1 to avoid Finch pool hang ──
#
# Finch defaults to HTTP/2 which multiplexes requests over a single TCP
# connection. With long-lived connections to LLM providers (Anthropic,
# StepFun, OpenAI), HTTP/2 stream multiplexing can cause pool hangs when
# one stream stalls — blocking all other requests sharing the same pool.
#
# HTTP/1.1 uses one connection per request from the pool, so a stalled
# request only blocks its own connection. Other requests proceed normally.
#
# See: https://github.com/sneako/finch/issues/224
config :req, finch_options: [conn_opts: [protocols: [:http1]]]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
