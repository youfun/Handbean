defmodule Handbean.ReleaseVersionTest do
  use ExUnit.Case, async: true

  # Packaging boundary failures: mismatched tags, malformed version/build,
  # stale bundle metadata, and source templates changed by version stamping.
  # Exercise the actual shell entry point without compiling a native binary.
  @root Path.expand("../..", __DIR__)

  setup do
    root = Path.join(System.tmp_dir!(), "handbean-version-#{Ecto.UUID.generate()}")
    File.mkdir_p!(Path.join(root, "scripts"))
    on_exit(fn -> File.rm_rf!(root) end)
    File.cp!(Path.join(@root, "scripts/version.sh"), Path.join(root, "scripts/version.sh"))
    File.write!(Path.join(root, "version.properties"), "version=0.12.34\nbuild=28\n")
    %{root: root}
  end

  test "reads version and build independently of working directory", %{root: root} do
    assert {"0.12.34\n", 0} = run(root, ["version"])
    assert {"28\n", 0} = run(root, ["build"])
    assert {_, 0} = run(root, ["check-tag", "v0.12.34"])
    assert {_, 1} = run(root, ["check-tag", "v0.12.33"])

    File.write!(Path.join(root, "version.properties"), "version=0.12.34\r\nbuild=28\r\n")
    assert {"0.12.34\n", 0} = run(root, ["version"])
    assert {"28\n", 0} = run(root, ["build"])
  end

  test "both Mix projects read a changed single version source", %{root: root} do
    File.write!(Path.join(root, "version.properties"), "version=0.12.34\r\nbuild=28\r\n")
    File.mkdir_p!(Path.join(root, "mobile"))

    for relative <- ["mix.exs", "mobile/mix.exs"] do
      path = Path.join(root, relative)
      File.cp!(Path.join(@root, relative), path)

      assert {output, 0} =
               System.cmd(
                 "elixir",
                 [
                   "-e",
                   "Mix.start(); Code.require_file(hd(System.argv())); IO.puts(Mix.Project.config()[:version])",
                   path
                 ],
                 stderr_to_stdout: true,
                 env: [{"ERL_FLAGS", "+S 2:2"}]
               )

      assert String.ends_with?(output, "0.12.34\n")
    end
  end

  test "rejects ambiguous or invalid release metadata", %{root: root} do
    for metadata <- [
          "version=0.12.34\nbuild=0\n",
          "version=0.12.34-rc.1\nbuild=28\n",
          "version=0.12.34\nversion=0.12.35\nbuild=28\n",
          "version=0.12.34\nbuild=2100000001\n"
        ] do
      File.write!(Path.join(root, "version.properties"), metadata)
      assert {_, 1} = run(root, ["version"])
    end
  end

  test "rejects a stale Web release, including one bundled in a desktop app", %{root: root} do
    web = Path.join(root, "web")
    File.mkdir_p!(Path.join(web, "releases"))
    metadata = Path.join(web, "releases/start_erl.data")
    File.write!(metadata, "17.0 0.12.34\n")
    assert {_, 0} = run(root, ["verify-web", web])
    File.write!(metadata, "17.0 0.12.33\n")
    assert {_, 1} = run(root, ["verify-web", web])
  end

  test "APK verification handles large entry listings without pipefail false negatives", %{
    root: root
  } do
    android_home = Path.join(root, "android-sdk")
    aapt = Path.join(android_home, "build-tools/35.0.0/aapt")
    fake_bin = Path.join(root, "bin")
    unzip = Path.join(fake_bin, "unzip")
    apk = Path.join(root, "developer.apk")

    File.mkdir_p!(Path.dirname(aapt))
    File.mkdir_p!(fake_bin)
    File.write!(apk, "fixture")

    File.write!(
      aapt,
      """
      #!/bin/sh
      printf '%s\\n' \
        "package: name='io.hndbean' versionCode='28' versionName='0.12.34-developer'" \
        "targetSdkVersion:'28'"
      """
    )

    File.write!(
      unzip,
      """
      #!/bin/sh
      printf '%s\\n' \
        assets/termux-rootfs.tgz \
        assets/termux-rootfs.json \
        assets/termux-packages.json
      i=0
      while [ "$i" -lt 10000 ]; do
        printf 'assets/filler/%05d\\n' "$i"
        i=$((i + 1))
      done
      """
    )

    File.chmod!(aapt, 0o755)
    File.chmod!(unzip, 0o755)

    env = [
      {"ANDROID_HOME", android_home},
      {"PATH", fake_bin <> ":" <> System.fetch_env!("PATH")}
    ]

    assert {_, 0} = run(root, ["verify-apk", apk, "developer"], env)
  end

  if :os.type() == {:unix, :darwin} do
    test "mobile preparation alias generates the plist before native packaging", %{root: root} do
      mobile = Path.join(root, "mobile")
      File.mkdir_p!(Path.join(mobile, "ios"))
      File.cp!(Path.join(@root, "mobile/mix.exs"), Path.join(mobile, "mix.exs"))

      File.cp!(
        Path.join(@root, "mobile/ios/Info.plist.template"),
        Path.join(mobile, "ios/Info.plist.template")
      )

      assert {_, 0} =
               System.cmd(
                 "elixir",
                 [
                   "-e",
                   "Mix.start(); Code.require_file(\"mix.exs\"); Mix.Task.run(\"handbean.prepare_ios\")"
                 ],
                 cd: mobile,
                 stderr_to_stdout: true,
                 env: [{"ERL_FLAGS", "+S 2:2"}]
               )

      assert {_, 0} = run(root, ["verify-plist", Path.join(mobile, "ios/Info.plist")])
    end

    test "stamps and verifies generated plist without changing template", %{root: root} do
      template = Path.join(root, "Info.plist.template")
      output = Path.join(root, "Info.plist")
      source = File.read!(Path.join(@root, "mobile/ios/Info.plist.template"))
      File.write!(template, source)

      assert {_, 0} = run(root, ["plist", template, output])
      assert File.read!(template) == source
      assert {_, 0} = run(root, ["verify-plist", output])

      assert {"0.12.34\n", 0} =
               System.cmd("/usr/libexec/PlistBuddy", [
                 "-c",
                 "Print :CFBundleShortVersionString",
                 output
               ])

      assert {"28\n", 0} =
               System.cmd("/usr/libexec/PlistBuddy", ["-c", "Print :CFBundleVersion", output])

      app = Path.join(root, "Payload/Handbean.app")
      File.mkdir_p!(app)
      File.cp!(output, Path.join(app, "Info.plist"))
      ipa = Path.join(root, "Handbean.ipa")
      assert {_, 0} = System.cmd("zip", ["-qr", ipa, "Payload"], cd: root)
      assert {_, 0} = run(root, ["verify-ipa", ipa])

      {_, 0} =
        System.cmd("/usr/libexec/PlistBuddy", [
          "-c",
          "Set :CFBundleVersion 27",
          output
        ])

      assert {_, 1} = run(root, ["verify-plist", output])
      File.cp!(output, Path.join(app, "Info.plist"))
      assert {_, 0} = System.cmd("zip", ["-qr", ipa, "Payload"], cd: root)
      assert {_, 1} = run(root, ["verify-ipa", ipa])
    end
  end

  defp run(root, args, env \\ []) do
    System.cmd("bash", [Path.join(root, "scripts/version.sh") | args],
      cd: System.tmp_dir!(),
      stderr_to_stdout: true,
      env: env
    )
  end
end
