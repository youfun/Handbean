import Config

config :handbean, HandbeanWeb.Endpoint,
  check_origin: true,
  force_ssl: [
    exclude: [
      conn: {HandbeanWeb.Endpoint, :allow_http?, []}
    ]
  ]

# Do not print debug messages in production
config :logger, level: :info

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
