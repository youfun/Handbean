defmodule Handbean.Tool.Builtin.MixProject do
  @moduledoc """
  Agent entry for Mix/Hex project operations on the host BEAM.

  Long work is owned by `Handbean.Workspace.MixOwner`, not LiveView or
  HomeScreen. This is host-privileged, not a sandbox.
  """

  @behaviour Handbean.Agent.Tool

  alias Handbean.Workspace.MixProject, as: Project
  alias Handbean.Workspace.MixToolchain

  @impl true
  def name, do: "mix_project"

  @impl true
  def description do
    """
    Run Mix/Hex operations for a regular Elixir project in the current workspace.

    Actions: deps.get (install host-compatible pure Elixir/Erlang deps through real Mix and Hex), compile, test, run.
    The project must contain mix.exs; typical layout is mix.exs, mix.lock, lib/, test/.
    Set job=true for long work: short wait returns job_id; query job_status until finished before ending the run. MixOwner still serializes execution and restores VM state before completion. No shell is required.
    #{toolchain_status()}

    Supported deps are Mix packages of pure Elixir/Erlang code. NIF/native compilers, Rebar, Make, and other external build tools are rejected with an error. Host application versions and modules are not replaced. Mix changes the whole VM working directory while a project operation runs; operations are serialized, managed descendant processes are cleaned up, and globals are restored afterwards. This is not a security sandbox: project code runs with Handbean app privileges, can still call System.cmd/3, and can hand work to pre-existing or external processes outside the managed lifecycle.

    Script-local Hex deps should use Mix.install from run_elixir_script. Use this tool for a workspace mix.exs project (deps.get, compile, test, run). Do not invent Hex resolution by downloading tarballs yourself.
    """
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        job: %{type: "boolean", default: false},
        wait_ms: %{type: "integer", minimum: 1, default: 1_000},
        action: %{
          type: "string",
          enum: ["deps.get", "compile", "test", "run"],
          description: "Mix operation to run."
        },
        path: %{
          type: "string",
          description:
            "Workspace-relative or absolute project directory containing mix.exs. Defaults to the workspace root."
        },
        module: %{
          type: "string",
          description: "For action=run, Elixir module to call after compile."
        },
        function: %{
          type: "string",
          description: "For action=run, function name to call. Default: run"
        },
        args: %{
          type: "array",
          items: %{},
          description: "For action=run, arguments passed to the function. Default: []"
        },
        offline: %{
          type: "boolean",
          description: "Set HEX_OFFLINE=1. Use after deps are already in the workspace cache.",
          default: false
        },
        timeout_ms: %{
          type: "integer",
          description:
            "Execution limit in milliseconds (default #{Project.default_timeout_ms()}, synchronous max #{Project.max_timeout_ms()}, job max 3600000). Separate from job response wait.",
          default: Project.default_timeout_ms()
        }
      },
      required: ["action"]
    }
  end

  @impl true
  def max_result_chars, do: 105_000

  @impl true
  def concurrent?, do: false

  @impl true
  def execute(%{"action" => action} = input, context) when is_binary(action) do
    workspace =
      Handbean.Utils.SafeMap.get_any(context, :working_directory, "working_directory")

    with {:ok, workspace} <- require_workspace(workspace),
         {:ok, action} <- parse_action(action),
         {:ok, path} <- resolve_project(Map.get(input, "path", "."), workspace),
         {:ok, timeout_ms} <-
           parse_timeout(
             Map.get(input, "timeout_ms", Project.default_timeout_ms()),
             Map.get(input, "job", false)
           ),
         {:ok, opts} <- run_opts(action, input) do
      opts = Keyword.merge(opts, timeout_ms: timeout_ms, offline: truthy?(input["offline"]))

      if input["job"] == true do
        Handbean.Jobs.start_beam(
          :mix,
          fn sink ->
            Project.perform(action, path, Keyword.put(opts, :on_output, sink))
          end,
          timeout_ms,
          Map.get(input, "wait_ms", 1_000),
          context
        )
        |> Handbean.Jobs.format()
      else
        Project.perform(action, path, opts)
      end
    end
  end

  def execute(_input, _context), do: {:error, "action is required"}

  defp toolchain_status do
    case MixToolchain.info() do
      {:ok, info} ->
        "Toolchain: Mix #{presence(info.mix?)}, Hex #{presence(info.hex?)}, ExUnit #{presence(info.ex_unit?)} " <>
          "(#{info.source}, Elixir #{info.elixir}, OTP #{info.otp}" <>
          hex_vsn(info.hex_version) <> ")."

      {:error, reason} ->
        "Toolchain unavailable: #{reason}."
    end
  end

  defp hex_vsn(nil), do: ""
  defp hex_vsn(version), do: ", Hex #{version}"

  defp presence(true), do: "present"
  defp presence(false), do: "absent"

  defp require_workspace(workspace) when is_binary(workspace) and workspace != "",
    do: {:ok, Path.expand(workspace)}

  defp require_workspace(_), do: {:error, "working_directory is required"}

  defp parse_action("deps.get"), do: {:ok, :deps_get}
  defp parse_action("compile"), do: {:ok, :compile}
  defp parse_action("test"), do: {:ok, :test}
  defp parse_action("run"), do: {:ok, :run}
  defp parse_action(other), do: {:error, "unsupported mix_project action: #{other}"}

  defp resolve_project(path, workspace) do
    with {:ok, resolved} <- Handbean.Workspace.resolve(path, workspace),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(resolved) do
      {:ok, resolved}
    else
      {:ok, %File.Stat{type: type}} ->
        {:error, "project path must be a directory, got #{type}"}

      {:error, :enoent} ->
        {:error, "project directory not found: #{path}"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, "cannot stat project: #{inspect(reason)}"}
    end
  end

  defp parse_timeout(ms, job) when is_integer(ms) and ms >= 1 and is_boolean(job) do
    max = if job, do: 3_600_000, else: Project.max_timeout_ms()
    if ms <= max, do: {:ok, ms}, else: parse_timeout(nil, job)
  end

  defp parse_timeout(_, job),
    do:
      {:error,
       "job must be boolean; timeout_ms must be 1..#{if job == true, do: 3_600_000, else: Project.max_timeout_ms()}"}

  defp run_opts(:run, input) do
    {:ok,
     [
       module: input["module"],
       function: Map.get(input, "function", "run"),
       args: Map.get(input, "args", [])
     ]}
  end

  defp run_opts(_action, _input), do: {:ok, []}

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_), do: false
end
