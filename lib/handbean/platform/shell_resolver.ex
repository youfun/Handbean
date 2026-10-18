defmodule Handbean.Platform.ShellResolver do
  @moduledoc """
  Resolves the bash shell path with configurable priority chain.

  Priority (highest first):
  1. explicit `:shell_path` option
  2. workspace settings `tools.bash.shellPath`
  3. user settings `tools.bash.shellPath`
  4. Application env `:handbean, :shell_path`
  5. auto-detect (Windows Git Bash paths, PATH bash, fallbacks)
  """

  alias Handbean.Platform

  @type shell_config :: %{
          path: String.t(),
          args: [String.t()],
          source:
            :explicit
            | :workspace
            | :user
            | :app_env
            | :known_path
            | :path
            | :fallback
        }

  @doc """
  Resolves the bash shell, returning a config map or an error with install guidance.
  """
  @spec resolve(keyword()) :: {:ok, shell_config()} | {:error, String.t()}
  def resolve(opts \\ []) do
    with nil <- resolve_explicit(opts),
         nil <- resolve_settings(opts),
         nil <- resolve_app_env(),
         nil <- auto_detect() do
      {:error, no_shell_message()}
    else
      {:ok, config} -> {:ok, config}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Resolution chain ──

  defp resolve_explicit(opts) do
    case Keyword.get(opts, :shell_path) do
      nil -> nil
      path -> validate_path(path, :explicit)
    end
  end

  defp resolve_settings(opts) do
    workspace_path = Keyword.get(opts, :workspace_path)

    # Priority: workspace > user
    resolved = read_shell_path_from_workspace(workspace_path) || read_shell_path_from_user()

    case resolved do
      nil -> nil
      path -> validate_path(path, :workspace)
    end
  end

  defp read_shell_path_from_workspace(nil), do: nil

  defp read_shell_path_from_workspace(workspace_path) do
    with {:ok, settings} <- Handbean.WorkspaceSettings.load(workspace_path) do
      get_in(settings, ["tools", "bash", "shellPath"])
    else
      _ -> nil
    end
  end

  defp read_shell_path_from_user do
    with {:ok, settings} <- Handbean.Settings.load_global() do
      get_in(settings, ["tools", "bash", "shellPath"])
    end
  end

  defp resolve_app_env do
    case Application.get_env(:handbean, :shell_path) do
      nil -> nil
      path -> validate_path(path, :app_env)
    end
  end

  # ── Auto-detect ──

  defp auto_detect do
    if Platform.windows?() do
      windows_auto_detect()
    else
      unix_auto_detect()
    end
  end

  defp windows_auto_detect do
    # Known Git Bash install locations
    known =
      [
        expand_env("%ProgramFiles%\\Git\\bin\\bash.exe"),
        expand_env("%ProgramFiles(x86)%\\Git\\bin\\bash.exe")
      ]
      |> Enum.filter(&File.exists?/1)

    case known do
      [path | _] ->
        validate_path(path, :known_path)

      [] ->
        # Try `where bash.exe`
        case System.cmd("where", ["bash.exe"], stderr_to_stdout: true) do
          {output, 0} ->
            output
            |> String.split("\n", trim: true)
            |> Enum.map(&String.trim/1)
            |> Enum.find_value(fn path -> validate_path(path, :path) end)

          _ ->
            nil
        end
    end
  end

  defp unix_auto_detect do
    # Try PATH first
    case System.find_executable("bash") do
      nil ->
        # Fallbacks
        fallbacks = ["/bin/bash", "/bin/sh"]

        Enum.find_value(fallbacks, fn path ->
          validate_path(path, :fallback)
        end)

      path ->
        validate_path(path, :path)
    end
  end

  # ── Validation ──

  defp validate_path(path, source) do
    expanded = Path.expand(path)

    cond do
      not File.exists?(expanded) ->
        {:error, "Shell not found: #{path} does not exist"}

      File.dir?(expanded) ->
        {:error, "Shell path is a directory: #{path}"}

      true ->
        {:ok, %{path: expanded, args: ["-c"], source: source}}
    end
  end

  # ── Helpers ──

  defp expand_env(template) do
    Regex.replace(~r/%([^%]+)%/, template, fn _, var ->
      System.get_env(var) || "%#{var}%"
    end)
  end

  defp no_shell_message do
    if Platform.windows?() do
      "No bash shell found. Install Git for Windows (https://git-scm.com) " <>
        "or configure shellPath in workspace settings."
    else
      "No bash shell found. Install bash or configure shellPath in settings."
    end
  end
end
