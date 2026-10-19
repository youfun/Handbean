defmodule Handbean.WebUILauncherTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @powershell System.find_executable("pwsh") || System.find_executable("powershell")
  @layouts if(match?({:win32, _}, :os.type()),
             do: [:package, :checkout, :versioned_checkout],
             else: [:package, :checkout]
           )
  @launchers if(match?({:unix, _}, :os.type()),
               do: [{"Unix", "bash", [], "start.sh", "--lan"}],
               else: [{"Windows batch", "cmd", ["/d", "/c"], "start.bat", "-LanHost"}]
             ) ++
               if(@powershell,
                 do: [
                   {"PowerShell", @powershell, ["-NoProfile", "-NonInteractive", "-File"],
                    "start.ps1", "-LanHost"}
                 ],
                 else: []
               )

  setup do
    root = Path.join(System.tmp_dir!(), "handbean launcher #{Ecto.UUID.generate()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  for {name, command, prefix, script, lan_option} <- @launchers do
    @tag launcher: {command, prefix, script, lan_option}
    test "#{name}: package and checkout launch locally by default and preserve release failures",
         context do
      for layout <- @layouts do
        launcher = fixture(context.root, elem(context.launcher, 2), layout)
        assert {output, 0} = run(context, launcher, [])
        assert output =~ "LAUNCH start host=localhost port=5008 public=unset http=unset"
        assert output =~ "layout=#{layout}"
        refute output =~ "strong password"
        assert {_, 7} = run(context, launcher, [], %{"LAUNCH_TEST_EXIT" => "7"})
      end
    end

    @tag launcher: {command, prefix, script, lan_option}
    test "#{name}: LAN mode forwards host, port and password with bilingual safety reminders",
         context do
      for layout <- @layouts do
        launcher = fixture(context.root, elem(context.launcher, 2), layout)
        args = [elem(context.launcher, 3), "192.0.2.10"]
        env = %{"PORT" => "51234", "HANDBEAN_ACCESS_PASSWORD" => "launcher-test-secret"}

        assert {output, 0} = run(context, launcher, args, env)

        assert output =~
                 "LAUNCH start host=192.0.2.10 port=51234 public=1 http=1 mode=password password_ok=yes"

        assert output =~ "http://192.0.2.10:51234"
        assert output =~ "layout=#{layout}"
        assert output =~ "强密码"
        assert output =~ "strong password"
        assert output =~ "HTTP 不加密"
        assert output =~ "HTTP does not encrypt"
        refute output =~ "launcher-test-secret"
      end
    end

    @tag launcher: {command, prefix, script, lan_option}
    test "#{name}: LAN startup fails closed without a password or with an invalid host",
         context do
      launcher = fixture(context.root, elem(context.launcher, 2), :package)
      option = elem(context.launcher, 3)

      invalid_cases = [[option], [option, "http://192.0.2.10:5008"]]

      cases =
        if elem(context.launcher, 2) == "start.bat",
          do: invalid_cases,
          else: [[option, "192.0.2.10"] | invalid_cases]

      for args <- cases do
        {output, status} = run(context, launcher, args)
        assert status != 0
        refute output =~ "LAUNCH "
      end
    end
  end

  if match?({:win32, _}, :os.type()) do
    test "repository root launcher selects current version and forwards LAN arguments", context do
      launcher_context =
        Map.put(context, :launcher, {"cmd", ["/d", "/c"], "start.bat", "-LanHost"})

      _script_launcher = fixture(context.root, "start.bat", :versioned_checkout)
      root_launcher = Path.join(context.root, "start.bat")
      File.cp!(Path.join(@root, "start.bat"), root_launcher)

      env = %{"PORT" => "51234", "HANDBEAN_ACCESS_PASSWORD" => "launcher-test-secret"}

      assert {output, 0} =
               run(launcher_context, root_launcher, ["-LanHost", "192.0.2.10"], env)

      assert output =~ "layout=versioned_checkout"
      assert output =~ "host=192.0.2.10 port=51234 public=1 http=1"
      assert {_, 7} = run(launcher_context, root_launcher, [], %{"LAUNCH_TEST_EXIT" => "7"})
    end
  end

  defp fixture(root, script, layout) do
    checkout? = layout in [:checkout, :versioned_checkout]
    launcher_dir = Path.join(root, if(checkout?, do: "scripts", else: "package"))

    release =
      case layout do
        :package -> launcher_dir
        :checkout -> Path.join(root, "_build/prod/rel/handbean")
        :versioned_checkout -> Path.join(root, "_build/local-webui/versions/fixture-version")
      end

    if layout == :versioned_checkout do
      local_root = Path.join(root, "_build/local-webui")
      File.mkdir_p!(local_root)
      File.write!(Path.join(local_root, "current.txt"), "fixture-version")
    end

    File.mkdir_p!(Path.join(release, "bin"))
    File.mkdir_p!(launcher_dir)

    for name <- ["start.sh", "start.ps1", "start.bat"] do
      File.cp!(Path.join(@root, "scripts/#{name}"), Path.join(launcher_dir, name))
    end

    binary =
      Path.join(release, if(script == "start.sh", do: "bin/handbean", else: "bin/handbean.bat"))

    source =
      if match?({:win32, _}, :os.type()) do
        """
        @echo off
        set password_ok=no
        if "%HANDBEAN_ACCESS_PASSWORD%"=="launcher-test-secret" set password_ok=yes
        if not defined HANDBEAN_PUBLIC_BIND set HANDBEAN_PUBLIC_BIND=unset
        if not defined HANDBEAN_ALLOW_HTTP set HANDBEAN_ALLOW_HTTP=unset
        if not defined HANDBEAN_ACCESS_MODE set HANDBEAN_ACCESS_MODE=unset
        echo LAUNCH %1 host=%PHX_HOST% port=%PORT% public=%HANDBEAN_PUBLIC_BIND% http=%HANDBEAN_ALLOW_HTTP% mode=%HANDBEAN_ACCESS_MODE% password_ok=%password_ok% layout=#{layout}
        if defined LAUNCH_TEST_EXIT exit /b %LAUNCH_TEST_EXIT%
        exit /b 0
        """
      else
        """
        #!/usr/bin/env bash
        password_ok=no
        if [[ "${HANDBEAN_ACCESS_PASSWORD:-}" == launcher-test-secret ]]; then password_ok=yes; fi
        printf 'LAUNCH %s host=%s port=%s public=%s http=%s mode=%s password_ok=%s layout=#{layout}\n' \
          "$1" "$PHX_HOST" "$PORT" "${HANDBEAN_PUBLIC_BIND:-unset}" \
          "${HANDBEAN_ALLOW_HTTP:-unset}" "${HANDBEAN_ACCESS_MODE:-unset}" "$password_ok"
        exit "${LAUNCH_TEST_EXIT:-0}"
        """
      end

    File.write!(binary, source)
    File.chmod!(binary, 0o755)
    Path.join(launcher_dir, script)
  end

  defp run(context, launcher, args, overrides \\ %{}) do
    {command, prefix, _script, _lan_option} = context.launcher

    env =
      ~w(PHX_SERVER PHX_HOST PORT DATABASE_PATH HANDBEAN_PUBLIC_BIND HANDBEAN_ALLOW_HTTP HANDBEAN_ACCESS_MODE HANDBEAN_ACCESS_PASSWORD HANDBEAN_ACCESS_USERNAME HANDBEAN_FILE_MANAGER LAUNCH_TEST_EXIT)
      |> Map.new(&{&1, nil})
      |> Map.merge(%{
        "HOME" => Path.join(context.root, "home"),
        "USERPROFILE" => Path.join(context.root, "home"),
        "SECRET_KEY_BASE" => String.duplicate("launcher-fixture", 4)
      })
      |> Map.merge(overrides)

    System.cmd(command, prefix ++ [launcher | args],
      cd: System.tmp_dir!(),
      stderr_to_stdout: true,
      env: Map.to_list(env)
    )
  end
end
