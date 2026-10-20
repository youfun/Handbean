defmodule Handbean.Platform.ProcessSandboxTest do
  @moduledoc """
  Failure list for the OS sandbox boundary (written before the macOS backend).

  Inputs and required outcomes:

    1. Seatbelt profile text never contains a caller-supplied path; every path
       reaches `sandbox-exec` only through `-D NAME=value` parameters.
    2. The profile denies all file writes by default and re-allows only the
       workspace, the private temp dir, declared extra paths, and fixed /dev nodes.
    3. Signals may only target processes in the same sandbox.
    4. Extra writable paths: `~` is expanded, symlinks are resolved, missing or
       non-directory paths are dropped, and `/` or the home directory itself are
       rejected because they would void the boundary.
    5. macOS wrapping resolves symlinks (`/tmp` -> `/private/tmp`) before passing
       the workspace, because Seatbelt matches real paths.
    6. Paths containing quotes, parentheses, or spaces are passed verbatim as
       parameters and cannot alter the profile.
    7. A missing sandbox executable or a missing workspace fails closed; it never
       falls back to an unconfined shell.
    8. The private temp dir lives outside the workspace and outside the host's
       shared temp dir root, and is exported as TMPDIR.

  Behavioural checks against the real OS sandbox are tagged `:os_sandbox`.
  """

  use ExUnit.Case, async: false

  alias Handbean.Platform.ProcessSandbox

  @shell %{path: "/bin/bash", args: ["-c"]}

  setup do
    previous_host = Application.get_env(:handbean, :host)
    Application.delete_env(:handbean, :host)

    root =
      Path.join(System.tmp_dir!(), "sbx-test-#{System.unique_integer([:positive])}")
      |> Path.expand()

    workspace_name =
      if match?({:win32, _}, :os.type()), do: "ws (odd path)", else: "ws (it's \"odd\")"

    workspace = Path.join(root, workspace_name)
    File.mkdir_p!(workspace)

    on_exit(fn ->
      File.rm_rf!(root)

      if previous_host,
        do: Application.put_env(:handbean, :host, previous_host),
        else: Application.delete_env(:handbean, :host)
    end)

    %{root: root, workspace: workspace}
  end

  describe "seatbelt_profile/1" do
    test "denies writes by default and re-allows only parameterised roots" do
      profile = ProcessSandbox.seatbelt_profile(2)

      assert profile =~ "(deny file-write*)"
      assert profile =~ ~s|(subpath (param "WORKSPACE"))|
      assert profile =~ ~s|(subpath (param "TMPDIR"))|
      assert profile =~ ~s|(subpath (param "WRITABLE_0"))|
      assert profile =~ ~s|(subpath (param "WRITABLE_1"))|
      refute profile =~ ~s|(param "WRITABLE_2")|
      assert profile =~ ~s|(literal "/dev/null")|
    end

    test "restricts signals to the same sandbox" do
      profile = ProcessSandbox.seatbelt_profile(0)
      assert profile =~ "(deny signal)"
      assert profile =~ "(allow signal (target same-sandbox))"
    end

    test "contains no absolute host paths other than fixed /dev nodes" do
      profile = ProcessSandbox.seatbelt_profile(1)

      paths = Regex.scan(~r{"(/[^"]*)"}, profile) |> Enum.map(&List.last/1)
      assert Enum.all?(paths, &String.starts_with?(&1, "/dev/"))
    end
  end

  describe "seatbelt_args/5" do
    test "passes every path through -D parameters, never inside the profile", %{
      workspace: workspace
    } do
      tmp = Path.join(workspace, "tmp")
      extra = Path.join(workspace, "extra")

      args = ProcessSandbox.seatbelt_args(@shell, "echo hi", workspace, tmp, [extra])

      assert ["-D", "WORKSPACE=" <> ^workspace, "-D", "TMPDIR=" <> ^tmp | rest] = args
      assert ["-D", "WRITABLE_0=" <> ^extra, "-p", profile | command] = rest
      refute profile =~ workspace
      assert command == ["/bin/bash", "-c", "echo hi"]
    end
  end

  describe "writable_paths/1" do
    test "expands, resolves symlinks, and drops missing or non-directory entries", %{
      root: root
    } do
      real = Path.join(root, "real")
      link = Path.join(root, "link")
      file = Path.join(root, "file")
      File.mkdir_p!(real)
      File.write!(file, "x")

      paths =
        case File.ln_s(real, link) do
          :ok ->
            [link, file, Path.join(root, "missing"), real]

          {:error, reason} when reason in [:eperm, :eacces, :enotsup] ->
            [file, Path.join(root, "missing"), real]

          {:error, reason} ->
            flunk("unexpected symlink failure: #{inspect(reason)}")
        end

      resolved_real = Handbean.Security.PathValidator.resolve_symlink(real)

      assert ProcessSandbox.writable_paths(paths) == [resolved_real]
    end

    test "rejects the filesystem root and the home directory itself" do
      assert ProcessSandbox.writable_paths(["/", "~", System.user_home!()]) == []
    end

    test "ignores non-string entries" do
      assert ProcessSandbox.writable_paths([nil, 42, :atom]) == []
    end
  end

  describe "os_enforced?/0" do
    test "is true only on Linux and macOS" do
      expected = match?({:unix, os} when os in [:linux, :darwin], :os.type())
      assert ProcessSandbox.os_enforced?() == expected
    end
  end

  describe "wrap/4 fail-closed" do
    test "a host that declares no isolation cannot request workspace confinement", %{
      workspace: workspace
    } do
      Handbean.Host.put!(%{shell: true, shell_isolation: :none})
      refute ProcessSandbox.os_enforced?()

      assert {:error, reason} =
               ProcessSandbox.wrap(@shell, "echo x", workspace, workspace_path: workspace)

      assert reason =~ "not supported"
    end

    test "missing sandbox executable is an error, not an unconfined shell", %{
      workspace: workspace
    } do
      assert {:error, reason} =
               ProcessSandbox.wrap(@shell, "echo x", workspace,
                 workspace_path: workspace,
                 sandbox_path: Path.join(workspace, "missing-sandbox")
               )

      assert reason =~ "Sandbox executable not found" or
               reason =~ "Workspace-confined bash is not supported"
    end

    test "missing workspace is an error", %{root: root} do
      missing = Path.join(root, "nope")

      assert {:error, reason} =
               ProcessSandbox.wrap(@shell, "echo x", missing, workspace_path: missing)

      assert reason =~ "not a directory"
    end

    test "an outside cwd requires authorization for that exact directory", %{
      root: root,
      workspace: workspace
    } do
      outside = Path.join(root, "outside")
      sibling = Path.join(root, "other")
      File.mkdir_p!(outside)
      File.mkdir_p!(sibling)
      authorized = Handbean.Security.PathValidator.resolve_symlink(outside)

      for opts <- [[], [authorized_cwd: sibling]] do
        assert {:error, reason} =
                 ProcessSandbox.wrap(
                   @shell,
                   "echo x",
                   outside,
                   [workspace_path: workspace] ++ opts
                 )

        assert reason =~ "Path traversal"
      end

      if ProcessSandbox.os_enforced?() do
        # Exercise the invocation builder without launching a backend executable.
        assert {:ok, invocation} =
                 ProcessSandbox.wrap(@shell, "echo x", outside,
                   workspace_path: workspace,
                   authorized_cwd: authorized,
                   sandbox_path: @shell.path
                 )

        assert invocation.pid_namespace? or invocation.process_group?
      end
    end

    @tag :unix_jobs
    test "a canonical cwd authorization cannot follow a replaced directory symlink", %{
      root: root,
      workspace: workspace
    } do
      outside = Path.join(root, "approved")
      replacement = Path.join(root, "replacement")
      File.mkdir_p!(outside)
      File.mkdir_p!(replacement)
      authorized = Handbean.Security.PathValidator.resolve_symlink(outside)
      File.rmdir!(outside)
      File.ln_s!(replacement, outside)

      assert {:error, reason} =
               ProcessSandbox.wrap(@shell, "echo x", outside,
                 workspace_path: workspace,
                 authorized_cwd: authorized
               )

      assert reason =~ "Path traversal"
    end

    test "no workspace means no sandbox and no extra environment" do
      assert {:ok,
              %{
                executable: "/bin/bash",
                env: [],
                pid_namespace?: false,
                process_group?: false
              }} =
               ProcessSandbox.wrap(@shell, "echo x", nil, [])
    end
  end

  if match?({:unix, :darwin}, :os.type()) do
    describe "wrap/4 on macOS" do
      test "resolves symlinked workspace paths and exports a private TMPDIR", %{root: root} do
        workspace = Path.join(root, "ws")
        File.mkdir_p!(workspace)
        via_tmp = String.replace_prefix(workspace, "/private/", "/")

        assert {:ok, invocation} =
                 ProcessSandbox.wrap(@shell, "echo x", via_tmp, workspace_path: via_tmp)

        real = Handbean.Security.PathValidator.resolve_symlink(workspace)
        assert ("WORKSPACE=" <> real) in invocation.args
        assert [{"TMPDIR", tmp}] = invocation.env
        assert ("TMPDIR=" <> tmp) in invocation.args
        assert File.dir?(tmp)
        refute String.starts_with?(tmp, real <> "/")
        refute tmp == Handbean.Security.PathValidator.resolve_symlink(System.tmp_dir!())
        assert invocation.pid_namespace? == false
        assert invocation.process_group? == true
        assert invocation.executable == "/usr/bin/sandbox-exec"
      end
    end
  end

  describe "behaviour under the real OS sandbox" do
    @describetag :os_sandbox

    test "workspace and TMPDIR are writable; siblings and home are not", %{
      root: root,
      workspace: workspace
    } do
      outside = Path.join(root, "outside.txt")

      home_probe =
        Path.join(System.user_home!(), ".handbean-sbx-probe-#{System.unique_integer()}")

      command =
        "printf in > inside.txt; printf t > \"${TMPDIR:-/tmp}/t.txt\" && echo tmp-ok; " <>
          "target=$(printf '%s' '#{outside}'); printf x > \"$target\" 2>/dev/null; " <>
          "home=$(printf '%s' '#{home_probe}'); printf x > \"$home\" 2>/dev/null || echo home-denied"

      assert {:ok, output, %{exit_code: 0}} =
               Handbean.Platform.ProcessRunner.run_bash(command, workspace, 10_000,
                 workspace_path: workspace
               )

      assert File.read!(Path.join(workspace, "inside.txt")) == "in"
      assert output =~ "tmp-ok"
      # Linux absorbs /tmp writes into a private tmpfs, so only persistence is portable.
      assert output =~ "home-denied"
      refute File.exists?(outside)
      refute File.exists?(home_probe)
    end

    test "declared extra writable paths are writable", %{root: root, workspace: workspace} do
      extra = Path.join(root, "cache")
      File.mkdir_p!(extra)
      target = Path.join(extra, "hit")

      assert {:ok, _output, %{exit_code: 0}} =
               Handbean.Platform.ProcessRunner.run_bash(
                 "target=$(printf '%s' '#{target}'); printf ok > \"$target\"",
                 workspace,
                 10_000,
                 workspace_path: workspace,
                 writable_paths: [extra]
               )

      assert File.read!(target) == "ok"
    end

    test "timeout kills sandboxed descendants", %{root: root, workspace: workspace} do
      marker = Path.join(workspace, "late")

      assert {:ok, output, %{timed_out: true}} =
               Handbean.Platform.ProcessRunner.run_bash(
                 "(sleep 2; printf late > late) & sleep 30",
                 workspace,
                 300,
                 workspace_path: workspace
               )

      assert output =~ "timed out"
      # A surviving descendant would create the marker once its sleep ends.
      ref = make_ref()
      Process.send_after(self(), {:checked, ref}, 2_500)
      assert_receive {:checked, ^ref}, 3_000
      refute File.exists?(marker)
      _ = root
    end

    test "timeout kills a descendant reparented before the process-tree snapshot", %{
      workspace: workspace
    } do
      marker = Path.join(workspace, "reparented-late")

      assert {:ok, output, %{timed_out: true}} =
               Handbean.Platform.ProcessRunner.run_bash(
                 "/usr/bin/perl -e '$pid = fork(); die $! unless defined $pid; exit 0 if $pid; " <>
                   "while (getppid() != 1) { select undef, undef, undef, 0.01 }; " <>
                   ~S/$| = 1; print "detached\n"; sleep 2; open my $fh, ">", "reparented-late" or die $!; print $fh "late"' & sleep 30/,
                 workspace,
                 1_000,
                 workspace_path: workspace
               )

      assert output =~ "timed out"
      assert output =~ "detached"
      ref = make_ref()
      Process.send_after(self(), {:checked, ref}, 2_500)
      assert_receive {:checked, ^ref}, 3_000
      refute File.exists?(marker)
    end
  end
end
