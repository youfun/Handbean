defmodule Handbean.Git.CLI.Detect do
  @moduledoc """
  Resolve and verify the host Git executable.

  A path on disk is not enough. This runs `git --version` with a timeout
  and a noninteractive environment, and distinguishes missing, not
  runnable, and probe-failed cases. On macOS it explains the Command Line
  Tools stub instead of installing anything.
  """

  alias Handbean.Git.CLI.Exec

  @probe_timeout_ms 5_000

  @type probe_ok :: %{executable: String.t(), version: String.t()}

  @spec probe(keyword()) :: {:ok, probe_ok()} | {:error, String.t()}
  def probe(opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, @probe_timeout_ms)

    case resolve_executable(opts) do
      {:ok, executable} -> verify(executable, timeout)
      {:error, _} = error -> error
    end
  end

  @spec resolve_executable(keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def resolve_executable(opts \\ []) do
    configured =
      Keyword.get(opts, :executable) || Application.get_env(:handbean, :git_executable)

    cond do
      is_binary(configured) and String.trim(configured) != "" ->
        check_configured(Path.expand(configured))

      true ->
        case System.find_executable("git") do
          nil -> {:error, missing_message()}
          path -> {:ok, path}
        end
    end
  end

  defp check_configured(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        if executable_file?(path) do
          {:ok, path}
        else
          {:error, "Git executable is not runnable: #{path}"}
        end

      {:ok, %File.Stat{type: type}} ->
        {:error, "Git executable is not runnable: #{path} (#{type})"}

      {:error, :enoent} ->
        case File.lstat(path) do
          {:ok, %File.Stat{type: :symlink}} ->
            {:error, "Git executable is a broken symlink: #{path}"}

          _ ->
            {:error, "Git executable not found: #{path}"}
        end

      {:error, reason} ->
        {:error, "Git executable is not runnable: #{path} (#{inspect(reason)})"}
    end
  end

  defp executable_file?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  defp verify(executable, timeout) do
    result = Exec.run(executable, ["--version"], timeout: timeout, cwd: nil, secrets: [])

    case result do
      {:ok, output, %{timed_out: true}} ->
        {:error, timeout_message(executable, timeout, output)}

      {:ok, output, %{exit_code: 0}} ->
        parse_version(executable, output)

      {:ok, output, %{exit_code: code}} ->
        {:error, failed_message(executable, code, output)}

      {:error, reason} ->
        {:error, "Git --version failed for #{executable}: #{reason}"}
    end
  end

  defp parse_version(executable, output) do
    cond do
      stub_output?(output) ->
        {:error, stub_message(executable, output)}

      true ->
        case Regex.run(~r/git version ([^\s]+)/, output) do
          [_, version] -> {:ok, %{executable: executable, version: version}}
          nil -> {:error, failed_message(executable, 0, output)}
        end
    end
  end

  defp stub_output?(output) do
    down = String.downcase(output)
    String.contains?(down, "xcode-select") or String.contains?(down, "command line tools")
  end

  defp missing_message do
    "Git executable not found on PATH. Install Git and retry, or set :git_executable."
  end

  defp timeout_message(executable, timeout, output) do
    base =
      "Git --version timed out after #{timeout}ms for #{executable}. " <>
        "The binary exists but did not complete a noninteractive probe."

    cond do
      macos?() ->
        base <>
          " On macOS this is often the Command Line Tools stub; run `xcode-select --install`." <>
          suffix(output)

      true ->
        base <> suffix(output)
    end
  end

  defp failed_message(executable, code, output) do
    cond do
      stub_output?(output) ->
        stub_message(executable, output)

      macos?() and String.starts_with?(executable, "/usr/bin/git") ->
        "Git --version failed for #{executable} (exit #{code}). " <>
          "If developer tools are missing, run `xcode-select --install`." <>
          suffix(output)

      true ->
        "Git --version failed for #{executable} (exit #{code})." <> suffix(output)
    end
  end

  defp stub_message(executable, output) do
    "Git at #{executable} is the macOS Command Line Tools stub, not a working Git. " <>
      "Run `xcode-select --install` and retry. Handbean will not install tools." <>
      suffix(output)
  end

  defp suffix(output) do
    trimmed = output |> Exec.redact([]) |> String.trim()

    if trimmed == "" do
      ""
    else
      " Probe output: #{String.slice(trimmed, 0, 400)}"
    end
  end

  defp macos?, do: match?({:unix, :darwin}, :os.type())
end
