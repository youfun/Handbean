defmodule Handbean.Git.CLI.DetectTest do
  use ExUnit.Case, async: false

  alias Handbean.Git.CLI.Detect

  setup do
    dir = Path.join(System.tmp_dir!(), "git-detect-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    previous = Application.get_env(:handbean, :git_executable)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:handbean, :git_executable, previous),
        else: Application.delete_env(:handbean, :git_executable)

      File.rm_rf(dir)
    end)

    %{dir: dir}
  end

  test "probes a working Git on PATH" do
    Application.delete_env(:handbean, :git_executable)
    assert {:ok, %{executable: path, version: version}} = Detect.probe()
    assert File.exists?(path)
    assert version =~ ~r/^\d+\.\d+/
  end

  test "missing configured path is not treated as available", %{dir: dir} do
    path = Path.join(dir, "no-such-git")
    Application.put_env(:handbean, :git_executable, path)
    assert {:error, message} = Detect.probe()
    assert message =~ "not found"
    assert message =~ path
  end

  test "a non-executable file is not treated as available", %{dir: dir} do
    path = Path.join(dir, "git")
    File.write!(path, "#!/bin/sh\necho git version 2.0.0\n")
    File.chmod!(path, 0o644)
    Application.put_env(:handbean, :git_executable, path)
    assert {:error, message} = Detect.probe()
    assert message =~ "not runnable"
  end

  test "probe requires git --version, not just a file named git", %{dir: dir} do
    path = Path.join(dir, "git")
    File.write!(path, "#!/bin/sh\necho not a git implementation\n")
    File.chmod!(path, 0o755)
    Application.put_env(:handbean, :git_executable, path)
    assert {:error, message} = Detect.probe()
    assert message =~ "failed" or message =~ "not"
    refute message =~ "not found"
  end

  test "nonzero probe output mentioning xcode-select is explained", %{dir: dir} do
    path = Path.join(dir, "git")

    File.write!(
      path,
      "#!/bin/sh\necho 'xcode-select: note: No developer tools were found' >&2\nexit 1\n"
    )

    File.chmod!(path, 0o755)
    Application.put_env(:handbean, :git_executable, path)
    assert {:error, message} = Detect.probe()
    assert message =~ "xcode-select --install"
    refute message =~ "not found"
  end

  test "a hanging binary fails the probe with timeout, then is cleaned up", %{dir: dir} do
    path = Path.join(dir, "git")
    File.write!(path, "#!/bin/sh\nexec sleep 30\n")
    File.chmod!(path, 0o755)
    Application.put_env(:handbean, :git_executable, path)
    assert {:error, message} = Detect.probe(timeout_ms: 400)
    assert message =~ "timed out"
  end

  test "a valid symlink to an executable Git is accepted", %{dir: dir} do
    target = System.find_executable("git")
    bindir = Path.join(dir, "bin")
    File.mkdir_p!(bindir)
    link = Path.join(bindir, "git")
    File.ln_s!(target, link)
    assert {:ok, %{executable: ^link, version: version}} = Detect.probe(executable: link)
    assert version =~ ~r/^\d+\.\d+/
  end

  test "a broken symlink is rejected", %{dir: dir} do
    link = Path.join(dir, "broken-git")
    File.ln_s!(Path.join(dir, "missing-git"), link)
    assert {:error, message} = Detect.probe(executable: link)
    assert message =~ "broken symlink"
    assert message =~ link
  end

  test "a symlink to a non-executable file is rejected", %{dir: dir} do
    target = Path.join(dir, "not-git")
    File.write!(target, "#!/bin/sh\necho git version 2.0.0\n")
    File.chmod!(target, 0o644)
    link = Path.join(dir, "git-link")
    File.ln_s!(target, link)
    assert {:error, message} = Detect.probe(executable: link)
    assert message =~ "not runnable"
  end

  test "unavailable Git is returned from perform without falling back to ExGit", %{dir: dir} do
    Application.put_env(:handbean, :git_executable, Path.join(dir, "missing"))
    ctx = %{working_directory: dir}
    assert {:error, message} = Handbean.Tool.Builtin.Git.execute(%{"action" => "init"}, ctx)
    assert message =~ "not found"
    refute Code.ensure_loaded?(ExGit)
  end
end
