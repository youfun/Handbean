defmodule HandbeanProbe.App do
  @moduledoc "Application entry point for HandbeanProbe."

  use Mob.App

  require Logger

  @impl Mob.App
  def navigation(_platform) do
    stack(:main, root: HandbeanProbe.HomeScreen)
  end

  @known_api_hosts [
    "api.stepfun.com",
    "api.openai.com",
    "api.anthropic.com",
    "api.deepseek.com",
    "zenmux.ai",
    "api.x.ai"
  ]

  @impl Mob.App
  def on_start do
    start_runtime!()
  end

  def start_runtime! do
    Mob.DNS.configure_pure_beam()

    # Load packaged defaults before applying device paths below. Otherwise the
    # first ensure_all_started(:handbean) reloads the build-host Repo path from
    # handbean.app and replaces the Android runtime override.
    :ok = Application.ensure_loaded(:handbean)
    {:ok, _} = Application.ensure_all_started(:ecto_sqlite3)
    _ = Application.ensure_all_started(:bcrypt_elixir)
    # `:castore` is a Hex OTP app. Mob iOS/Android flatten BEAMs onto `-pa`,
    # so `Application.ensure_all_started(:castore)` raises `unknown application`
    # and `CAStore.file_path/0` cannot resolve `Application.app_dir(:castore)`.
    # Load the Mozilla bundle from this app's priv instead (copied at pack time).
    maybe_start_castore()
    load_cacerts()
    configure_git()
    Req.default_options(plugins: [HandbeanProbe.ReqDNS])
    configure_sigil!()
    log_mix_toolchain()
    Mob.DNS.preresolve(@known_api_hosts)
    # Clock reads schedule_runs during Application.start. On device
    # Handbean.Application skips Ecto.Migrator (no RELEASE_NAME), so the
    # schema has to exist before :handbean starts.
    migrate!()
    {:ok, _} = Application.ensure_all_started(:handbean)
    :ok = ensure_task_supervisor()
    :ok = HandbeanProbe.ShareIntake.Lock.ensure_started()
    :ok = HandbeanProbe.ShareCopy.ensure_started()
    # Loads :handbean_browser so nif_ready is set before HomeScreen can mount
    # and before hot share JNI callbacks are useful.
    HandbeanProbe.Browser.Engine.install!()
    _ = Code.ensure_loaded(:handbean_ios)
    HandbeanProbe.Platform.IOS.Registry.ensure_started()
    Handbean.Runtime.configure_notify_adapter()

    unless Process.whereis(:mob_screen) do
      Mob.Screen.start_root(HandbeanProbe.HomeScreen)
    end

    if Handbean.Host.dist?() do
      # mob 0.9.8 ignores the public :mob_secret cookie. Omit it so Android
      # uses the per-app cookie mix mob.deploy writes to mob_dist_cookie.
      Mob.Dist.ensure_started(
        node: HandbeanProbe.NativePlatform.dist_node(HandbeanProbe.NativePlatform.get())
      )
    end

    :ok
  end

  defp migrate! do
    Ecto.Migrator.with_repo(Handbean.Repo, fn repo ->
      Ecto.Migrator.run(repo, Handbean.Paths.migrations_dir(), :up, all: true)
    end)
  end

  def ensure_task_supervisor do
    spec = {Task.Supervisor, name: HandbeanProbe.TaskSupervisor}

    case Process.whereis(Handbean.Supervisor) do
      nil ->
        raise "Handbean.Supervisor is not running; start :handbean before ensure_task_supervisor/0"

      _pid ->
        case Supervisor.start_child(Handbean.Supervisor, spec) do
          {:ok, _} -> :ok
          {:ok, _, _} -> :ok
          {:error, {:already_started, _}} -> :ok
          {:error, :already_present} -> :ok
          {:error, {:already_present, _}} -> :ok
        end
    end
  end

  # Mix config/*.exs is not loaded on device. Set the env Phoenix and Ecto
  # need before `Application.ensure_all_started(:handbean)`.
  defp configure_sigil! do
    data_dir = Mob.data_dir()
    beams_dir = System.get_env("MOB_BEAMS_DIR")

    priv_dir =
      if beams_dir, do: Path.join(beams_dir, "priv"), else: Application.app_dir(:handbean, "priv")

    debug? = System.get_env("MOB_RELEASE") != "1"
    platform = HandbeanProbe.NativePlatform.detect()
    HandbeanProbe.NativePlatform.put!(platform)

    host_shell = developer_shell_profile(priv_dir, data_dir)

    Handbean.Host.put!(
      Map.merge(
        %{
          data_dir: data_dir,
          priv_dir: priv_dir,
          shell: false,
          shell_jobs: false,
          shell_isolation: :none,
          shell_environment: %{},
          terminal: false,
          browser_backend: :webview,
          speech_backend: nil,
          artifact_delivery_backend: HandbeanProbe.AndroidIntent,
          host_script: true,
          directory_picker: HandbeanProbe.DirectoryPicker,
          script_http: :platform_dns_ca,
          dns_resolver: &HandbeanProbe.ReqDNS.resolve/1,
          beam_eval: false,
          mcp: true,
          dist: debug?,
          git_backend: Handbean.Git.ExGit,
          packaged_mix_toolchain: true
        },
        host_shell
      )
    )

    System.put_env("HOME", data_dir)
    System.put_env("HANDBEAN_WORKSPACE", Path.join(data_dir, "workspace"))
    System.put_env("HANDBEAN_MODELS_FILE", Path.join(data_dir, ".handbean/models.json"))
    System.put_env("HANDBEAN_WORKSPACES_FILE", Path.join(data_dir, ".handbean/workspaces.json"))
    maybe_set_models_seed(priv_dir)

    liveview_port = Application.get_env(:mob, :liveview_port, default_liveview_port())
    Application.put_env(:mob, :liveview_port, liveview_port)
    Application.put_env(:mob, :host_url, "http://127.0.0.1:#{liveview_port}/")

    Application.put_env(:phoenix, :json_library, Handbean.JSON)
    Application.put_env(:handbean, :telemetry_adapter, HandbeanWeb.Telemetry)
    Application.put_env(:handbean, :endpoint_adapter, HandbeanWeb.Endpoint)
    configure_error_tracker!()
    Application.put_env(:handbean, :ecto_repos, [Handbean.Repo])
    Application.put_env(:handbean, :extension_hot_reload, false)
    Application.put_env(:handbean, :trust_project_code, false)
    Application.put_env(:handbean, :notifier, :handbean_notify)

    Application.put_env(:handbean, Handbean.Repo,
      database: Path.join(data_dir, "handbean.db"),
      pool_size: 5
    )

    Application.put_env(:handbean, Handbean.Gettext,
      default_locale: "zh_CN",
      locales: ~w(zh_CN en)
    )

    Application.put_env(:handbean_probe, HandbeanProbe.Gettext,
      default_locale: "zh_CN",
      locales: ~w(zh_CN en)
    )

    configure_staging_roots!()

    secret = host_secret(data_dir)
    origin = "http://127.0.0.1:#{liveview_port}"

    Application.put_env(:handbean, HandbeanWeb.Endpoint,
      adapter: Bandit.PhoenixAdapter,
      url: [host: "127.0.0.1", port: liveview_port],
      http: [ip: {127, 0, 0, 1}, port: liveview_port],
      check_origin: [origin],
      debug_errors: debug?,
      server: true,
      secret_key_base: secret,
      pubsub_server: Handbean.PubSub,
      live_view: [signing_salt: String.slice(secret, 0, 8)],
      render_errors: [
        formats: [html: HandbeanWeb.ErrorHTML, json: HandbeanWeb.ErrorJSON],
        layout: false
      ],
      code_reloader: false,
      watchers: [],
      live_reload: [patterns: []]
    )
  end

  @doc false
  def developer_shell_profile(priv_dir, data_dir, opts \\ [])
      when is_binary(priv_dir) and is_binary(data_dir) do
    profile_path = Path.join(priv_dir, "android_host_profile.json")
    expected_prefix = Keyword.get(opts, :expected_prefix, "/data/data/io.hndbean/files/usr")

    with {:ok, encoded} <- File.read(profile_path),
         {:ok,
          %{
            "profile" => "android_developer_sideload",
            "shell" => true,
            "shell_jobs" => false,
            "shell_isolation" => "none",
            "termux_prefix" => ^expected_prefix
          }} <- Handbean.JSON.decode(encoded),
         true <- File.regular?(Path.join(expected_prefix, "bin/bash")),
         true <- File.regular?(Path.join(expected_prefix, "lib/libtermux-exec.so")) do
      home = Path.join(data_dir, "home")
      tmp = Path.join(data_dir, "tmp")
      File.mkdir_p!(home)
      File.mkdir_p!(tmp)

      Application.put_env(:handbean, :shell_path, Path.join(expected_prefix, "bin/bash"))

      %{
        shell: true,
        shell_jobs: false,
        shell_isolation: :none,
        shell_environment: %{
          "HOME" => home,
          "LANG" => "en_US.UTF-8",
          "LD_LIBRARY_PATH" => Path.join(expected_prefix, "lib"),
          "LD_PRELOAD" => Path.join(expected_prefix, "lib/libtermux-exec.so"),
          "MIX_OS_CONCURRENCY_LOCK" => "0",
          "PATH" => Path.join(expected_prefix, "bin"),
          "PREFIX" => expected_prefix,
          "SHELL" => Path.join(expected_prefix, "bin/bash"),
          "TMPDIR" => tmp
        }
      }
    else
      _ ->
        Application.delete_env(:handbean, :shell_path)
        %{}
    end
  end

  @doc false
  def configure_error_tracker! do
    Application.put_env(:error_tracker, :repo, Handbean.Repo)
    Application.put_env(:error_tracker, :otp_app, :handbean)
    Application.put_env(:error_tracker, :filter, Handbean.ErrorTrackerFilter)
    Application.put_env(:error_tracker, :enabled, true)
  end

  # Mix config/*.exs is not loaded on device. Cleanup roots must be the
  # real Android cacheDir/controlled_import path from the JNI/runtime env
  # (MOB_CACHE_DIR). Host Mix never sets that env, so tests keep injecting
  # :staging_roots themselves.
  def configure_staging_roots!(env \\ System.get_env()) do
    case Map.get(env, "MOB_CACHE_DIR") do
      dir when is_binary(dir) and dir != "" ->
        Application.put_env(:handbean_probe, :staging_roots, [
          Path.join(dir, "controlled_import")
          | share_intake_root(env)
        ])

        :ok

      _ ->
        case ios_import_root(env) ++ share_intake_root(env) do
          [] ->
            :ok

          roots ->
            Application.put_env(:handbean_probe, :staging_roots, roots)
            :ok
        end
    end
  end

  @doc false
  def maybe_set_models_seed(priv_dir, env \\ System.get_env())
      when is_binary(priv_dir) do
    seed = Path.join(priv_dir, "models.seed.json")
    suffix = env["MOB_NODE_SUFFIX"]

    cond do
      suffix not in ["foundationtest", "nativechat"] ->
        :ignored

      File.exists?(seed) ->
        System.put_env("HANDBEAN_MODELS_SEED", seed)
        :seed

      true ->
        :default
    end
  end

  defp share_intake_root(env) do
    case Map.get(env, "MOB_DATA_DIR") do
      dir when is_binary(dir) and dir != "" -> [Path.join(dir, "share_intake")]
      _ -> []
    end
  end

  # iOS has no MOB_CACHE_DIR. Photo-picker copies land under Documents/Caches
  # so `Platform.import_owned?/1` can release them.
  defp ios_import_root(env) do
    if HandbeanProbe.NativePlatform.ios?() do
      case Map.get(env, "MOB_DATA_DIR") do
        dir when is_binary(dir) and dir != "" ->
          [Path.join([dir, "Caches", "controlled_import"])]

        _ ->
          []
      end
    else
      []
    end
  end

  defp host_secret(data_dir) do
    path = Path.join(data_dir, ".handbean/endpoint_secret")

    case File.read(path) do
      {:ok, secret} when byte_size(secret) >= 64 ->
        String.trim(secret)

      _ ->
        secret = :crypto.strong_rand_bytes(48) |> Base.encode64()
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, secret)
        secret
    end
  end

  defp log_mix_toolchain do
    case Handbean.Workspace.MixToolchain.info() do
      {:ok, info} ->
        Logger.info(
          "[HandbeanProbe] Mix toolchain #{info.source} mix=#{info.mix?} hex=#{info.hex?} " <>
            "ex_unit=#{info.ex_unit?} elixir=#{info.elixir} otp=#{info.otp}"
        )

      {:error, reason} ->
        Logger.warning("[HandbeanProbe] Mix toolchain unavailable: #{reason}")
    end
  end

  defp maybe_start_castore do
    case Application.ensure_all_started(:castore) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        if missing_otp_app?(reason) do
          :ok
        else
          raise "failed to start :castore: #{inspect(reason)}"
        end
    end
  rescue
    error ->
      if missing_otp_app?(error) do
        :ok
      else
        reraise error, __STACKTRACE__
      end
  end

  @doc false
  def missing_otp_app?(reason) do
    text = inspect(reason)

    String.contains?(text, "unknown application") or
      String.contains?(text, "not_found") or
      String.contains?(text, "no such file or directory")
  end

  # Prefer the bundled PEM. Host Mix still has `:castore` as a real OTP app
  # and `CAStore.file_path/0` works there; the device/sim path does not.
  def cacerts_path do
    Enum.find_value(cacerts_candidates(), fn path ->
      if is_binary(path) and File.regular?(path), do: path
    end)
  end

  defp cacerts_candidates do
    [
      beams_priv_cacerts(),
      probe_app_dir_cacerts(),
      Path.join(File.cwd!(), "priv/cacerts.pem"),
      castore_file_path()
    ]
  end

  defp probe_app_dir_cacerts do
    Application.app_dir(:handbean_probe, "priv/cacerts.pem")
  rescue
    ArgumentError -> nil
    ErlangError -> nil
  catch
    :error, {:bad_name, _} -> nil
    :error, :bad_name -> nil
  end

  defp beams_priv_cacerts do
    case System.get_env("MOB_BEAMS_DIR") do
      dir when is_binary(dir) and dir != "" -> Path.join(dir, "priv/cacerts.pem")
      _ -> nil
    end
  end

  defp castore_file_path do
    CAStore.file_path()
  rescue
    ArgumentError -> nil
    ErlangError -> nil
  catch
    :error, {:bad_name, _} -> nil
    :error, :bad_name -> nil
  end

  defp load_cacerts do
    path = cacerts_path()

    if is_nil(path) do
      raise "failed to load CA bundle: priv/cacerts.pem missing (and :castore is not an OTP lib)"
    end

    case Mob.Certs.load_cacerts(path) do
      :ok -> :ok
      {:error, reason} -> raise "failed to load CA bundle at #{path}: #{inspect(reason)}"
    end
  end

  defp configure_git do
    if HandbeanProbe.NativePlatform.detect() == :android do
      native_dir = System.fetch_env!("MOB_NATIVE_LIB_DIR")
      Application.put_env(:ex_git, :nif_path, Path.join(native_dir, "libex_git_nif"))
      Application.put_env(:ex_git, :cacertfile, cacerts_path())
    end
  end

  defp default_liveview_port do
    System.get_env("HANDBEAN_HTTP_PORT", "5088") |> String.to_integer()
  end
end
