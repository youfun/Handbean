defmodule HandbeanProbe.MixProject do
  use Mix.Project

  @version_file Path.expand("../version.properties", __DIR__)
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
      app: :handbean_probe,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: false,
      deps: deps(),
      aliases: aliases(),
      erlc_paths: ["src"],
      erlc_options: [:debug_info]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:mob, "== 0.9.27"},
      {:mob_dev, "== 0.7.31", only: :dev, runtime: false},
      # The native host configures its private data directory and runs root
      # migrations before starting the shared runtime explicitly.
      {:handbean, path: "..", runtime: false},
      # Phone Git backend (libgit2 NIF). Root Mix uses the host Git CLI and
      # must not depend on this package.
      {:ex_git, github: "youfun/ex-git", tag: "v0.0.4"},
      # Handbean pins these; Mob pulled newer ones into this Mix lock.
      {:phoenix_live_view, "~> 1.2.0", override: true},
      {:req, "~> 0.7.4", override: true},
      {:ecto_sqlite3, "~> 0.25"},
      # Host-provided password hash for workspace Mix projects (phx.gen.auth).
      {:bcrypt_elixir, "~> 3.3"},
      {:gettext, "~> 1.0"},
      {:nimble_csv, "~> 1.3"},
      # Code quality — Credo + ex_slop (catches AI-generated patterns
      # like blanket rescue, narrator docs, redundant Enum chains, etc).
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4.5", only: [:dev, :test], runtime: false}
    ]
  end

  # Shorthands for the common mob workflows — `mix deploy` is `mix mob.deploy`,
  # etc. Extra args pass through to the underlying task, so `mix deploy
  # --device <udid>` works as expected.
  defp aliases do
    [
      connect: ["mob.connect"],
      deploy: ["handbean.pack_mix_toolchain", "mob.deploy"],
      watch: ["mob.watch"],
      icon: ["mob.icon"],
      "handbean.prepare_ios": [fn _ -> prepare_ios!() end],
      "mob.deploy": [
        fn args ->
          if "--ios" in args or ("--android" not in args and :os.type() == {:unix, :darwin}),
            do: prepare_ios!()

          Mix.Task.run("compile")
          Mix.Tasks.Mob.Deploy.run(args)
        end
      ],
      ios: ["handbean.pack_mix_toolchain", "mob.deploy --ios"],
      # TestFlight rewrites ios/release_device.sh from mob_dev. Splice the
      # markdown host overlay back in before that rewrite, then run the real task.
      "mob.release": [
        fn args ->
          unless "--android" in args do
            prepare_ios!()
            Mix.Task.run("compile")
            HandbeanProbe.IosMarkdownRelease.install!()
          end

          Mix.Tasks.Mob.Release.run(args)
        end
      ],
      "ios.native": ["handbean.pack_mix_toolchain", "mob.deploy --native --ios"],
      android: ["handbean.pack_mix_toolchain", "mob.deploy --android"],
      "android.native": ["handbean.pack_mix_toolchain", "mob.deploy --native --android"]
    ]
  end

  defp prepare_ios! do
    script = Path.expand("../scripts/version.sh", __DIR__)
    template = Path.expand("ios/Info.plist.template", __DIR__)
    output = Path.expand("ios/Info.plist", __DIR__)

    case System.cmd("bash", [script, "plist", template, output], stderr_to_stdout: true) do
      {output, 0} -> Mix.shell().info(String.trim(output))
      {output, _} -> Mix.raise(output)
    end
  end
end
