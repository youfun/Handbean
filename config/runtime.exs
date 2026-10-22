import Config

if config_env() != :test and match?({:unix, :darwin}, :os.type()) and
     System.get_env("HANDBEAN_NOTIFY_PORT") do
  config :handbean,
         :macos_notify_port,
         String.to_integer(System.fetch_env!("HANDBEAN_NOTIFY_PORT"))

  config :handbean, :macos_notify_token, System.fetch_env!("HANDBEAN_NOTIFY_TOKEN")
  config :handbean, :runtime_notify_adapter, Handbean.Runtime.MacNotify
end

# Accumulate host capabilities before writing config: config/3 does not update
# Application env while this file is being evaluated. Keep the existing data_dir.
host = Application.get_env(:handbean, :host, %{})

host =
  if config_env() != :test and match?({:unix, :darwin}, :os.type()) and
       System.get_env("HANDBEAN_COMPUTER_PORT") do
    config :handbean,
           :computer_use_port,
           String.to_integer(System.fetch_env!("HANDBEAN_COMPUTER_PORT"))

    config :handbean, :computer_use_token, System.fetch_env!("HANDBEAN_COMPUTER_TOKEN")

    host = Map.put(host, :computer_use_backend, Handbean.ComputerUse.Native)

    case System.get_env("HANDBEAN_DATA_DIR") do
      dir when is_binary(dir) and dir != "" -> Map.put(host, :data_dir, dir)
      _ -> host
    end
  else
    host
  end

# Desktop launchers declare the file-manager integration explicitly. Do not
# infer it from :os.type(); Darwin also identifies non-desktop hosts.
file_manager_backend =
  if config_env() == :test do
    nil
  else
    case System.get_env("HANDBEAN_FILE_MANAGER") do
      value when value in [nil, ""] -> nil
      "macos" -> Handbean.Platform.FileManager.MacOS
      value -> raise "HANDBEAN_FILE_MANAGER has unsupported backend: #{inspect(value)}"
    end
  end

host =
  if file_manager_backend do
    Map.put_new(host, :file_manager_backend, file_manager_backend)
  else
    host
  end

config :handbean, :host, host

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/handbean start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
public_bind? = config_env() != :test and System.get_env("HANDBEAN_PUBLIC_BIND") == "1"

http_opts =
  if config_env() == :test do
    [ip: {127, 0, 0, 1}, port: 4002]
  else
    ip = if public_bind?, do: {0, 0, 0, 0}, else: {127, 0, 0, 1}
    [ip: ip, port: String.to_integer(System.get_env("PORT", "5002"))]
  end

if config_env() != :test do
  if System.get_env("PHX_SERVER") do
    config :handbean, HandbeanWeb.Endpoint, server: true
  end

  config :handbean, HandbeanWeb.Endpoint, http: http_opts
end

access_mode =
  case System.get_env("HANDBEAN_ACCESS_MODE", if(public_bind?, do: "password", else: "local")) do
    "local" -> :local
    "password" -> :password
    value -> raise "HANDBEAN_ACCESS_MODE must be 'local' or 'password', got: #{inspect(value)}"
  end

access_username = System.get_env("HANDBEAN_ACCESS_USERNAME", "handbean")
access_password = System.get_env("HANDBEAN_ACCESS_PASSWORD")

if public_bind? and access_mode != :password do
  raise """
  Refusing a non-loopback bind without authentication. HANDBEAN_PUBLIC_BIND=1 requires
  HANDBEAN_ACCESS_MODE=password and HANDBEAN_ACCESS_PASSWORD.
  """
end

if access_mode == :password and (is_nil(access_password) or access_password == "") do
  raise """
  HANDBEAN_ACCESS_PASSWORD is required when HANDBEAN_ACCESS_MODE=password.
  Use a long, randomly generated secret.
  """
end

config :handbean, :access,
  mode: access_mode,
  username: access_username,
  password: access_password

# The browser enrollment flow generates and persists VAPID keys automatically.
# The operator supplies a contact URI, never a private key in frontend config.
if config_env() != :test do
  config :handbean, :web_push, subject: System.get_env("HANDBEAN_WEB_PUSH_SUBJECT")
end

config :handbean,
  trust_project_code:
    String.downcase(System.get_env("HANDBEAN_TRUST_PROJECT_CODE", "false")) in [
      "1",
      "true",
      "yes"
    ]

# ── Streaming transcript flush pacing ──
# Streaming deltas are journaled in batches: at most every
# HANDBEAN_STREAM_FLUSH_MS milliseconds or HANDBEAN_STREAM_FLUSH_BYTES bytes,
# plus at event boundaries (phase change, tool, turn/run end). Raise both for
# remote or power-constrained storage; the built-in defaults live in
# Handbean.Agent.StreamBatch.
stream_flush_opts = []

stream_flush_opts =
  case System.get_env("HANDBEAN_STREAM_FLUSH_MS") do
    nil -> stream_flush_opts
    value -> Keyword.put(stream_flush_opts, :ms, String.to_integer(value))
  end

stream_flush_opts =
  case System.get_env("HANDBEAN_STREAM_FLUSH_BYTES") do
    nil -> stream_flush_opts
    value -> Keyword.put(stream_flush_opts, :bytes, String.to_integer(value))
  end

if stream_flush_opts != [] do
  config :handbean, :stream_flush, stream_flush_opts
end

# ── OpenAI-compatible provider config ──
openai_base_url =
  System.get_env("OPENAI_BASE_URL") || "https://api.stepfun.com/step_plan/v1"

openai_model = System.get_env("OPENAI_MODEL") || "step-5-preview"

openai_max_tokens =
  case System.get_env("OPENAI_MAX_TOKENS") do
    nil -> nil
    v -> String.to_integer(v)
  end

openai_temperature =
  case System.get_env("OPENAI_TEMPERATURE") do
    nil -> nil
    v -> String.to_float(v)
  end

openai_config = [base_url: openai_base_url, model: openai_model]

openai_config =
  if openai_max_tokens,
    do: Keyword.put(openai_config, :max_tokens, openai_max_tokens),
    else: openai_config

openai_config =
  if openai_temperature,
    do: Keyword.put(openai_config, :temperature, openai_temperature),
    else: openai_config

config :handbean, :openai, openai_config

if config_env() == :prod do
  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /etc/handbean/handbean.db
      """

  config :handbean, Handbean.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :handbean, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  allow_http? = System.get_env("HANDBEAN_ALLOW_HTTP") == "1"

  config :handbean, :web_push_access_secret, secret_key_base

  config :handbean, HandbeanWeb.Endpoint,
    url: [
      host: host,
      port: if(allow_http?, do: Keyword.fetch!(http_opts, :port), else: 443),
      scheme: if(allow_http?, do: "http", else: "https")
    ],
    allow_http: allow_http?,
    http: http_opts,
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :handbean, HandbeanWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :handbean, HandbeanWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
