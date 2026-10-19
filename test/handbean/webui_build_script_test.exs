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
