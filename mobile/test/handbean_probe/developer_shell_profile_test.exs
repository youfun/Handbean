defmodule HandbeanProbe.DeveloperShellProfileTest do
  use ExUnit.Case, async: false

  setup do
    root = Path.join(System.tmp_dir!(), "developer-shell-#{System.unique_integer([:positive])}")
    priv = Path.join(root, "priv")
    data = Path.join(root, "data")
    prefix = Path.join(root, "usr")
    previous_shell = Application.get_env(:handbean, :shell_path)
    File.mkdir_p!(priv)
    File.mkdir_p!(Path.join(prefix, "bin"))
    File.mkdir_p!(Path.join(prefix, "lib"))
    File.write!(Path.join(prefix, "bin/bash"), "stub")
    File.write!(Path.join(prefix, "lib/libtermux-exec.so"), "stub")

    on_exit(fn ->
      File.rm_rf!(root)

      if previous_shell,
        do: Application.put_env(:handbean, :shell_path, previous_shell),
        else: Application.delete_env(:handbean, :shell_path)
    end)

    %{priv: priv, data: data, prefix: prefix}
  end

  test "an exact packaged developer profile enables only synchronous unisolated shell", context do
    write_profile(context.priv, context.prefix)

    profile =
      HandbeanProbe.App.developer_shell_profile(context.priv, context.data,
        expected_prefix: context.prefix
      )

    assert profile.shell == true
    assert profile.shell_jobs == false
    assert profile.shell_isolation == :none
    assert profile.shell_environment["PREFIX"] == context.prefix
    assert profile.shell_environment["HOME"] == Path.join(context.data, "home")
    assert profile.shell_environment["TMPDIR"] == Path.join(context.data, "tmp")
    assert profile.shell_environment["MIX_OS_CONCURRENCY_LOCK"] == "0"
    assert Application.get_env(:handbean, :shell_path) == Path.join(context.prefix, "bin/bash")
    assert File.dir?(Path.join(context.data, "home"))
    assert File.dir?(Path.join(context.data, "tmp"))
  end

  test "missing runtime files keep shell disabled", context do
    write_profile(context.priv, context.prefix)
    File.rm!(Path.join(context.prefix, "lib/libtermux-exec.so"))

    assert HandbeanProbe.App.developer_shell_profile(context.priv, context.data,
             expected_prefix: context.prefix
           ) == %{}

    assert Application.get_env(:handbean, :shell_path) == nil
  end

  test "a near-match profile is rejected", context do
    write_profile(context.priv, context.prefix, %{"shell_jobs" => true})

    assert HandbeanProbe.App.developer_shell_profile(context.priv, context.data,
             expected_prefix: context.prefix
           ) == %{}
  end

  defp write_profile(priv, prefix, overrides \\ %{}) do
    profile =
      Map.merge(
        %{
          "profile" => "android_developer_sideload",
          "shell" => true,
          "shell_jobs" => false,
          "shell_isolation" => "none",
          "termux_prefix" => prefix
        },
        overrides
      )

    File.write!(Path.join(priv, "android_host_profile.json"), Handbean.JSON.encode!(profile))
  end
end
