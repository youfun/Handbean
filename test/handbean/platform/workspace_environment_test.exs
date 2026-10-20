defmodule Handbean.Platform.WorkspaceEnvironmentTest do
  use ExUnit.Case, async: false

  alias Handbean.Browser.Cli
  alias Handbean.Platform.{ProcessRunner, WorkspaceEnvironment}

  setup do
    old_capture = Application.get_env(:handbean, :workspace_environment_capture)
    WorkspaceEnvironment.clear()

    on_exit(fn ->
      if old_capture,
        do: Application.put_env(:handbean, :workspace_environment_capture, old_capture),
        else: Application.delete_env(:handbean, :workspace_environment_capture)

      WorkspaceEnvironment.clear()
    end)

    :ok
  end

  test "caches a complete workspace environment without mutating the BEAM environment" do
    parent = self()
    original = System.get_env("HANDBEAN_PROJECT_MARKER")

    Application.put_env(:handbean, :workspace_environment_capture, fn path ->
      send(parent, {:captured, path})

      {:ok,
       %{
         "PATH" => "/workspace/shims:/usr/bin",
         "HANDBEAN_PROJECT_MARKER" => "project",
         "ROOTDIR" => "/packaged/release"
       }}
    end)

    assert {:ok, environment} = WorkspaceEnvironment.environment(File.cwd!())

    assert environment == %{
             "PATH" => "/workspace/shims:/usr/bin",
             "HANDBEAN_PROJECT_MARKER" => "project"
           }

    assert {:ok, cached_environment} = WorkspaceEnvironment.environment(File.cwd!())
    assert cached_environment["HANDBEAN_PROJECT_MARKER"] == "project"
    assert_received {:captured, path}
    assert path == Path.expand(File.cwd!())
    refute_received {:captured, _}
    assert System.get_env("HANDBEAN_PROJECT_MARKER") == original
  end

  test "does not cache capture failures and retries on the next request" do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    Application.put_env(:handbean, :workspace_environment_capture, fn _path ->
      Agent.get_and_update(attempts, fn
        0 -> {{:error, {:helper_exit_status, 17}}, 1}
        count -> {{:ok, %{"PATH" => "/workspace/bin"}}, count + 1}
      end)
    end)

    assert WorkspaceEnvironment.environment(File.cwd!()) ==
             {:error, {:workspace_environment_failed, {:helper_exit_status, 17}}}

    assert WorkspaceEnvironment.environment(File.cwd!()) ==
             {:ok, %{"PATH" => "/workspace/bin"}}

    assert WorkspaceEnvironment.environment(File.cwd!()) ==
             {:ok, %{"PATH" => "/workspace/bin"}}

    assert Agent.get(attempts, & &1) == 2
  end

  test "reports a sanitized exception category without exposing its message" do
    Application.put_env(:handbean, :workspace_environment_capture, fn _path ->
      raise "secret helper output /private/path"
    end)

    assert WorkspaceEnvironment.environment(File.cwd!()) ==
             {:error, {:workspace_environment_failed, {:capture_exception, RuntimeError}}}
  end

  test "unsandboxed process keeps the captured workspace environment" do
    workspace = File.cwd!()

    Application.put_env(:handbean, :workspace_environment_capture, fn ^workspace ->
      {:ok,
       %{
         "PATH" => System.get_env("PATH"),
         "HANDBEAN_YOLO_PROJECT_MARKER" => "project-env"
       }}
    end)

    assert {:ok, "project-env", %{exit_code: 0}} =
             ProcessRunner.run_bash(
               "printf %s \"$HANDBEAN_YOLO_PROJECT_MARKER\"",
               workspace,
               5_000,
               workspace_path: workspace,
               sandboxed: false
             )
  end

  test "process startup propagates workspace capture failures" do
    Application.put_env(:handbean, :workspace_environment_capture, fn _path ->
      {:error, {:helper_exit_status, 9}}
    end)

    assert ProcessRunner.open_tracked(
             command: "printf should-not-run",
             cwd: File.cwd!(),
             workspace_path: File.cwd!()
           ) == {:error, {:workspace_environment_failed, {:helper_exit_status, 9}}}
  end

  test "browser CLI does not fall back to the process PATH after capture failure" do
    Application.put_env(:handbean, :workspace_environment_capture, fn _path ->
      {:error, {:helper_exit_status, 23}}
    end)

    assert Cli.run(["--version"], workspace_path: File.cwd!()) ==
             {:error, {:workspace_environment_failed, {:helper_exit_status, 23}}}
  end

  test "removes desktop backend values before invoking the shell environment helper" do
    if match?({:unix, _}, :os.type()) do
      root =
        Path.join(System.tmp_dir!(), "handbean-env-helper-#{System.unique_integer([:positive])}")

      helper = Path.join(root, "capture-env")

      keys =
        ~w(HANDBEAN_DESKTOP_ENV_HELPER PHX_SERVER PORT SECRET_KEY_BASE HANDBEAN_COMPUTER_TOKEN)

      originals = Map.new(keys, &{&1, System.get_env(&1)})

      File.mkdir_p!(root)

      File.write!(
        helper,
        ~S|#!/bin/sh
printf '{"INHERITED_PHX_SERVER":"%s","INHERITED_PORT":"%s","INHERITED_SECRET":"%s","INHERITED_TOKEN":"%s","PORT":"4100"}' "${PHX_SERVER-unset}" "${PORT-unset}" "${SECRET_KEY_BASE-unset}" "${HANDBEAN_COMPUTER_TOKEN-unset}"
|
      )

      File.chmod!(helper, 0o755)
      System.put_env("HANDBEAN_DESKTOP_ENV_HELPER", helper)
      System.put_env("PHX_SERVER", "true")
      System.put_env("PORT", "60302")
      System.put_env("SECRET_KEY_BASE", "desktop-secret")
      System.put_env("HANDBEAN_COMPUTER_TOKEN", "desktop-token")

      try do
        Application.delete_env(:handbean, :workspace_environment_capture)
        WorkspaceEnvironment.clear()

        assert {:ok, environment} = WorkspaceEnvironment.environment(root)

        assert environment == %{
                 "INHERITED_PHX_SERVER" => "unset",
                 "INHERITED_PORT" => "unset",
                 "INHERITED_SECRET" => "unset",
                 "INHERITED_TOKEN" => "unset",
                 "PORT" => "4100"
               }
      after
        Enum.each(originals, fn
          {key, nil} -> System.delete_env(key)
          {key, value} -> System.put_env(key, value)
        end)

        File.rm_rf!(root)
      end
    end
  end

  test "resolves executables from the workspace PATH" do
    root =
      Path.join(System.tmp_dir!(), "handbean-workspace-env-#{System.unique_integer([:positive])}")

    bin = Path.join(root, "bin")
    executable = Path.join(bin, "workspace-tool")
    File.mkdir_p!(bin)
    File.write!(executable, "#!/bin/sh\n")
    File.chmod!(executable, 0o755)
    on_exit(fn -> File.rm_rf!(root) end)

    Application.put_env(:handbean, :workspace_environment_capture, fn ^root ->
      {:ok, %{"PATH" => bin}}
    end)

    assert WorkspaceEnvironment.find_executable("workspace-tool", root) == {:ok, executable}
  end

  test "browser CLI resolves agent-browser from the workspace environment" do
    root =
      Path.join(System.tmp_dir!(), "handbean-browser-env-#{System.unique_integer([:positive])}")

    bin = Path.join(root, "bin")
    executable = Path.join(bin, "agent-browser")
    File.mkdir_p!(bin)

    File.write!(
      executable,
      ~S|#!/bin/sh
printf '%s:%s' "$PROJECT_BROWSER" "$PWD"
|
    )

    File.chmod!(executable, 0o755)
    on_exit(fn -> File.rm_rf!(root) end)

    Application.put_env(:handbean, :workspace_environment_capture, fn ^root ->
      {:ok, %{"PATH" => bin, "PROJECT_BROWSER" => "enabled"}}
    end)

    assert {:ok, %{exit_code: 0, stdout: output}} =
             Cli.run(["--version"], workspace_path: root)

    assert output == "enabled:#{Handbean.Security.PathValidator.resolve_symlink(root)}"
  end

  test "bash inherits the workspace environment and explicit values win" do
    root =
      Path.join(System.tmp_dir!(), "handbean-bash-env-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    Application.put_env(:handbean, :workspace_environment_capture, fn ^root ->
      {:ok,
       %{
         "PATH" => System.get_env("PATH"),
         "PROJECT_ONLY" => "project",
         "PRECEDENCE" => "project"
       }}
    end)

    assert {:ok, "project:explicit", %{exit_code: 0}} =
             ProcessRunner.run_bash(
               ~S|printf '%s:%s' "$PROJECT_ONLY" "$PRECEDENCE"|,
               root,
               5_000,
               workspace_path: root,
               env: [{"PRECEDENCE", "explicit"}]
             )
  end
end
