defmodule Mix.Tasks.Mob.PackApk do
  @shortdoc "Bundle OTP into the debug APK and adb-install it"
  @moduledoc """
  Chromos/ARC cannot `adb run-as`, so `mix mob.deploy --native` cannot push
  the OTP tree after install. Package `otp.zip` into the APK the same way
  `mix mob.release --android` does, then install with adb.

  Defaults to the connected device ABI (x86_64 on this Chromos box).

  One APK holds one OTP zip, so arm64 and x86_64 are separate builds:

      mix mob.pack_apk --abi arm64-v8a --no-install --output Handbean-android-arm64-v8a.apk
      mix mob.pack_apk --abi x86_64 --no-install --output Handbean-android-x86_64.apk

  Standard packages keep `targetSdk 35`. The developer/sideload package is a
  separate ARM64-only application with `targetSdk 28` and a pinned Termux rootfs:

      mix mob.pack_apk --abi arm64-v8a --developer-sideload --no-install \
        --output Handbean-android-developer-linux-arm64-v8a.apk

  The developer package requires generated assets under
  `android/app/src/developerSideload/assets`; it never falls back to an unpinned
  download during an APK build.

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

  @standard_activity "com.example.handbean_probe.nativechat/com.example.handbean_probe.MainActivity"
  @developer_activity "io.hndbean/com.example.handbean_probe.MainActivity"
  @developer_assets Path.expand("android/app/src/developerSideload/assets")
  @developer_lock Path.expand("config/termux-rootfs.lock.json")

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
          developer_sideload: :boolean,
          models_seed: :string
        ]
      )

    abi = opts[:abi] || detect_abi(opts[:device])
    validate_variant!(abi, opts)

    Mix.Task.run("compile")
    prepare_mix_toolchain!()
    # mob.exs is gitignored; pack from a fresh tree must install the
    # checked-in static_nifs template or Zig omits project C NIFs.
    Mix.Task.run("mob.write_mob_exs")
    # The Zig link can succeed with a stale table while project NIFs fail to load.
    Mix.Task.run("mob.regen_driver_tab")
    ensure_developer_assets!(opts)

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
      if install?, do: install_apk(apk, opts[:device], opts), else: :ok
    else
      {:error, reason} -> Mix.raise(inspect(reason))
    end
  end

  @doc false
  def validate_prepacked_mix_toolchain(manifest, expected_elixir, expected_otp)
      when is_map(manifest) do
    if manifest["elixir"] == expected_elixir and manifest["otp"] == expected_otp do
      :ok
    else
      {:error,
       "prepacked Mix toolchain is Elixir #{manifest["elixir"]}/OTP #{manifest["otp"]}; " <>
         "expected Elixir #{expected_elixir}/OTP #{expected_otp}"}
    end
  end

  defp prepare_mix_toolchain! do
    if System.get_env("HANDBEAN_MIX_TOOLCHAIN_PREPACKED") == "1" do
      validate_mix_toolchain_manifest!(Path.expand("priv/mix_toolchain/manifest.json"))
    else
      Mix.Task.run("handbean.pack_mix_toolchain")
    end
  end

  defp validate_mix_toolchain_manifest!(manifest_path) do
    manifest = manifest_path |> File.read!() |> Handbean.JSON.decode!()
    {expected_elixir, expected_otp} = expected_mobile_beam_versions()

    case validate_prepacked_mix_toolchain(manifest, expected_elixir, expected_otp) do
      :ok -> :ok
      {:error, reason} -> Mix.raise(reason)
    end
  end

  defp expected_mobile_beam_versions do
    versions = Path.expand(".tool-versions") |> File.read!()

    elixir =
      Regex.run(~r/^elixir\s+(\S+)/m, versions, capture: :all_but_first)
      |> List.first()
      |> String.split("-otp-", parts: 2)
      |> List.first()

    otp =
      Regex.run(~r/^erlang\s+(\d+)/m, versions, capture: :all_but_first)
      |> List.first()

    {elixir, otp}
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
        add_developer_host_profile!(dest, opts)
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

  @doc false
  def merge_priv!(dest, root_priv \\ Path.expand("../priv"), mobile_priv \\ Path.expand("priv")) do
    dest_priv = Path.join(dest, "priv")
    File.mkdir_p!(dest_priv)

    # Android uses native screens; root static assets are for the Web UI.
    # Keep the remaining root runtime resources and overlay mobile priv as before.
    if File.dir?(root_priv) do
      root_priv
      |> File.ls!()
      |> Enum.reject(&(&1 == "static"))
      |> Enum.each(&cp!(Path.join(root_priv, &1), dest_priv))
    end

    if File.dir?(mobile_priv), do: cp!(mobile_priv <> "/.", dest_priv)
    # Also discard old Web build output left in the mobile overlay or OTP tree.
    File.rm_rf!(Path.join(dest_priv, "static/assets"))
    File.rm_rf!(Path.join(dest_priv, "static/cache_manifest.json"))

    if System.get_env("HANDBEAN_MIX_TOOLCHAIN_PREPACKED") == "1" do
      validate_mix_toolchain_manifest!(Path.join(dest_priv, "mix_toolchain/manifest.json"))
    end
  end

  defp add_exqlite!(staging), do: add_dep_lib!(staging, :exqlite)
  defp add_bcrypt!(staging), do: add_dep_lib!(staging, :bcrypt_elixir)
  defp add_castore!(staging), do: add_dep_lib!(staging, :castore)

  # Flattened ebin copies are not an OTP lib. Mint TLS falls back to
  # CAStore.file_path/0 → Application.app_dir(:castore), which needs
  # $OTP_ROOT/lib/castore-*/{ebin,priv/cacerts.pem}.
  @doc false
  def dep_build_dir(app) do
    Path.join([Mix.Project.build_path(), "lib", to_string(app)])
  end

  defp add_dep_lib!(staging, app) do
    name = to_string(app)
    build_dir = dep_build_dir(app)

    with vsn when is_binary(vsn) <- MobDev.AppFile.dep_version(app),
         true <- File.dir?(Path.join(build_dir, "ebin")) do
      ebin = Path.join(build_dir, "ebin")
      lib_dir = Path.join(staging, "lib/#{name}-#{vsn}")
      dest_ebin = Path.join(lib_dir, "ebin")
      File.mkdir_p!(dest_ebin)

      cp!("#{Path.expand(ebin)}/.", dest_ebin)

      priv = Path.join(build_dir, "priv")

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
      _ -> Mix.raise("required OTP lib #{name} missing from #{Mix.Project.build_path()}")
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

  @doc false
  def validate_variant!(abi, opts) do
    developer? = Keyword.get(opts, :developer_sideload, false)
    foundation? = Keyword.get(opts, :foundation_test_app, false)

    cond do
      developer? and foundation? ->
        Mix.raise("--developer-sideload and --foundation-test-app are mutually exclusive")

      developer? and abi != "arm64-v8a" ->
        Mix.raise("--developer-sideload supports only --abi arm64-v8a")

      true ->
        :ok
    end
  end

  defp ensure_developer_assets!(opts) do
    if Keyword.get(opts, :developer_sideload, false) do
      archive = Path.join(@developer_assets, "termux-rootfs.tgz")
      manifest_path = Path.join(@developer_assets, "termux-rootfs.json")
      package_manifest_path = Path.join(@developer_assets, "termux-packages.json")

      with true <- File.regular?(archive),
           true <- File.regular?(manifest_path),
           true <- File.regular?(package_manifest_path),
           true <- File.regular?(@developer_lock),
           {:ok, manifest_json} <- File.read(manifest_path),
           {:ok, manifest} when is_map(manifest) <- Handbean.JSON.decode(manifest_json),
           :ok <- validate_rootfs_manifest(manifest),
           {:ok, package_manifest_json} <- File.read(package_manifest_path),
           {:ok, package_manifest} when is_map(package_manifest) <-
             Handbean.JSON.decode(package_manifest_json),
           :ok <- validate_package_manifest(package_manifest),
           {:ok, digest} <- file_sha256(archive),
           true <- digest == String.downcase(manifest["archive_sha256"]),
           {:ok, lock_digest} <- file_sha256(@developer_lock),
           true <- lock_digest == String.downcase(manifest["package_lock_sha256"]),
           {:ok, package_digest} <- file_sha256(package_manifest_path),
           true <- package_digest == String.downcase(manifest["package_manifest_sha256"]) do
        :ok
      else
        false ->
          Mix.raise(
            "developer rootfs is missing or does not match termux-rootfs.json; " <>
              "run script/build_termux_rootfs.exs first"
          )

        {:error, reason} ->
          Mix.raise("invalid developer rootfs: #{inspect(reason)}")

        other ->
          Mix.raise("invalid developer rootfs manifest: #{inspect(other)}")
      end
    end
  end

  defp validate_rootfs_manifest(%{
         "version" => version,
         "archive_sha256" => digest,
         "package_lock_sha256" => lock_digest,
         "package_manifest_sha256" => package_digest,
         "abi" => "arm64-v8a",
         "prefix" => "/data/data/io.hndbean/files/usr"
       })
       when is_binary(version) and version != "" and is_binary(digest) and
              byte_size(digest) == 64 and is_binary(lock_digest) and
              byte_size(lock_digest) == 64 and is_binary(package_digest) and
              byte_size(package_digest) == 64,
       do: :ok

  defp validate_rootfs_manifest(_), do: {:error, :invalid_manifest_contract}

  @doc false
  def validate_package_manifest(%{
        "repository" => repository,
        "index_sha256" => index_digest,
        "license_review_required" => false,
        "packages" => [_ | _]
      })
      when is_binary(repository) and repository != "" and is_binary(index_digest) and
             byte_size(index_digest) == 64,
      do: :ok

  def validate_package_manifest(%{"license_review_required" => true}),
    do: {:error, :license_review_required}

  def validate_package_manifest(_), do: {:error, :invalid_package_manifest_contract}

  defp file_sha256(path) do
    digest =
      path
      |> File.stream!(1_048_576, [])
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    {:ok, digest}
  rescue
    error -> {:error, {:hash_failed, error.__struct__}}
  end

  defp add_developer_host_profile!(dest, opts) do
    path = Path.join(dest, "priv/android_host_profile.json")

    if Keyword.get(opts, :developer_sideload, false) do
      profile = %{
        "profile" => "android_developer_sideload",
        "shell" => true,
        "shell_jobs" => false,
        "shell_isolation" => "none",
        "termux_prefix" => "/data/data/io.hndbean/files/usr"
      }

      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Handbean.JSON.encode!(profile))
    else
      if File.exists?(path) do
        Mix.raise("android_host_profile.json must not enter a standard APK")
      end
    end
  end

  @doc false
  def gradle_assemble_args(abi, opts \\ []) when is_binary(abi) do
    args = ["assembleDebug", "--no-daemon", "-PmobAbi=#{abi}"]

    args =
      if Keyword.get(opts, :foundation_test_app, false) do
        args ++ ["-PfoundationTestApp"]
      else
        args
      end

    if Keyword.get(opts, :developer_sideload, false) do
      args ++ ["-PdeveloperSideload"]
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

  defp install_apk(apk, device, opts) do
    adb = System.find_executable("adb") || Mix.raise("adb not found")
    serial = device || default_serial()
    args = if serial, do: ["-s", serial, "install", "-r", apk], else: ["install", "-r", apk]
    Mix.shell().info("  adb #{Enum.join(args, " ")}")

    case System.cmd(adb, args, stderr_to_stdout: true) do
      {out, 0} ->
        Mix.shell().info(out)
        launch(serial, opts)

      {out, rc} ->
        Mix.raise("adb install failed (#{rc}): #{out}")
    end
  end

  defp launch(nil, _opts), do: :ok

  defp launch(serial, opts) do
    adb = System.find_executable("adb")

    System.cmd(
      adb,
      ["-s", serial, "shell", "am", "start", "-n", activity(opts)],
      stderr_to_stdout: true
    )

    :ok
  end

  defp activity(opts) do
    if Keyword.get(opts, :developer_sideload, false),
      do: @developer_activity,
      else: @standard_activity
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
