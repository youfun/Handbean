defmodule Handbean.Platform.ProcessSandbox do
  @moduledoc """
  Builds an OS-enforced command boundary for workspace-scoped processes.

  Both backends keep the host filesystem readable and allow writes only to the
  workspace, a private temp area, and explicitly configured extra directories
  (`config :handbean, :sandbox_writable_paths` or the `:writable_paths` option).
  Network access is not restricted by either backend.

  * Linux uses Bubblewrap with a read-only host filesystem, private PID/IPC/UTS
    namespaces, and a tmpfs over `/tmp` and `/var/tmp`.
  * macOS uses Seatbelt (`sandbox-exec`). There are no namespaces: the private
    temp area is a per-workspace directory exported as `TMPDIR`, host `/tmp`
    stays read-only, and signals may only target processes in the same sandbox.
  """

  alias Handbean.Security.PathValidator

  @seatbelt_executable "/usr/bin/sandbox-exec"

  @type command :: %{
          executable: Path.t(),
          args: [String.t()],
          cwd: Path.t() | nil,
          env: [{String.t(), String.t() | false}],
          pid_namespace?: boolean(),
          process_group?: boolean()
        }

  @doc """
  True when the host requires the platform workspace sandbox and this OS has a
  supported backend. This describes policy, not whether the backend executable is
  currently installed; wrapping still validates that and fails closed.

  Native Windows has no such backend. Callers retain `workspace_path` for
  project environment resolution and select `sandboxed: false`; the bash tool
  routes that execution through the unsandboxed approval gate.
  """
  @spec os_enforced?() :: boolean()
  def os_enforced? do
    Handbean.Host.shell_isolation() == :platform_required and
      match?({:unix, os} when os in [:linux, :darwin], :os.type())
  end

  @doc """
  Wraps a command, applying the workspace write boundary unless `:sandboxed`
  is explicitly false. `:workspace_path` still identifies the project whose
  shell configuration and captured environment the caller loaded; it is not
  itself the decision to isolate the process.

  `:authorized_cwd` is a canonical directory already authorized by the caller for
  this invocation. It permits only that exact cwd; the frozen value is compared
  with the current resolved path and never grants writes or disables isolation.
  """
  @spec wrap(map(), String.t(), Path.t() | nil, keyword()) ::
          {:ok, command()} | {:error, String.t()}
  def wrap(shell, command, cwd, opts) do
    env = Keyword.get(opts, :env, [])

    case {Keyword.get(opts, :workspace_path), Keyword.get(opts, :sandboxed, true)} do
      {_, false} ->
        unconfined(shell, command, cwd, env)

      {nil, true} ->
        unconfined(shell, command, cwd, env)

      {workspace, true} ->
        wrap_workspace(shell, command, cwd || workspace, workspace, opts)

      {_workspace, _invalid} ->
        {:error, "sandboxed must be a boolean"}
    end
  end

  defp unconfined(shell, command, cwd, env) do
    {:ok,
     %{
       executable: shell.path,
       args: shell.args ++ [command],
       cwd: cwd,
       env: env,
       pid_namespace?: false,
       process_group?: false
     }}
  end

  @doc """
  Normalizes extra writable directories: expands `~`, resolves symlinks, keeps
  existing directories only, and rejects `/` and the home directory itself.
  """
  @spec writable_paths([term()]) :: [Path.t()]
  def writable_paths(paths) when is_list(paths) do
    home = PathValidator.resolve_symlink(System.user_home!())

    paths
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&PathValidator.resolve_symlink(Path.expand(&1)))
    |> Enum.filter(&File.dir?/1)
    |> Enum.reject(&(&1 == home or filesystem_root?(&1)))
    |> Enum.uniq()
  end

  defp filesystem_root?(path), do: Path.dirname(path) == path

  @doc """
  Seatbelt profile for `writable_count` extra directories. Paths are never
  interpolated; they arrive as `-D` parameters so they cannot alter the policy.
  """
  @spec seatbelt_profile(non_neg_integer()) :: String.t()
  def seatbelt_profile(writable_count) when is_integer(writable_count) and writable_count >= 0 do
    extra =
      if writable_count == 0,
        do: "",
        else:
          Enum.map_join(0..(writable_count - 1), "\n", &~s|  (subpath (param "WRITABLE_#{&1}"))|)

    """
    (version 1)
    (allow default)
    (deny signal)
    (allow signal (target same-sandbox))
    (deny file-write*)
    (allow file-write*
      (subpath (param "WORKSPACE"))
      (subpath (param "TMPDIR"))
    #{extra}
      (literal "/dev/null")
      (literal "/dev/zero")
      (literal "/dev/tty")
      (literal "/dev/dtracehelper")
      (regex #"^/dev/fd/[0-9]+$")
      (regex #"^/dev/ttys[0-9]+$"))
    """
  end

  @spec seatbelt_args(map(), String.t(), Path.t(), Path.t(), [Path.t()]) :: [String.t()]
  def seatbelt_args(shell, command, workspace, tmp_dir, writable) do
    params =
      writable
      |> Enum.with_index()
      |> Enum.flat_map(fn {path, index} -> ["-D", "WRITABLE_#{index}=#{path}"] end)

    ["-D", "WORKSPACE=#{workspace}", "-D", "TMPDIR=#{tmp_dir}"] ++
      params ++
      ["-p", seatbelt_profile(length(writable)), shell.path | shell.args ++ [command]]
  end

  defp wrap_workspace(shell, command, cwd, workspace, opts) do
    workspace = PathValidator.resolve_symlink(Path.expand(workspace))
    cwd = PathValidator.resolve_symlink(Path.expand(cwd))

    with :ok <- validate_directory(workspace, "workspace"),
         :ok <- validate_directory(cwd, "cwd"),
         :ok <- validate_cwd(cwd, workspace, Keyword.get(opts, :authorized_cwd)) do
      writable =
        writable_paths(
          Application.get_env(:handbean, :sandbox_writable_paths, []) ++
            Keyword.get(opts, :writable_paths, [])
        )

      case {Handbean.Host.shell_isolation(), :os.type()} do
        {:platform_required, {:unix, :linux}} ->
          wrap_linux(shell, command, cwd, workspace, writable, opts)

        {:platform_required, {:unix, :darwin}} ->
          wrap_darwin(shell, command, cwd, workspace, writable, opts)

        _ ->
          {:error, unsupported()}
      end
    end
  end

  defp validate_cwd(cwd, _workspace, cwd), do: PathValidator.reject_resolved(cwd)

  defp validate_cwd(cwd, workspace, _authorized_cwd),
    do: PathValidator.validate_within_workspace(cwd, workspace)

  defp wrap_linux(shell, command, cwd, workspace, writable, opts) do
    case Keyword.get(opts, :sandbox_path) || System.find_executable("bwrap") do
      nil ->
        {:error,
         "Workspace-confined bash requires Bubblewrap (bwrap); refusing to run without an OS sandbox"}

      path ->
        with {:ok, sandbox} <- validate_executable(path) do
          {:ok,
           %{
             executable: sandbox,
             args: bwrap_args(shell, command, cwd, workspace, writable),
             cwd: nil,
             env: Keyword.get(opts, :env, []),
             pid_namespace?: true,
             process_group?: false
           }}
        end
    end
  end

  defp wrap_darwin(shell, command, cwd, workspace, writable, opts) do
    with {:ok, sandbox} <-
           validate_executable(Keyword.get(opts, :sandbox_path, @seatbelt_executable)),
         {:ok, tmp_dir} <- private_tmp_dir(workspace) do
      {:ok,
       %{
         executable: sandbox,
         args: seatbelt_args(shell, command, workspace, tmp_dir, writable),
         cwd: cwd,
         env: merge_env(Keyword.get(opts, :env, []), [{"TMPDIR", tmp_dir}]),
         pid_namespace?: false,
         process_group?: true
       }}
    end
  end

  # One directory per workspace, so no per-run lifecycle is needed; it sits
  # below the host temp root, never at it, so siblings there stay read-only.
  defp private_tmp_dir(workspace) do
    hash = :crypto.hash(:sha256, workspace) |> Base.url_encode64(padding: false)
    dir = Path.join([System.tmp_dir!(), "handbean-sandbox", binary_part(hash, 0, 16)])

    case File.mkdir_p(dir) do
      :ok ->
        File.chmod(dir, 0o700)
        {:ok, PathValidator.resolve_symlink(dir)}

      {:error, reason} ->
        {:error, "Cannot create sandbox temp dir: #{inspect(reason)}"}
    end
  end

  defp merge_env(base, overrides) do
    base
    |> Map.new()
    |> Map.merge(Map.new(overrides))
    |> Map.to_list()
  end

  defp unsupported,
    do:
      "Workspace-confined bash is not supported on this platform; refusing to run without an OS sandbox. " <>
        "On this host, bash runs only through the unsandboxed approval gate (yolo auto-approves). " <>
        "job=true is not available."

  defp validate_executable(path) do
    expanded = Path.expand(path)

    if File.regular?(expanded) do
      {:ok, expanded}
    else
      {:error, "Sandbox executable not found: #{path}"}
    end
  end

  defp validate_directory(path, label) do
    if File.dir?(path), do: :ok, else: {:error, "#{label} #{path} is not a directory"}
  end

  defp bwrap_args(shell, command, cwd, workspace, writable) do
    [
      "--die-with-parent",
      "--new-session",
      "--unshare-pid",
      "--unshare-ipc",
      "--unshare-uts",
      "--ro-bind",
      "/",
      "/",
      "--dev",
      "/dev",
      "--proc",
      "/proc",
      "--tmpfs",
      "/tmp",
      "--tmpfs",
      "/var/tmp"
    ] ++
      external_tmp_cwd_mount(cwd, workspace) ++
      ["--bind", workspace, workspace] ++
      Enum.flat_map(writable, &["--bind", &1, &1]) ++
      [
        "--chdir",
        cwd,
        shell.path
        | shell.args ++ [command]
      ]
  end

  # Bubblewrap's private temp mounts hide host paths. Restore only an approved
  # external cwd there, read-only, before restoring the workspace write mount.
  defp external_tmp_cwd_mount(cwd, workspace) do
    hidden? = Enum.any?(["/tmp", "/var/tmp"], &(cwd == &1 or String.starts_with?(cwd, &1 <> "/")))

    if hidden? and PathValidator.validate_within_workspace(cwd, workspace) != :ok,
      do: ["--ro-bind", cwd, cwd],
      else: []
  end
end
