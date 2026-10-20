defmodule Handbean.Tool.Builtin.RunElixirScript do
  @moduledoc """
  Evaluate a workspace `.exs` file on the host BEAM.

  High privilege: the script runs in this VM with no sandbox. Bindings
  `args` and `workspace` are injected; the tool does not set `System.argv`
  or change the global cwd.
  """

  @behaviour Handbean.Agent.Tool

  alias Handbean.Tool.Builtin.ElixirScriptIO

  @max_source_bytes 256_000
  @max_stdout_bytes 32_768
  @max_value_bytes 8_192
  @default_timeout_ms 30_000
  @max_timeout_ms 60_000

  @impl true
  def name, do: "run_elixir_script"

  @impl true
  def description do
    "Run a workspace .exs file on the installed OTP/Elixir VM.\n\n" <>
      "Set job=true for long work without a Mix project. Wait briefly, then query job_status " <>
      "until finished before ending the run. No shell or restart recovery. Host-privileged, not a sandbox.\n\n" <>
      Handbean.Tool.ScriptEnvironment.describe()
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        job: %{type: "boolean", default: false},
        wait_ms: %{type: "integer", minimum: 1, default: 1_000},
        path: %{
          type: "string",
          description:
            "Workspace-relative or absolute path to a regular .exs file inside the current workspace."
        },
        args: %{
          type: "array",
          items: %{type: "string"},
          description:
            "Optional string list bound as `args` in the script. Not assigned to System.argv."
        },
        timeout_ms: %{
          type: "integer",
          description:
            "Execution limit: default 30000ms, synchronous max 60000ms; job mode max 3600000ms. Job wait is separate.",
          default: @default_timeout_ms
        }
      },
      required: ["path"]
    }
  end

  @impl true
  def max_result_chars, do: 105_000

  @impl true
  def concurrent?, do: false

  @impl true
  def timeout_ms(%{"job" => true}), do: nil

  def timeout_ms(input) when is_map(input) do
    case parse_timeout(Map.get(input, "timeout_ms", @default_timeout_ms), false) do
      {:ok, timeout} -> timeout
      {:error, _} -> nil
    end
  end

  def timeout_ms(_input), do: nil

  @impl true
  def execute(%{"path" => path} = input, context) when is_binary(path) do
    workspace =
      Handbean.Utils.SafeMap.get_any(context, :working_directory, "working_directory")

    with {:ok, workspace} <- require_workspace(workspace),
         {:ok, args} <- parse_args(Map.get(input, "args", [])),
         {:ok, timeout_ms} <-
           parse_timeout(
             Map.get(input, "timeout_ms", @default_timeout_ms),
             Map.get(input, "job", false)
           ),
         {:ok, resolved} <- resolve_script(path, workspace),
         {:ok, source} <- read_source(resolved) do
      if input["job"] == true do
        Handbean.Jobs.start_beam(
          :script,
          fn sink ->
            capture = ElixirScriptIO.start_link(@max_stdout_bytes, sink)
            Process.group_leader(self(), capture)
            result = eval_source(source, [args: args, workspace: workspace], resolved)
            format_result(resolved, result, ElixirScriptIO.snapshot(capture))
          end,
          timeout_ms,
          Map.get(input, "wait_ms", 1_000),
          context
        )
        |> Handbean.Jobs.format()
      else
        run_script(resolved, source, args, workspace, timeout_ms)
      end
    end
  end

  def execute(_input, _context) do
    {:error, "path is required"}
  end

  defp require_workspace(workspace) when is_binary(workspace) and workspace != "",
    do: {:ok, Path.expand(workspace)}

  defp require_workspace(_), do: {:error, "working_directory is required"}

  defp parse_args(args) when is_list(args) do
    if Enum.all?(args, &is_binary/1) do
      {:ok, args}
    else
      {:error, "args must be a list of strings"}
    end
  end

  defp parse_args(_), do: {:error, "args must be a list of strings"}

  defp parse_timeout(ms, true) when is_integer(ms) and ms in 1..3_600_000, do: {:ok, ms}

  defp parse_timeout(ms, false) when is_integer(ms) and ms >= 1 and ms <= @max_timeout_ms,
    do: {:ok, ms}

  defp parse_timeout(_, job),
    do:
      {:error,
       "job must be boolean; timeout_ms must be 1..#{if job == true, do: 3_600_000, else: @max_timeout_ms}"}

  defp resolve_script(path, workspace) do
    with {:ok, resolved} <- Handbean.Workspace.resolve(path, workspace),
         :ok <- require_exs(resolved),
         {:ok, %File.Stat{type: :regular}} <- File.lstat(resolved) do
      {:ok, resolved}
    else
      {:ok, %File.Stat{type: type}} ->
        {:error, "script must be a regular .exs file, got #{type}"}

      {:error, :enoent} ->
        {:error, "script not found: #{path}"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, "cannot stat script: #{inspect(reason)}"}
    end
  end

  defp require_exs(path) do
    if String.ends_with?(path, ".exs") do
      :ok
    else
      {:error, "script path must end with .exs"}
    end
  end

  defp read_source(path) do
    case File.open(path, [:read, :raw]) do
      {:ok, io} ->
        try do
          bin = IO.binread(io, @max_source_bytes + 1)

          cond do
            bin == :eof ->
              {:ok, ""}

            not is_binary(bin) ->
              {:error, "script is unreadable"}

            byte_size(bin) > @max_source_bytes ->
              {:error, "script exceeds #{@max_source_bytes} bytes"}

            true ->
              {:ok, bin}
          end
        after
          File.close(io)
        end

      {:error, reason} ->
        {:error, "cannot read script: #{inspect(reason)}"}
    end
  end

  defp run_script(path, source, args, workspace, timeout_ms) do
    bindings = [args: args, workspace: workspace]
    caller = self()

    task =
      Task.Supervisor.async_nolink(Handbean.AgentRunTaskSupervisor, fn ->
        worker = self()
        capture = ElixirScriptIO.start_link(@max_stdout_bytes)
        Process.group_leader(worker, capture)

        watcher =
          spawn_link(fn ->
            ref = Process.monitor(caller)

            receive do
              {:DOWN, ^ref, :process, ^caller, _} ->
                Process.exit(worker, :kill)

              :stop ->
                :ok
            end
          end)

        watcher_ref = Process.monitor(watcher)

        try do
          result = eval_source(source, bindings, path)
          stdout = ElixirScriptIO.snapshot(capture)
          format_result(path, result, stdout)
        after
          ElixirScriptIO.stop(capture)
          send(watcher, :stop)

          receive do
            {:DOWN, ^watcher_ref, :process, ^watcher, _} -> :ok
          end
        end
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, text, details}} ->
        {:ok, text, details}

      {:ok, {:error, text, details}} ->
        {:error, text, details}

      {:exit, reason} ->
        {:error, "script worker exited: #{inspect(reason)}",
         %{path: path, stdout: "", stdout_truncated?: false}}

      nil ->
        {:error, "script timed out after #{timeout_ms}ms",
         %{path: path, timed_out: true, stdout: "", stdout_truncated?: false}}
    end
  end

  defp eval_source(source, bindings, path) do
    try do
      {value, _binding} = Code.eval_string(source, bindings, file: path)
      {:ok, value}
    rescue
      exception ->
        {:raised, Exception.format(:error, exception, __STACKTRACE__)}
    catch
      kind, reason ->
        {:caught, kind, Exception.format(kind, reason, __STACKTRACE__)}
    end
  end

  defp format_result(path, {:ok, value}, stdout) do
    {inspected, value_truncated?} = bound_inspect(value)

    text =
      format_output(stdout.text, inspected, stdout.truncated?, value_truncated?)

    {:ok, text,
     %{
       path: path,
       stdout: stdout.text,
       stdout_truncated?: stdout.truncated?,
       return: inspected,
       return_truncated?: value_truncated?
     }}
  end

  defp format_result(path, {:raised, formatted}, stdout) do
    {error, truncated?} = bound_text(formatted)

    {:error, error,
     %{
       path: path,
       stdout: stdout.text,
       stdout_truncated?: stdout.truncated?,
       error_truncated?: truncated?
     }}
  end

  defp format_result(path, {:caught, kind, formatted}, stdout) do
    {error, truncated?} = bound_text("#{kind}: #{formatted}")

    {:error, error,
     %{
       path: path,
       stdout: stdout.text,
       stdout_truncated?: stdout.truncated?,
       error_truncated?: truncated?
     }}
  end

  defp format_output(stdout, inspected, stdout_truncated?, value_truncated?) do
    parts = [
      "stdout:",
      stdout,
      "",
      "return:",
      inspected
    ]

    notes =
      Enum.reject(
        [
          stdout_truncated? && "stdout truncated",
          value_truncated? && "return truncated"
        ],
        &(!&1)
      )

    body = Enum.join(parts, "\n")

    if notes == [] do
      body
    else
      body <> "\n\n(" <> Enum.join(notes, "; ") <> ")"
    end
  end

  defp bound_inspect(value) do
    inspected = inspect(value, limit: 50, printable_limit: 2_048)
    bound_text(inspected)
  end

  defp bound_text(text) when is_binary(text) do
    ElixirScriptIO.take_utf8(text, @max_value_bytes)
  end
end
