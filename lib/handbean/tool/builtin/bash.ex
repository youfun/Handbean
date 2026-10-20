defmodule Handbean.Tool.Builtin.Bash do
  @moduledoc """
  Execute shell commands with timeout control and process tree killing.

  Uses Port-based execution with scroll buffer, output truncation (tail strategy),
  and process group killing on timeout.

  Before a process starts, a best-effort precheck rejects commands that name
  sensitive credential paths. The OS sandbox leaves the host filesystem readable,
  so this precheck closes that hole. It is not a shell policy engine: quotes,
  variable expansion, globs, and encoded payloads are not fully solved.
  `unsandboxed=true` does not skip the precheck and does not grant those reads.
  """

  @behaviour Handbean.Agent.Tool

  @max_output_bytes 50_000

  @impl true
  def name, do: "bash"

  @impl true
  def description do
    "Execute a bash command in the current working directory. " <>
      "Returns stdout and stderr. Use Unix-style commands and forward-slash paths " <>
      "(ls, cat, grep, find, rm, ./scripts/test.sh) even on Windows — " <>
      "this tool always runs in a bash environment. " <>
      "Supports timeout control and working directory override. " <>
      sandbox_description() <>
      "Commands that name sensitive credential paths are " <>
      "rejected before execution; unsandboxed=true does not bypass that, and the " <>
      "precheck is not a complete shell parser. " <>
      job_description() <>
      "if it is still running, pass the returned cursor to job_status. Do not launch another Bash " <>
      "sleep command just to wait for it. Query job_status until finished before ending this run: " <>
      "run completion cancels unfinished jobs. Not a detached dev server; descendants that escape " <>
      "the process group are not contained."
  end

  @impl true
  def hint do
    if Handbean.Platform.ProcessSandbox.os_enforced?() do
      "Read the command's stderr before retrying. Change the command, or its timeout and " <>
        "working_directory, from that error. Retry with unsandboxed=true only after a sandbox " <>
        "write denial; that asks the user for approval and does not bypass credential-path checks."
    else
      "This platform has no OS sandbox. Do not retry the same command; that is not a write denial. " <>
        "Bash already uses the unsandboxed approval gate here (yolo auto-approves). " <>
        "job=true is not available. Credential-path checks still apply."
    end
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        command: %{
          type: "string",
          description:
            "Bash command to execute. Use Unix-style commands with forward-slash paths " <>
              "(e.g. ls, cat, grep, find). Do not prefix with cd — this tool sets the " <>
              "working directory automatically."
        },
        timeout: %{type: "integer", description: "Timeout in seconds", default: 120},
        job: %{type: "boolean", default: false, description: "Explicit run-scoped job mode"},
        wait_ms: %{
          type: "integer",
          minimum: 1,
          maximum: 5_000,
          default: 1_000,
          description:
            "Job response wait, capped at 5000ms and half the tool timeout. Must be positive for launch."
        },
        cwd: %{
          type: "string",
          description:
            "Optional working directory override. Use a subdirectory inside the current workspace, " <>
              "or an external directory in yolo mode."
        },
        unsandboxed: %{
          type: "boolean",
          default: false,
          description:
            if Handbean.Platform.ProcessSandbox.os_enforced?() and Handbean.Host.shell_jobs?() do
              "Run outside the OS sandbox. Use only after the sandbox denied a needed write; " <>
                "requires approval unless the run is in yolo mode. Does not permit sensitive credential paths. " <>
                "Not available for job=true."
            else
              "This platform has no OS sandbox; bash already uses the unsandboxed approval gate. " <>
                "You can omit this flag. Requires approval unless the run is in yolo mode. " <>
                "Does not permit sensitive credential paths. Not available for job=true."
            end
        }
      },
      required: ["command"]
    }
  end

  @impl true
  def max_result_chars, do: @max_output_bytes + 5_000

  @impl true
  def concurrent?, do: false

  @impl true
  def execute(%{"command" => command} = input, context) do
    timeout_sec = Map.get(input, "timeout", 120)
    working_directory = context[:working_directory]

    with :ok <- validate_command(command),
         :ok <- preflight_cwd(Map.get(input, "cwd"), working_directory),
         {:ok, cwd} <- resolve_cwd(Map.get(input, "cwd"), working_directory, context),
         :ok <- preflight_sensitive(command, cwd) do
      external_cwd? = outside_workspace?(cwd, working_directory)

      unsandboxed? =
        Map.get(input, "unsandboxed") == true or
          (Handbean.Agent.Tool.outside_workspace_allowed?(context) and external_cwd?) or
          not Handbean.Platform.ProcessSandbox.os_enforced?()

      cond do
        Map.get(input, "job", false) == true and not Handbean.Host.shell_jobs?() ->
          {:error, "job=true is not available on this host"}

        unsandboxed? and Map.get(input, "job", false) == true ->
          {:error, "unsandboxed is not available for job=true"}

        unsandboxed? or not managed_context?(context) ->
          execute_command(command, timeout_sec, cwd, context, unsandboxed?)

        Map.get(input, "job", false) == false and is_integer(timeout_sec) and
            timeout_sec in 1..3_600 ->
          managed_command(command, timeout_sec, cwd, input, context)

        Map.get(input, "job", false) == false ->
          execute_command(command, timeout_sec, cwd, context, unsandboxed?)

        is_integer(timeout_sec) and timeout_sec in 1..3_600 ->
          Handbean.Jobs.start(
            command,
            cwd,
            timeout_sec * 1_000,
            Map.get(input, "wait_ms", 1_000),
            context
          )
          |> Handbean.Jobs.format()

        Map.get(input, "job", false) == true ->
          {:error, "Job timeout must be an integer from 1 to 3600 seconds"}

        true ->
          {:error, "job must be a boolean"}
      end
    end
  end

  def execute(_input, _context) do
    {:error, "command is required"}
  end

  # ── Validation ──

  defp validate_command(cmd) when not is_binary(cmd) or byte_size(cmd) == 0 do
    {:error, "command must be a non-empty string"}
  end

  defp validate_command(_), do: :ok

  @doc false
  @spec preflight_sensitive(String.t(), String.t() | nil) :: :ok | {:error, String.t()}
  def preflight_sensitive(command, cwd \\ nil) do
    Handbean.Security.PathValidator.reject_sensitive_command(command, cwd)
  end

  defp preflight_cwd(nil, _working_directory), do: :ok

  defp preflight_cwd(path, working_directory) when is_binary(path) do
    base = working_directory || File.cwd!()
    Handbean.Security.PathValidator.reject_sensitive_command(path, base)
  end

  defp preflight_cwd(_path, _working_directory), do: :ok

  defp resolve_cwd(nil, working_directory, _context), do: {:ok, working_directory}

  defp resolve_cwd(path, working_directory, context) do
    cwd =
      if Path.type(path) == :absolute do
        Path.expand(path)
      else
        wd = working_directory || File.cwd!()
        Path.expand(Path.join(wd, path))
      end

    # Validate cwd stays within workspace boundary (resolving symlinks)
    case working_directory do
      nil ->
        {:ok, cwd}

      wd ->
        resolved_cwd = Handbean.Security.PathValidator.resolve_symlink(cwd)
        resolved_wd = Handbean.Security.PathValidator.resolve_symlink(Path.expand(wd))

        if Handbean.Agent.Tool.outside_workspace_allowed?(context) or
             String.starts_with?(resolved_cwd, resolved_wd <> "/") or resolved_cwd == resolved_wd do
          if cwd == "/" or File.dir?(cwd) do
            {:ok, cwd}
          else
            {:error, "cwd #{path} is not a directory"}
          end
        else
          {:error, "Path traversal blocked: cwd #{path} is outside workspace #{wd}"}
        end
    end
  end

  defp outside_workspace?(_cwd, working_directory)
       when not is_binary(working_directory) or working_directory == "",
       do: false

  defp outside_workspace?(cwd, working_directory) when is_binary(cwd) do
    Handbean.Security.PathValidator.validate_within_workspace(cwd, working_directory) != :ok
  end

  defp outside_workspace?(_cwd, _working_directory), do: false

  # ── Execution ──

  # Soft wait decides only how long this call blocks. The command starts once;
  # a still-running result is the same job and must be polled, not relaunched.
  defp managed_context?(context) do
    is_binary(context[:conversation_id]) and context[:conversation_id] != "" and
      is_binary(context[:run_id]) and context[:run_id] != "" and
      is_binary(context[:working_directory]) and context[:working_directory] != "" and
      is_binary(context[:tool_call_id]) and context[:tool_call_id] != ""
  end

  defp managed_command(command, timeout_sec, cwd, input, context) do
    wait_ms = Map.get(input, "wait_ms", 1_000)

    result =
      command
      |> Handbean.Jobs.start(cwd, timeout_sec * 1_000, wait_ms, context)
      |> Handbean.Jobs.format()

    case result do
      {:ok, text, meta} ->
        {:ok, text, Map.merge(meta || %{}, %{side_effect: :unknown, recovery: :poll})}

      {:error, reason} when is_binary(reason) ->
        if String.contains?(reason, "requires trusted") or String.contains?(reason, "unavailable") or
             String.contains?(reason, "not open") do
          execute_command(command, timeout_sec, cwd, context, false)
        else
          {:error, reason}
        end

      other ->
        other
    end
  end

  defp execute_command(command, timeout_sec, cwd, context, unsandboxed?) do
    working_directory = context[:working_directory]
    capture = Handbean.WorkspaceChangeCapture.start(working_directory)
    timeout_ms = timeout_sec * 1000
    sandboxed? = working_directory != nil and not unsandboxed?
    opts = if sandboxed?, do: [workspace_path: working_directory], else: []

    opts =
      if is_pid(Process.get(:tool_owner)),
        do: Keyword.put(opts, :owner, Process.get(:tool_owner)),
        else: opts

    result = Handbean.Platform.ProcessRunner.run_bash(command, cwd, timeout_ms, opts)
    changes = Handbean.WorkspaceChangeCapture.finish(capture, context)
    :ok = Handbean.WorkspaceChangeCapture.persist(changes, context)

    case result do
      {:ok, output, %{exit_code: code} = meta} when sandboxed? and code != 0 ->
        {:ok, output <> sandbox_hint(output), put_changes(meta, changes)}

      {:ok, output, meta} ->
        {:ok, output, put_changes(meta, changes)}

      {:error, reason} when changes != [] ->
        {:error, reason, %{changes: changes, side_effect: :unknown}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp put_changes(meta, []), do: meta
  defp put_changes(meta, changes), do: Map.put(meta, :changes, changes)

  defp sandbox_description do
    if Handbean.Platform.ProcessSandbox.os_enforced?() do
      "Runs inside an OS sandbox (Linux Bubblewrap, macOS Seatbelt): the host filesystem " <>
        "is readable, writes are allowed only in the workspace and $TMPDIR, network is not " <>
        "restricted. Writes elsewhere fail with 'Operation not permitted' or 'Read-only file " <>
        "system'. Only after such a sandbox denial, retry with unsandboxed=true; that asks " <>
        "for approval unless the run is in yolo mode. "
    else
      "This platform has no OS sandbox. Bash is not workspace-confined; every command uses " <>
        "the unsandboxed approval gate (yolo auto-approves). Do not retry after a sandbox " <>
        "write denial — there is none. You can omit unsandboxed=true. "
    end
  end

  defp job_description do
    if Handbean.Host.shell_jobs?() do
      "Set job=true for a run-scoped job (Linux and macOS). The launch wait is capped at 5s; "
    else
      "job=true is not available on this host. The launch wait is capped at 5s; "
    end
  end

  defp sandbox_hint(output) do
    if output =~ "Operation not permitted" or output =~ "Read-only file system" do
      "\n\n[sandbox] A write outside the workspace and $TMPDIR may have been blocked. " <>
        "If that write is required, retry with unsandboxed=true (requires user approval)."
    else
      ""
    end
  end
end
