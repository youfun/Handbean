defmodule Handbean.WebUILocalVersionTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @powershell System.find_executable("pwsh") || System.find_executable("powershell")

  if match?({:win32, _}, :os.type()) and @powershell do
    setup do
      root = Path.join(System.tmp_dir!(), "handbean local version #{Ecto.UUID.generate()}")
      scripts = Path.join(root, "scripts")
      File.mkdir_p!(scripts)
      File.cp!(Path.join(@root, "scripts/start.ps1"), Path.join(scripts, "start.ps1"))
      on_exit(fn -> File.rm_rf!(root) end)
      %{root: root, launcher: Path.join(scripts, "start.ps1")}
    end

    test "checkout starts the release selected by current.txt", context do
      write_release(context.root, "_build/prod/rel/handbean", "legacy")
      write_release(context.root, "_build/local-webui/versions/selected", "selected")
      write_current(context.root, "selected")

      assert {output, 0} = run(context.launcher)
      assert output =~ "RELEASE selected start"
      refute output =~ "RELEASE legacy"
    end

    test "an invalid or missing selected release does not fall back to legacy", context do
      write_release(context.root, "_build/prod/rel/handbean", "legacy")

      for pointer <- ["../legacy", "missing"] do
        write_current(context.root, pointer)
        {output, status} = run(context.launcher)
        assert status != 0
        refute output =~ "RELEASE legacy"
      end
    end
  end

  defp write_release(root, relative, label) do
    release = Path.join(root, relative)
    File.mkdir_p!(Path.join(release, "bin"))

    File.write!(
      Path.join(release, "bin/handbean.bat"),
      "@echo off\r\necho RELEASE #{label} %1\r\nexit /b 0\r\n"
    )
  end

  defp write_current(root, value) do
    local_root = Path.join(root, "_build/local-webui")
    File.mkdir_p!(local_root)
    File.write!(Path.join(local_root, "current.txt"), value)
  end

  defp run(launcher) do
    env = [
      {"HOME", System.tmp_dir!()},
      {"USERPROFILE", System.tmp_dir!()},
      {"SECRET_KEY_BASE", String.duplicate("launcher-fixture", 4)}
    ]

    System.cmd(@powershell, ["-NoProfile", "-NonInteractive", "-File", launcher],
      stderr_to_stdout: true,
      env: env
    )
  end
end
