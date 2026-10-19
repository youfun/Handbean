defmodule Mix.Tasks.Mob.PackApk do
  @shortdoc "Bundle OTP into the debug APK and adb-install it"
  @moduledoc """
  Chromos/ARC cannot `adb run-as`, so `mix mob.deploy --native` cannot push
  the OTP tree after install. Package `otp.zip` into the APK the same way
  `mix mob.release --android` does, then install with adb.

  Defaults to the connected device ABI (x86_64 on this Chromos box).

  One APK holds one OTP zip, so arm64 and x86_64 are separate builds:

      mix mob.pack_apk --abi arm64-v8a --no-install --output handbean_probe-arm64.apk
      mix mob.pack_apk --abi x86_64 --no-install --output handbean_probe-x86_64.apk

  Default packaging stays `com.example.handbean_probe.nativechat`. Pass
  `--foundation-test-app` to forward Gradle `-PfoundationTestApp` (isolated
  `foundationtest` applicationId + dist 9300):

      mix mob.pack_apk --abi x86_64 --no-install --foundation-test-app --output artifacts/foundation-x86_64.apk

  Optional private model seed (explicit opt-in for distributable test APKs):

      mix mob.pack_apk --abi arm64-v8a --no-install --models-seed PATH

  Or place `config/foundation_test_models.seed.json` (gitignored) / set
  `HANDBEAN_FOUNDATION_MODELS_SEED` for foundation-test packs only. Nativechat
  requires an explicit --models-seed path. First boot copies the seed only
  when models.json is missing. Embedded keys are extractable; use revocable
  test credentials. Do not commit keys.
  """

  use Mix.Task

  @activity "com.example.handbean_probe.nativechat/com.example.handbean_probe.MainActivity"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          abi: :string,
          device: :string,
          slim: :boolean,
          install: :boolean,
          output: :string,
          foundation_test_app: :boolean,
          models_seed: :string
        ]
      )

    Mix.Task.run("compile")
    Mix.Task.run("handbean.pack_mix_toolchain")
    # mob.exs is gitignored; pack from a fresh tree must install the
    # checked-in static_nifs template or Zig omits project C NIFs.
    Mix.Task.run("mob.write_mob_exs")
    # The Zig link can succeed with a stale table while project NIFs fail to load.
    Mix.Task.run("mob.regen_driver_tab")
    ensure_handbean_assets!()

    abi = opts[:abi] || detect_abi(opts[:device])
    slim? = Keyword.get(opts, :slim, true)
    install? = Keyword.get(opts, :install, true)
    app_name = Mix.Project.config()[:app] |> to_string()

    Mix.shell().info("Packing OTP for ABI #{abi} into debug APK...")

    with {:ok, otp_dir} <- MobDev.OtpDownloader.ensure_android(abi),
         :ok <- zig_native(abi, otp_dir),
         {:ok, staging} <- stage(otp_dir, app_name, opts),
         zip_path <- zip_path(),
         :ok <- File.mkdir_p(Path.dirname(zip_path)),
         {:ok, info} <-
           MobDev.OtpAssetBundle.build(staging, zip_path,
             slim: slim?,
             keep_prefixes: ["runtime_tools", "inets", "ssl", "public_key", "asn1", "crypto"]
           ),
         _ <- File.rm_rf!(staging),
         _ <-
           Mix.shell().info(
             "  otp.zip: #{info.zipped_files} files, #{div(info.zip_size_kb, 1024)}MB"
           ),
         {:ok, apk} <- assemble_debug(abi, opts),
         apk <- copy_output(apk, opts[:output]) do
      Mix.shell().info("  APK: #{apk}")
      if install?, do: install_apk(apk, opts[:device]), else: :ok
    else
      {:error, reason} -> Mix.raise(inspect(reason))
    end
  end

  defp zig_native(abi, otp_dir) do
    case MobDev.Toolchain.zig_status() do
      {:ok, _} ->
        copy_erts_helpers!(otp_dir, abi)
        run_zig(abi, otp_dir)

      status ->
        {:error, MobDev.NativeBuild.zig_required_message(status)}
    end
  end

  defp run_zig(abi, otp_dir) do
    platform =
      case abi do
        "arm64-v8a" -> :android_arm64
        "armeabi-v7a" -> :android_arm32
        "x86_64" -> :android_x86_64
      end

    {:ok, nif_args} = MobDev.NativeBuild.project_nif_zig_args(platform)
    nif_args = Enum.reject(nif_args, &String.starts_with?(&1, "-Dproject_root="))

    app_name = Mix.Project.config()[:app] |> to_string()
    root = Path.expand(".")
    jni_libs = Path.join([root, "android/app/src/main/jniLibs", abi])
    File.mkdir_p!(jni_libs)

    args = [
      "build",
      "native-lib",
      "--build-file",
      "android/app/src/main/jni/build.zig",
      "--prefix",
      "android/app/build/zig-out",
      "-Dabi=#{abi}",
      "-Dotp_dir=#{otp_dir}",
      "-Derts_vsn=#{erts_vsn(otp_dir)}",
      "-Dmob_dir=#{Path.join(root, "deps/mob")}",
      "-Ddriver_tab=#{Path.join(root, "priv/generated/driver_tab_android.zig")}",
      "-Dproject_jni_dir=#{Path.join(root, "android/app/src/main/jni")}",
      "-Dndk_sysroot=#{MobDev.NdkVersion.sysroot()}",
      "-Dapp_name=#{app_name}",
      "-Dproject_root=#{root}",
      "-Dexqlite_src=#{Path.join(root, "deps/exqlite/c_src")}",
      "-Dbcrypt_src=#{Path.join(root, "deps/bcrypt_elixir/c_src")}"
      | nif_args
    ]

    Mix.shell().info("  zig build native-lib -Dabi=#{abi}")

    case System.cmd("zig", args, stderr_to_stdout: true, into: IO.stream()) do
      {_, 0} -> :ok
      {_, rc} -> {:error, "zig build #{abi} failed (#{rc})"}
    end
  end

  defp copy_erts_helpers!(otp_dir, abi) do
    jni_libs = Path.join(["android/app/src/main/jniLibs", abi])
    File.mkdir_p!(jni_libs)

    case Path.wildcard(Path.join(otp_dir, "erts-*/bin")) do
      [erts_bins | _] ->
        Enum.each(
          [
            {"erl_child_setup", "liberl_child_setup.so"},
            {"inet_gethost", "libinet_gethost.so"},
            {"epmd", "libepmd.so"}
          ],
          fn {exe, lib} ->
            src = Path.join(erts_bins, exe)
            if File.exists?(src), do: File.cp!(src, Path.join(jni_libs, lib))
          end
        )

      _ ->
        :ok
    end
  end

  defp erts_vsn(otp_dir) do
    case File.ls(otp_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.starts_with?(&1, "erts-"))
        |> Enum.sort(:desc)
        |> List.first() || "erts-17.0"

      _ ->
        "erts-17.0"
    end
  end

  defp zip_path, do: Path.expand("android/app/src/debug/assets/otp.zip")

  @doc false
  def handbean_assets_command do
    {"mix", ["assets.build"], [{"MIX_TARGET", "mobile"}]}
  end

  defp ensure_handbean_assets! do
    sigil = Path.expand("..", File.cwd!())
    {command, args, env} = handbean_assets_command()
    Mix.shell().info("  building Handbean assets…")

    case System.cmd(command, args, cd: sigil, env: env, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, rc} -> Mix.raise("sigil asset build failed (#{rc}): #{out}")
    end
  end

  defp stage(otp_dir, app_name, opts) do
    staging =
      Path.join(System.tmp_dir!(), "mob_pack_apk_#{:erlang.unique_integer([:positive])}")

    File.rm_rf!(staging)

    case System.cmd("cp", ["-R", otp_dir <> "/.", staging], stderr_to_stdout: true) do
      {_, 0} ->
        dest = Path.join(staging, app_name)
        File.mkdir_p!(dest)

        Enum.each(runtime_beam_dirs(), fn dir ->
          cp!("#{Path.expand(dir)}/.", dest)
        end)

        merge_priv!(dest)
        inject_or_reject_models_seed!(Path.join(dest, "priv"), opts)
        add_exqlite!(staging)
        add_bcrypt!(staging)
        add_castore!(staging)
        {:ok, staging}

      {out, _} ->
        {:error, "copy OTP failed: #{out}"}
    end
  end

  @doc false
  def runtime_beam_dirs(build_path \\ Mix.Project.build_path(), mob_dirs \\ nil) do
    mob_dirs = mob_dirs || mob_runtime_beam_dirs()

    (shared_runtime_beam_dirs(build_path) ++ mob_dirs)
    |> Enum.uniq()
    |> Enum.filter(&File.dir?/1)
  end

  defp shared_runtime_beam_dirs(build_path) do
    lib_path = Path.join(build_path, "lib")
    collect_runtime_apps(lib_path, ["handbean"], MapSet.new(), [])
  end

  defp collect_runtime_apps(_lib_path, [], _seen, dirs), do: Enum.reverse(dirs)

  defp collect_runtime_apps(lib_path, [app | rest], seen, dirs) do
    if MapSet.member?(seen, app) do
      collect_runtime_apps(lib_path, rest, seen, dirs)
    else
      seen = MapSet.put(seen, app)
      ebin = Path.join([lib_path, app, "ebin"])

      if File.dir?(ebin) do
        dependencies = application_dependencies(Path.join(ebin, "#{app}.app"))
        collect_runtime_apps(lib_path, rest ++ dependencies, seen, [ebin | dirs])
      else
        collect_runtime_apps(lib_path, rest, seen, dirs)
      end
    end
  end

  defp application_dependencies(app_file) do
    with {:ok, [{:application, _name, spec}]} <- :file.consult(String.to_charlist(app_file)) do
      spec
      |> Keyword.get(:applications, [])
      |> Enum.map(&to_string/1)
    else
      _ -> []
    end
  end

  defp mob_runtime_beam_dirs do
    if Code.ensure_loaded?(MobDev.HotPush),
      do: apply(MobDev.HotPush, :runtime_beam_dirs, []),
      else: []
  end

  defp merge_priv!(dest) do
    dest_priv = Path.join(dest, "priv")
    File.mkdir_p!(dest_priv)

    Enum.each(priv_sources(), fn source ->
      if File.dir?(source) do
        cp!(source <> "/.", dest_priv)
      end
    end)
  end

  defp priv_sources do
    [
      Path.join(File.cwd!(), "priv"),
      Path.expand("../priv", File.cwd!())
    ]
  end

  defp add_exqlite!(staging), do: add_dep_lib!(staging, :exqlite)
  defp add_bcrypt!(staging), do: add_dep_lib!(staging, :bcrypt_elixir)
  defp add_castore!(staging), do: add_dep_lib!(staging, :castore)

  # Flattened ebin copies are not an OTP lib. Mint TLS falls back to
  # CAStore.file_path/0 → Application.app_dir(:castore), which needs
  # $OTP_ROOT/lib/castore-*/{ebin,priv/cacerts.pem}.
  defp add_dep_lib!(staging, app) do
    name = to_string(app)

    with vsn when is_binary(vsn) <- MobDev.AppFile.dep_version(app),
         [ebin | _] <- Path.wildcard("_build/dev/lib/#{name}/ebin") do
      lib_dir = Path.join(staging, "lib/#{name}-#{vsn}")
      dest_ebin = Path.join(lib_dir, "ebin")
      File.mkdir_p!(dest_ebin)

      cp!("#{Path.expand(ebin)}/.", dest_ebin)

      priv = Path.expand("_build/dev/lib/#{name}/priv")

      if File.dir?(priv) do
        dest_priv = Path.join(lib_dir, "priv")
        File.mkdir_p!(dest_priv)
        cp!(priv <> "/.", dest_priv)
        # Host-built NIFs are the wrong ABI. Android/iOS load lib<name>.so
        # from jniLibs / the static NIF table instead.
        Enum.each([".so", ".dylib", ".dll"], fn ext ->
          Path.wildcard(Path.join(dest_priv, "**/*#{ext}"))
          |> Enum.each(&File.rm/1)
        end)
      end

      :ok
    else
      _ -> Mix.raise("required OTP lib #{name} missing from _build/dev")
    end
  end

  defp cp!(from, to) do
    case System.cmd("cp", ["-R", from, to], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, rc} -> Mix.raise("cp failed (#{rc}): #{from} -> #{to}\n#{out}")
    end
  end

  @seed_name "models.seed.json"

  def resolve_models_seed(opts \\ []) do
    foundation? = Keyword.get(opts, :foundation_test_app, false)
    requested = opts[:models_seed] || System.get_env("HANDBEAN_FOUNDATION_MODELS_SEED")
    default = Path.join(File.cwd!(), "config/foundation_test_models.seed.json")

    path =
      cond do
        is_binary(requested) and requested != "" -> requested
        File.exists?(default) -> default
        true -> nil
      end

    exists? = is_binary(path) and File.exists?(path)
    requested? = is_binary(requested) and requested != ""

    cond do
      (exists? or requested?) and not foundation? and is_nil(opts[:models_seed]) ->
        {:error, :seed_requires_foundation_test_app}

      exists? ->
        {:ok, path}

      requested? ->
        {:error, :seed_missing}

      true ->
        :none
    end
  end

  defp inject_or_reject_models_seed!(dest_priv, opts) do
    packed = Path.join(dest_priv, @seed_name)

    if File.exists?(packed) or
         File.exists?(Path.join(dest_priv, "foundation_test_models.seed.json")) do
      Mix.raise(
        "model seeds must come from an explicit pack option, not the source priv directory"
      )
    end

    case resolve_models_seed(opts) do
      {:error, :seed_requires_foundation_test_app} ->
        Mix.raise(
          "implicit model seed requires --foundation-test-app; use --models-seed for nativechat"
        )

      {:error, :seed_missing} ->
        Mix.raise("model seed file not found")

      {:ok, path} ->
        File.mkdir_p!(dest_priv)
        File.cp!(path, packed)

        Mix.shell().error(
          "WARNING: This APK embeds extractable credentials. Distribute only with revocable test keys. First boot copies them only if models.json is missing."
        )

        :ok

      :none ->
        :ok
    end
  end

  def gradle_assemble_args(abi, opts \\ []) when is_binary(abi) do
    args = ["assembleDebug", "--no-daemon", "-PmobAbi=#{abi}"]

    if Keyword.get(opts, :foundation_test_app, false) do
      args ++ ["-PfoundationTestApp"]
    else
      args
    end
  end

  defp assemble_debug(abi, opts) do
    gradlew = Path.expand("android/gradlew")
    apk = Path.expand("android/app/build/outputs/apk/debug/app-debug.apk")

    case System.cmd(
           "bash",
           [gradlew | gradle_assemble_args(abi, opts)],
           cd: Path.expand("android"),
           stderr_to_stdout: true,
           into: IO.stream()
         ) do
      {_, 0} ->
        if File.exists?(apk), do: {:ok, apk}, else: {:error, "APK missing at #{apk}"}

      {_, rc} ->
        {:error, "assembleDebug failed (#{rc})"}
    end
  end

  defp copy_output(apk, nil), do: apk

  defp copy_output(apk, output) do
    dest = Path.expand(output)
    File.mkdir_p!(Path.dirname(dest))
    File.cp!(apk, dest)
    dest
  end

  defp install_apk(apk, device) do
    adb = System.find_executable("adb") || Mix.raise("adb not found")
    serial = device || default_serial()
    args = if serial, do: ["-s", serial, "install", "-r", apk], else: ["install", "-r", apk]
    Mix.shell().info("  adb #{Enum.join(args, " ")}")

    case System.cmd(adb, args, stderr_to_stdout: true) do
      {out, 0} ->
        Mix.shell().info(out)
        launch(serial)

      {out, rc} ->
        Mix.raise("adb install failed (#{rc}): #{out}")
    end
  end

  defp launch(nil), do: :ok

  defp launch(serial) do
    adb = System.find_executable("adb")

    System.cmd(
      adb,
      ["-s", serial, "shell", "am", "start", "-n", @activity],
      stderr_to_stdout: true
    )

    :ok
  end

  defp detect_abi(device) do
    adb = System.find_executable("adb")

    args =
      if device,
        do: ["-s", device, "shell", "getprop", "ro.product.cpu.abi"],
        else: ["shell", "getprop", "ro.product.cpu.abi"]

    case adb && System.cmd(adb, args, stderr_to_stdout: true) do
      {out, 0} ->
        out
        |> String.split(["\n", "\r"])
        |> Enum.map(&String.trim/1)
        |> Enum.find(&(&1 in ["x86_64", "arm64-v8a", "armeabi-v7a"]))
        |> case do
          abi when is_binary(abi) -> abi
          nil -> "x86_64"
        end

      _ ->
        "x86_64"
    end
  end

  defp default_serial do
    adb = System.find_executable("adb") || Mix.raise("adb not found")

    case System.cmd(adb, ["devices"], stderr_to_stdout: true) do
      {out, 0} ->
        out
        |> String.split("\n")
        |> Enum.map(&String.split(&1, "\t"))
        |> Enum.find_value(fn
          [serial, "device"] -> serial
          _ -> nil
        end)

      _ ->
        nil
    end
  end
end
