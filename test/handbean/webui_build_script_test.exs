defmodule Handbean.WebUIBuildScriptTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @script Path.join(@root, "scripts/build_webui.ps1")
  @powershell System.find_executable("pwsh") || System.find_executable("powershell")

  if match?({:win32, _}, :os.type()) and @powershell do
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
  end

  defp run_build(args, env_overrides \\ %{}) do
    env =
      %{"HOME" => System.tmp_dir!(), "USERPROFILE" => System.tmp_dir!(), "HANDBEAN_VCVARS" => nil}
      |> Map.merge(env_overrides)
      |> Map.to_list()

    System.cmd(@powershell, ["-NoProfile", "-NonInteractive", "-File", @script] ++ args,
      stderr_to_stdout: true,
      env: env
    )
  end
end
