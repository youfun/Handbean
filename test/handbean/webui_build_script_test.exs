defmodule Handbean.WebUIBuildScriptTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @pack_script Path.join(@root, "scripts/pack_webui.ps1")

  test "package build uses a clean target-owned Mix build path" do
    source = File.read!(@pack_script)

    build_path = ~S($mixBuildPath = Join-Path $root "_build\webui-pack\$Target\mix-build")
    clean_path = "Remove-Item -LiteralPath $mixBuildPath -Recurse -Force"
    export_path = "$env:MIX_BUILD_PATH = $mixBuildPath"
    compile = ~S(Invoke-Native "mix compile" { mix compile })

    assert source =~ build_path
    assert source =~ clean_path
    assert source =~ export_path
    assert before?(source, build_path, clean_path)
    assert before?(source, clean_path, export_path)
    assert before?(source, export_path, compile)
  end

  if match?({:unix, _}, :os.type()) do
    test "Unix build selects the native package without starting a server" do
      fixture = unix_fixture()

      for {os, arch, target} <- [
            {"Darwin", "arm64", "macos-arm64"},
            {"Linux", "x86_64", "linux-x86_64"},
            {"Linux", "aarch64", "linux-arm64"},
            {"Linux", "arm64", "linux-arm64"}
          ] do
        assert {output, 0} = run_unix_build(fixture, [], os, arch)
        assert output =~ "PACKAGE #{target}"
        assert output =~ "build complete"
        refute output =~ "SERVER STARTED"
      end

      assert {output, 7} = run_unix_build(fixture, [], "Darwin", "arm64", "7")
      refute output =~ "build complete"
      refute output =~ "SERVER STARTED"
    end

    test "Unix build help, invalid arguments and unsupported platforms do not build" do
      fixture = unix_fixture()

      assert {help, 0} = run_unix_build(fixture, ["--help"], "Darwin", "arm64")
      assert help =~ "Usage:"
      refute help =~ "PACKAGE "

      for {args, os, arch} <- [
            {["--Lan", "192.0.2.10"], "Darwin", "arm64"},
            {[], "Darwin", "x86_64"},
            {[], "Linux", "riscv64"}
          ] do
        assert {output, 2} = run_unix_build(fixture, args, os, arch)
        refute output =~ "PACKAGE "
        refute output =~ "SERVER STARTED"
      end
    end

    defp unix_fixture do
      root = Path.join(System.tmp_dir!(), "handbean build #{System.unique_integer([:positive])}")
      scripts = Path.join(root, "scripts")
      bin = Path.join(root, "bin")
      File.mkdir_p!(scripts)
      File.mkdir_p!(bin)
      on_exit(fn -> File.rm_rf!(root) end)
      File.cp!(Path.join(@root, "scripts/build_webui.sh"), Path.join(scripts, "build_webui.sh"))

      File.write!(Path.join(scripts, "pack_webui.sh"), """
      printf 'PACKAGE %s\\n' "$1"
      exit "$BUILD_TEST_EXIT"
      """)

      File.write!(Path.join(scripts, "start.sh"), "echo 'SERVER STARTED'\n")
      uname = Path.join(bin, "uname")

      File.write!(uname, """
      #!/usr/bin/env bash
      case "$1" in
        -s) echo "$BUILD_TEST_OS" ;;
        -m) echo "$BUILD_TEST_ARCH" ;;
        *) exit 2 ;;
      esac
      """)

      File.chmod!(uname, 0o755)
      root
    end

    defp run_unix_build(root, args, os, arch, exit_status \\ "0") do
      System.cmd("bash", [Path.join(root, "scripts/build_webui.sh") | args],
        cd: System.tmp_dir!(),
        stderr_to_stdout: true,
        env: [
          {"PATH", Path.join(root, "bin") <> ":" <> System.fetch_env!("PATH")},
          {"BUILD_TEST_OS", os},
          {"BUILD_TEST_ARCH", arch},
          {"BUILD_TEST_EXIT", exit_status}
        ]
      )
    end
  end

  if match?({:win32, _}, :os.type()) and
       (System.find_executable("pwsh") || System.find_executable("powershell")) do
    @script Path.join(@root, "scripts/build_webui.ps1")
    @powershell System.find_executable("pwsh") || System.find_executable("powershell")

    test "rejects unsupported targets before touching the toolchain" do
      {output, status} = run_build(["-Target", "linux-x86_64"])

      assert status != 0
      assert output =~ "windows-amd64"
      assert output =~ "本机一键编译只支持"
    end

    test "reports missing Elixir with a bilingual install hint" do
      {output, status} = run_build([], %{"PATH" => "C:\\Windows\\System32;C:\\Windows"})

      assert status != 0
      assert output =~ "Elixir/Mix not found"
      assert output =~ "未找到 Elixir/Mix"
      refute output =~ "Node.js"
    end

    defp run_build(args, env_overrides \\ %{}) do
      env =
        %{
          "HOME" => System.tmp_dir!(),
          "USERPROFILE" => System.tmp_dir!(),
          "HANDBEAN_VCVARS" => nil
        }
        |> Map.merge(env_overrides)
        |> Map.to_list()

      System.cmd(@powershell, ["-NoProfile", "-NonInteractive", "-File", @script] ++ args,
        stderr_to_stdout: true,
        env: env
      )
    end
  end

  defp before?(source, first, second) do
    {first_index, _} = :binary.match(source, first)
    {second_index, _} = :binary.match(source, second)
    first_index < second_index
  end
end
