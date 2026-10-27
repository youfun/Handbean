defmodule Mix.Tasks.Mob.PackApkTest do
  use ExUnit.Case, async: false

  test "packaging includes the manually-started shared runtime closure" do
    build = Path.join(System.tmp_dir!(), "pack_runtime_#{System.unique_integer([:positive])}")
    shared = Path.join([build, "lib", "handbean", "ebin"])
    phoenix_ecto = Path.join([build, "lib", "phoenix_ecto", "ebin"])
    File.mkdir_p!(shared)
    File.mkdir_p!(phoenix_ecto)

    File.write!(
      Path.join(shared, "handbean.app"),
      "{application,handbean,[{applications,[kernel,stdlib,phoenix_ecto]}]}."
    )

    File.write!(
      Path.join(phoenix_ecto, "phoenix_ecto.app"),
      "{application,phoenix_ecto,[{applications,[kernel,stdlib]}]}."
    )

    on_exit(fn -> File.rm_rf(build) end)

    dirs = Mix.Tasks.Mob.PackApk.runtime_beam_dirs(build, [])
    assert shared in dirs
    assert phoenix_ecto in dirs
  end

  test "Android packaging excludes root Web assets and preserves runtime and mobile resources" do
    root = Path.join(System.tmp_dir!(), "pack_priv_#{System.unique_integer([:positive])}")
    root_priv = Path.join(root, "root_priv")
    mobile_priv = Path.join(root, "mobile_priv")
    dest = Path.join(root, "staging")
    versions = File.read!(".tool-versions")
    [_, elixir] = Regex.run(~r/^elixir\s+([^-\s]+)/m, versions)
    [_, otp] = Regex.run(~r/^erlang\s+(\d+)/m, versions)
    manifest = Handbean.JSON.encode!(%{"elixir" => elixir, "otp" => otp})

    for {base, path, content} <- [
          {root_priv, "static/assets/js/app.js", "stale web bundle"},
          {root_priv, "static/cache_manifest.json", "stale web manifest"},
          {root_priv, "repo/migrations/root.exs", "root migration"},
          {root_priv, "skills/example/SKILL.md", "skill"},
          {mobile_priv, "repo/migrations/mobile.exs", "mobile migration"},
          {mobile_priv, "mix_toolchain/manifest.json", manifest},
          {mobile_priv, "static/native.txt", "mobile resource"},
          {mobile_priv, "static/assets/js/app.js", "stale mobile web bundle"},
          {mobile_priv, "static/cache_manifest.json", "stale mobile web manifest"}
        ] do
      file = Path.join(base, path)
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, content)
    end

    on_exit(fn -> File.rm_rf(root) end)
    Mix.Tasks.Mob.PackApk.merge_priv!(dest, root_priv, mobile_priv)

    assert File.read!(Path.join(dest, "priv/repo/migrations/root.exs")) == "root migration"
    assert File.read!(Path.join(dest, "priv/repo/migrations/mobile.exs")) == "mobile migration"
    assert File.read!(Path.join(dest, "priv/skills/example/SKILL.md")) == "skill"
    assert File.read!(Path.join(dest, "priv/mix_toolchain/manifest.json")) == manifest
    assert File.read!(Path.join(dest, "priv/static/native.txt")) == "mobile resource"
    refute File.exists?(Path.join(dest, "priv/static/assets/js/app.js"))
    refute File.exists?(Path.join(dest, "priv/static/cache_manifest.json"))
    assert File.exists?(Path.join(root_priv, "static/assets/js/app.js"))
  end

  test "default assemble args do not select the foundation test app" do
    assert Mix.Tasks.Mob.PackApk.gradle_assemble_args("x86_64") ==
             ["assembleDebug", "--no-daemon", "-PmobAbi=x86_64"]

    assert Mix.Tasks.Mob.PackApk.gradle_assemble_args("x86_64", foundation_test_app: false) ==
             ["assembleDebug", "--no-daemon", "-PmobAbi=x86_64"]
  end

  test "foundation-test-app forwards the Gradle property" do
    assert Mix.Tasks.Mob.PackApk.gradle_assemble_args("x86_64", foundation_test_app: true) ==
             ["assembleDebug", "--no-daemon", "-PmobAbi=x86_64", "-PfoundationTestApp"]
  end

  test "developer sideload is explicit and ARM64-only" do
    assert Mix.Tasks.Mob.PackApk.gradle_assemble_args("arm64-v8a", developer_sideload: true) ==
             ["assembleDebug", "--no-daemon", "-PmobAbi=arm64-v8a", "-PdeveloperSideload"]

    assert :ok =
             Mix.Tasks.Mob.PackApk.validate_variant!("arm64-v8a", developer_sideload: true)

    assert_raise Mix.Error, ~r/only --abi arm64-v8a/, fn ->
      Mix.Tasks.Mob.PackApk.validate_variant!("x86_64", developer_sideload: true)
    end

    assert_raise Mix.Error, ~r/mutually exclusive/, fn ->
      Mix.Tasks.Mob.PackApk.validate_variant!("arm64-v8a",
        developer_sideload: true,
        foundation_test_app: true
      )
    end
  end

  test "developer package manifest requires completed license review" do
    manifest = %{
      "repository" => "https://packages.termux.dev/apt/termux-main",
      "index_sha256" => String.duplicate("a", 64),
      "license_review_required" => false,
      "packages" => [%{"name" => "bash"}]
    }

    assert :ok = Mix.Tasks.Mob.PackApk.validate_package_manifest(manifest)

    assert {:error, :license_review_required} =
             Mix.Tasks.Mob.PackApk.validate_package_manifest(%{
               manifest
               | "license_review_required" => true
             })
  end

  test "mobile target dependency libraries come from the active build path" do
    assert Mix.Tasks.Mob.PackApk.dep_build_dir(:exqlite) ==
             Path.join([Mix.Project.build_path(), "lib", "exqlite"])
  end

  test "prepacked Mix toolchain must match the Android runtime pin" do
    manifest = %{"elixir" => "1.20.1", "otp" => "29"}

    assert :ok =
             Mix.Tasks.Mob.PackApk.validate_prepacked_mix_toolchain(manifest, "1.20.1", "29")

    assert {:error, message} =
             Mix.Tasks.Mob.PackApk.validate_prepacked_mix_toolchain(
               %{"elixir" => "1.20.2", "otp" => "29"},
               "1.20.1",
               "29"
             )

    assert message =~ "prepacked Mix toolchain is Elixir 1.20.2/OTP 29"
  end

  test "explicit model seed supports nativechat and foundation packs" do
    seed = Path.join(System.tmp_dir!(), "seed_#{System.unique_integer([:positive])}.json")
    File.write!(seed, "{}")
    on_exit(fn -> File.rm(seed) end)

    assert {:ok, ^seed} =
             Mix.Tasks.Mob.PackApk.resolve_models_seed(models_seed: seed)

    assert {:ok, ^seed} =
             Mix.Tasks.Mob.PackApk.resolve_models_seed(
               foundation_test_app: true,
               models_seed: seed
             )

    assert {:error, :seed_missing} =
             Mix.Tasks.Mob.PackApk.resolve_models_seed(
               foundation_test_app: true,
               models_seed: "/no/such/foundation_test_models.seed.json"
             )

    assert {:error, :seed_missing} =
             Mix.Tasks.Mob.PackApk.resolve_models_seed(models_seed: "/no/such/models.seed.json")
  end

  test "environment seed cannot silently enter nativechat builds" do
    previous = System.get_env("HANDBEAN_FOUNDATION_MODELS_SEED")
    System.put_env("HANDBEAN_FOUNDATION_MODELS_SEED", "/no/such/private.seed.json")

    on_exit(fn ->
      if previous,
        do: System.put_env("HANDBEAN_FOUNDATION_MODELS_SEED", previous),
        else: System.delete_env("HANDBEAN_FOUNDATION_MODELS_SEED")
    end)

    assert {:error, :seed_requires_foundation_test_app} =
             Mix.Tasks.Mob.PackApk.resolve_models_seed()
  end
end
