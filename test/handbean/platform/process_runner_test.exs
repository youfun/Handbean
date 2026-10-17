defmodule Handbean.Platform.ProcessRunnerTest do
  use ExUnit.Case, async: false

  alias Handbean.Platform.ProcessRunner

  describe "run_bash/4" do
    test "executes simple command and returns output" do
      {:ok, output, meta} = ProcessRunner.run_bash("echo hello", nil, 5000)

      assert output =~ "hello"
      assert meta.exit_code == 0
      assert meta.timed_out == false
    end

    test "returns error for shell resolve failure" do
      assert {:error, reason} =
               ProcessRunner.run_bash("echo test", nil, 5000, shell_path: "/nonexistent/bash_xyz")

      assert reason =~ "not found" or reason =~ "does not exist"
    end

    test "captures non-zero exit code" do
      {:ok, output, meta} = ProcessRunner.run_bash("exit 42", nil, 5000)

      assert output =~ "exited with code 42"
      assert meta.exit_code == 42
    end

    test "timeout kills process", %{test: test_name} do
      # Start a long-running sleep, expect it to be killed
      {:ok, output, meta} = ProcessRunner.run_bash("sleep 30", nil, 100)

      assert meta.timed_out == true
      assert output =~ "timed out"
    end

    test "runs with cwd", %{test: test_name} do
      tmp = System.tmp_dir!()
      {:ok, output, meta} = ProcessRunner.run_bash("pwd", tmp, 5000)

      # Output should contain the tmp directory path
      assert output =~ tmp or output =~ Path.basename(tmp)
      assert meta.exit_code == 0
    end

    test "shell_prelude clears release ROOTDIR for interactive terminals" do
      old_root = System.get_env("ROOTDIR")
      System.put_env("ROOTDIR", "/incomplete/release")

      try do
        {output, 0} =
          System.cmd("/bin/sh", [
            "-c",
            ProcessRunner.shell_prelude() <> "; printf %s \"${ROOTDIR-unset}\""
          ])

        assert output == "unset"
      after
        restore_env("ROOTDIR", old_root)
      end
    end

    test "does not leak release launcher variables into child tools" do
      old_root = System.get_env("ROOTDIR")
      System.put_env("ROOTDIR", "/incomplete/release")

      try do
        assert {:ok, "unset", %{exit_code: 0}} =
                 ProcessRunner.run_bash("printf %s \"${ROOTDIR-unset}\"", nil, 5_000)
      after
        if old_root,
          do: System.put_env("ROOTDIR", old_root),
          else: System.delete_env("ROOTDIR")
      end
    end

    test "does not leak desktop backend variables into child tools" do
      keys = ~w(PHX_SERVER PORT PHX_HOST DATABASE_PATH SECRET_KEY_BASE HANDBEAN_COMPUTER_TOKEN)
      originals = Map.new(keys, &{&1, System.get_env(&1)})

      Enum.each(keys, &System.put_env(&1, "desktop-value"))

      try do
        command =
          Enum.map_join(keys, "; printf ':'; ", fn key ->
            ~s|printf %s "${#{key}-unset}"|
          end)

        assert {:ok, output, %{exit_code: 0}} = ProcessRunner.run_bash(command, nil, 5_000)
        assert String.split(output, ":") == List.duplicate("unset", length(keys))

        assert {:ok, "4100", %{exit_code: 0}} =
                 ProcessRunner.run_bash(~S|printf %s "$PORT"|, nil, 5_000,
                   env: [{"PORT", "4100"}]
                 )
      after
        Enum.each(originals, fn {key, value} -> restore_env(key, value) end)
      end
    end

    test "keeps a packaged mobile OTP erl on PATH" do
      root =
        Path.join(System.tmp_dir!(), "handbean-mobile-otp-#{System.unique_integer([:positive])}")

      erts = Path.join(root, "erts-17.0.4/bin")
      File.mkdir_p!(erts)
      File.mkdir_p!(Path.join(root, "releases"))
      File.write!(Path.join(root, "releases/start_erl.data"), "17.0.4 0.1.0\n")
      File.write!(Path.join(erts, "erl"), "#!/bin/sh\necho packaged-erl\n")
      File.chmod!(Path.join(erts, "erl"), 0o755)

      old_path = System.get_env("PATH")
      old_host = Application.get_env(:handbean, :host)
      System.put_env("PATH", erts <> ":" <> to_string(old_path))
      Application.put_env(:handbean, :host, %{packaged_mix_toolchain: true})

      try do
        assert {:ok, "packaged-erl", %{exit_code: 0}} =
                 ProcessRunner.run_bash("erl", nil, 5_000)
      after
        restore_env("PATH", old_path)
        restore_app_env(:host, old_host)
        File.rm_rf!(root)
      end
    end

    test "does not resolve erl from a release ERTS directory on PATH" do
      root =
        Path.join(
          System.tmp_dir!(),
          "handbean-release-path-#{System.unique_integer([:positive])}"
        )

      erts = Path.join(root, "erts-17.0.4/bin")
      releases = Path.join(root, "releases")
      host = Path.join(root, "host-bin")

      File.mkdir_p!(erts)
      File.mkdir_p!(releases)
      File.mkdir_p!(host)
      File.write!(Path.join(releases, "start_erl.data"), "17.0.4 0.1.0\n")
      File.write!(Path.join(erts, "erl"), "#!/bin/sh\necho release-erl\n")
      File.chmod!(Path.join(erts, "erl"), 0o755)
      File.write!(Path.join(host, "erl"), "#!/bin/sh\necho host-erl\n")
      File.chmod!(Path.join(host, "erl"), 0o755)

      old_path = System.get_env("PATH")
      System.put_env("PATH", Enum.join([erts, host, old_path], ":"))

      try do
        assert {:ok, "host-erl", %{exit_code: 0}} =
                 ProcessRunner.run_bash("erl", nil, 5_000)
      after
        restore_env("PATH", old_path)
        File.rm_rf!(root)
      end
    end

    test "owner death before Port.open does not start the command" do
      marker = Path.join(System.tmp_dir!(), "hb-open-hold-#{System.unique_integer([:positive])}")
      owner = spawn(fn -> Process.sleep(60_000) end)
      hold = self()

      task =
        Task.async(fn ->
          Handbean.Platform.ProcessRunner.run_bash("echo leaked > #{marker}", nil, 2_000,
            owner: owner,
            hold_before_open: hold
          )
        end)

      assert_receive {:held_before_open, invocation}, 1_000
      ref = Process.monitor(invocation)
      ref_owner = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^ref_owner, :process, ^owner, _reason}, 1_000
      send(invocation, :release_open)
      assert_receive {:DOWN, ^ref, :process, ^invocation, _reason}, 1_000
      assert Task.await(task, 2_000) == {:error, :cancelled}
      refute File.exists?(marker)
    end

    test "fails closed when a workspace sandbox is unavailable" do
      workspace = File.cwd!()

      assert {:error, reason} =
               ProcessRunner.run_bash("echo unsafe", workspace, 5000,
                 workspace_path: workspace,
                 sandbox_path: "/nonexistent/bwrap"
               )

      assert reason =~ "Sandbox executable not found" or
               reason =~ "Workspace-confined bash is not supported"
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp restore_app_env(key, nil), do: Application.delete_env(:handbean, key)
  defp restore_app_env(key, value), do: Application.put_env(:handbean, key, value)
end
