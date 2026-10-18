defmodule Mix.Tasks.Mob.WriteLocalProperties do
  @shortdoc "Write android/local.properties for CI / a fresh clone"
  @moduledoc false

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    android_home =
      System.get_env("ANDROID_HOME") ||
        System.get_env("ANDROID_SDK_ROOT") ||
        Mix.raise("ANDROID_HOME or ANDROID_SDK_ROOT must be set")

    otp_arm64 = ensure!("arm64-v8a")
    otp_arm32 = ensure!("armeabi-v7a")
    otp_x86 = ensure!("x86_64")
    mob_dir = Path.expand("deps/mob")

    File.mkdir_p!("android")

    # Write in-place. `/tmp` and the project can be different filesystems,
    # so File.rename!/2 would fail with :exdev.
    File.write!("android/local.properties", """
    sdk.dir=#{android_home}
    mob.otp_release=#{otp_arm64}
    mob.otp_release_arm32=#{otp_arm32}
    mob.otp_release_x86_64=#{otp_x86}
    mob.mob_dir=#{mob_dir}
    """)

    Mix.shell().info("android/local.properties written")
  end

  defp ensure!(abi) do
    case MobDev.OtpDownloader.ensure_android(abi) do
      {:ok, path} ->
        path

      other ->
        Mix.raise("OTP #{abi}: #{inspect(other)}")
    end
  end
end
