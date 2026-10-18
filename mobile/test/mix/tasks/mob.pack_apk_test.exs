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
