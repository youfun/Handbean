defmodule Handbean.Workspace do
  @moduledoc """
  Workspace path management.

  Resolves the workspace root directory from configuration, validates that
  file paths stay within the workspace boundary, and translates between
  absolute and relative path representations.

  ## Configuration priority

  1. `HANDBEAN_WORKSPACE` environment variable
  2. `Application.get_env(:handbean, :workspace_root)`
  3. Fallback: `~/.handbean/workspace`
  """

  alias Handbean.Security.PathValidator

  @default_root "~/.handbean/workspace"

  @doc "The fixed default workspace under the host data directory, independent of project overrides."
  @spec default_root() :: String.t()
  def default_root, do: Handbean.Home.expand(@default_root)

  @doc """
  Return the expanded workspace root directory.

  Resolution order:
    1. `HANDBEAN_WORKSPACE` env var
    2. `Application.get_env(:handbean, :workspace_root)`
    3. `~/.handbean/workspace`
  """
  @spec root() :: String.t()
  def root do
    from_env = System.get_env("HANDBEAN_WORKSPACE")
    from_app = Application.get_env(:handbean, :workspace_root)

    cond do
      is_binary(from_env) and from_env != "" -> Handbean.Home.expand(from_env)
      is_binary(from_app) -> Handbean.Home.expand(from_app)
      true -> Handbean.Home.expand(@default_root)
    end
  end

  @doc """
  Return the workspace root, creating the directory if it doesn't exist.
  """
  @spec ensure_root!() :: String.t()
  def ensure_root! do
    dir = root()
    File.mkdir_p!(dir)
    dir
  end

  @doc """
  Resolve a path against the workspace root.

  - Relative paths are expanded against the workspace root.
  - Absolute paths are expanded as-is.
  - The result is validated to ensure it stays within the workspace.

  When `workspace_root` is not provided, defaults to `root()`.

  Returns `{:ok, absolute_path}` or `{:error, reason}`.
  """
  @spec resolve(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def resolve(path, workspace_root \\ root()) do
    resolved =
      if Path.type(path) == :absolute do
        Path.expand(path)
      else
        Path.expand(path, workspace_root)
      end

    case validate_within(resolved, workspace_root) do
      :ok -> {:ok, resolved}
      {:error, _} = error -> error
    end
  end

  @doc """
  Validate that a path is within the workspace root.

  When `workspace_root` is not provided, defaults to `root()`.

  Delegates to `Handbean.Security.PathValidator.validate_within_workspace/2`.
  """
  @spec validate_within(String.t(), String.t()) :: :ok | {:error, String.t()}
  def validate_within(path, workspace_root \\ root()) do
    PathValidator.validate_within_workspace(path, workspace_root)
  end

  @doc """
  Check if a path is within the workspace root.

  When `workspace_root` is not provided, defaults to `root()`.
  """
  @spec within?(String.t(), String.t()) :: boolean()
  def within?(path, workspace_root \\ root()) do
    validate_within(path, workspace_root) == :ok
  end

  @doc """
  Return a relative path for display, stripping the workspace root prefix.

  When `workspace_root` is not provided, defaults to `root()`.

  Returns the path as-is if it's outside the workspace or if calculating
  a relative path fails.
  """
  @spec relative_path(String.t(), String.t()) :: String.t()
  def relative_path(path, workspace_root \\ root()) do
    ws = workspace_root <> "/"

    case String.split(path, ws) do
      [_, relative] -> relative
      _ -> Path.basename(path)
    end
  end
end
