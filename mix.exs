defmodule Handbean.MixProject do
  use Mix.Project

  @version_file Path.expand("version.properties", __DIR__)
  @external_resource @version_file
  @version @version_file
           |> File.read!()
           |> String.split("\n", trim: true)
           |> Map.new(fn line ->
             [key, value] = String.split(line, "=", parts: 2)
             {key, String.trim(value)}
           end)
           |> Map.fetch!("version")

  def project do
    [
      app: :handbean,
      version: @version,
      elixir: ">= 1.20.0-rc.5 and < 1.21.0",
      source_url: "https://github.com/youfun/Handbean",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      releases: releases(),
      compilers: [:elixir_make, :phoenix_live_view] ++ Mix.compilers(),
      make_clean: ["clean"],
      listeners: [Phoenix.CodeReloader],
      package: [
        # Hex and other source packages stay FSL. An iOS binary that
        # statically links iSH is a separate GPLv3 distribution; see LICENSE.iOS.
        licenses: ["FSL-1.1-ALv2"],
        links: %{"GitHub" => "https://github.com/youfun/Handbean"}
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Handbean.Application, []},
      extra_applications: [:logger, :runtime_tools, :castore],
      # Mob flattens Hex apps onto `-pa`; `:castore` then is not an OTP lib
      # and `ensure_all_started(:handbean)` must not abort boot. Probe loads the
      # Mozilla bundle from `priv/cacerts.pem` instead.
      optional_applications: [:castore]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test, "test.quality": :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.9"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.14"},
      {:ecto_sqlite3, ">= 0.0.0"},
      {:error_tracker, "~> 0.9"},
      {:tz, "~> 0.28"},
      {:phoenix_html, "~> 4.1"},
      {:file_system, "~> 1.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, "~> 0.1.13", only: :test},
      {:phoenix_test, "~> 0.12.0", only: :test, runtime: false},
      {:req, "~> 0.7.4"},
      {:mint, "~> 1.11"},
      {:castore, "~> 1.0"},
      {:floki, "~> 0.38.4"},
      {:llm_db, "~> 2026.10.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:websockex, "~> 0.5.1"},
      {:dns_cluster, "~> 0.3.1"},
      {:bandit, "~> 1.13"},
      {:rustler_precompiled, "~> 0.10", override: true, optional: true},

      # 程序依赖图 / 发布安全检查
      {:reach, "~> 2.6", only: [:dev, :test], runtime: false},

      # 代码质量分析
      {:credence, "~> 0.1", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4.1", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},

      # ETS-based fuzzy file search engine
      {:ex_fff, path: "ex_fff"},

      # i18n / 多语言支持
      {:gettext, "~> 1.0"},
      {:elixir_make, "~> 0.9", runtime: false}
    ] ++ maybe_ghostty() ++ maybe_whisper_cpp()
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"],
      "test.quality": ["run test/support/credence_check.exs"],
      "assets.setup": ["cmd npm ci", "esbuild.install --if-missing"],
      "assets.build": ["esbuild handbean"],
      "assets.deploy": ["esbuild handbean --minify", "phx.digest"]
    ]
  end

  defp maybe_whisper_cpp do
    architecture = List.to_string(:erlang.system_info(:system_architecture))

    supported? =
      String.starts_with?(architecture, "aarch64-apple-darwin") or
        ((String.starts_with?(architecture, "aarch64-") or
            String.starts_with?(architecture, "x86_64-")) and
           String.ends_with?(architecture, "-linux-gnu"))

    if supported?,
      do: [{:whisper_cpp, "~> 0.5.0", optional: true, targets: :host}],
      else: []
  end

  # Ghostty NIFs exist for Linux and macOS only. Windows Web UI packages
  # omit the dep so `mix release` can build; the terminal stays unavailable.
  defp maybe_ghostty do
    if match?({:win32, _}, :os.type()) do
      []
    else
      # The upgrade branch has no precompiled release; build its pinned engine.
      [
        {:ghostty,
         git: "https://github.com/youfun/ghostty_ex.git",
         branch: "upgrade/ghostty-22fa134",
         compile: ~s(bash "#{__DIR__}/scripts/compile_ghostty.sh"),
         optional: true,
         targets: :host},
        {:zigler, "~> 0.16.0", runtime: false, optional: true, targets: :host}
      ]
    end
  end

  # Phoenix release 配置（常规 OTP release，含 ERTS）。
  # Unix 包用 tar.gz，Windows 包用 zip；两边的启动脚本都打进 release。
  defp releases do
    [
      handbean: [
        include_erts: true,
        include_executables_for: [:unix, :windows]
      ]
    ]
  end
end
