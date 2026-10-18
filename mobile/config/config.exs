import Config

# Register the Repo so Mix tasks (mix ecto.create, mix ecto.migrate) can
# discover it. The actual database path is configured at runtime in
# HandbeanProbe.Repo.init/2 via the MOB_DATA_DIR environment variable.
config :handbean_probe, ecto_repos: [HandbeanProbe.Repo]

# Path dep `:handbean` does not load sigil/config/*.exs into this Mix project.
# Mix still starts `:handbean` because it is a runtime dep; give it a host DB
# and a disabled Endpoint so `mix test` does not crash the Repo pool.
config :phoenix, :json_library, Handbean.JSON

config :handbean,
  ecto_repos: [Handbean.Repo],
  telemetry_adapter: HandbeanWeb.Telemetry,
  endpoint_adapter: HandbeanWeb.Endpoint

config :handbean, :extension_hot_reload, false

config :handbean, Handbean.Repo,
  database: Path.expand("../tmp/handbean_host.db", __DIR__),
  pool_size: 5

config :handbean, HandbeanWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, port: 4012],
  secret_key_base: "d6gZah0nW4SwukROleHbkHgdQU3cMOhT0Zcz8JxRH3RC1MKd0EHr06Oc4M5MkbWR",
  server: false,
  pubsub_server: Handbean.PubSub,
  live_view: [signing_salt: "Wkzn+39Y"],
  render_errors: [
    formats: [html: HandbeanWeb.ErrorHTML, json: HandbeanWeb.ErrorJSON],
    layout: false
  ]

# Wire the Repo into Mob.ScreenState so screens using `vsn:` get automatic
# state persistence. Remove this line to disable screen state persistence.
config :mob, :repo, HandbeanProbe.Repo

config :handbean_probe, HandbeanProbe.Gettext,
  default_locale: "zh_CN",
  locales: ~w(zh_CN en)
