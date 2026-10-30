defmodule Handbean.Platform.CommandEnvironmentTest do
  use ExUnit.Case, async: false

  alias Handbean.Platform
  alias Handbean.Platform.CommandEnvironment

  test "sanitizes release and desktop internals without deleting project Phoenix values" do
    environment = %{
      "PATH" => "/usr/bin",
      "ROOTDIR" => "/app/release",
      "HANDBEAN_COMPUTER_TOKEN" => "desktop-secret",
      "PHX_SERVER" => "true",
      "PORT" => "4100"
    }

    assert CommandEnvironment.sanitize(environment) == %{
             "PATH" => "/usr/bin",
             "PHX_SERVER" => "true",
             "PORT" => "4100"
           }
  end

  test "empty workspace environments still clear backend launch values" do
    environment = Map.new(CommandEnvironment.port_env(%{}))

    assert environment["PHX_SERVER"] == false
    assert environment["PORT"] == false
    assert environment["SECRET_KEY_BASE"] == false
    assert environment["HANDBEAN_COMPUTER_TOKEN"] == false
    assert environment["ROOTDIR"] == false
  end

  test "captured and explicit project values override backend unsets" do
    captured = Map.new(CommandEnvironment.port_env(%{"PATH" => "/usr/bin", "PORT" => "4100"}))
    explicit = Map.new(CommandEnvironment.child_port_env(%{"PORT" => "4200"}))

    assert captured["PORT"] == "4100"
    assert captured["PHX_SERVER"] == false
    assert explicit["PORT"] == "4200"
    assert explicit["PHX_SERVER"] == false
  end

  @tag :tmp_dir
  test "strips release ERTS bin and locates executables with platform PATH separator", %{
    tmp_dir: tmp_dir
  } do
    sep = if Platform.windows?(), do: ";", else: ":"
    release_root = Path.join(tmp_dir, "release")
    erts_bin = Path.join(release_root, "erts-16.2/bin")
    releases_dir = Path.join(release_root, "releases")
    tool_dir = Path.join(tmp_dir, "tools")
    File.mkdir_p!(erts_bin)
    File.mkdir_p!(releases_dir)
    File.mkdir_p!(tool_dir)
    File.write!(Path.join(releases_dir, "start_erl.data"), "16.2 0.1.0\n")

    executable = Path.join(tool_dir, "my-cli")
    File.write!(executable, "#!/bin/sh\nexit 0\n")
    File.chmod!(executable, 0o755)

    path = Enum.join([erts_bin, tool_dir], sep)
    assert CommandEnvironment.strip_release_erts(path) == tool_dir
    assert CommandEnvironment.find_executable("my-cli", %{"PATH" => path}) == executable
  end

  @tag :tmp_dir
  test "locates PATHEXT shims on Windows and prefers them over extensionless npm shims", %{
    tmp_dir: tmp_dir
  } do
    if Platform.windows?() do
      bin_dir = Path.join(tmp_dir, "node_modules/.bin")
      File.mkdir_p!(bin_dir)

      # npm creates both an extensionless POSIX script and a .cmd wrapper in node_modules/.bin
      posix_shim = Path.join(bin_dir, "agent-browser")
      cmd_shim = Path.join(bin_dir, "agent-browser.cmd")
      exe_tool = Path.join(bin_dir, "droid.exe")

      File.write!(posix_shim, "#!/bin/sh\nexit 0\n")
      File.write!(cmd_shim, "@echo off\r\nexit /b 0\r\n")
      File.write!(exe_tool, "MZ")

      env = %{"Path" => bin_dir, "PATHEXT" => ".COM;.EXE;.BAT;.CMD"}

      assert CommandEnvironment.find_executable("agent-browser", env) == cmd_shim
      assert CommandEnvironment.find_executable("droid", env) == exe_tool
      assert CommandEnvironment.find_executable("droid.exe", env) == exe_tool
    end
  end
end
