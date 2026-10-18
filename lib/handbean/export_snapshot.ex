defmodule Handbean.ExportSnapshot do
  @moduledoc """
  Workspace-relative path authorization for outbound export snapshots.

  Byte copy and FileProvider/CreateDocument live on the Android owner.
  This module only checks containment, regular files, and the export size cap.
  """

  alias Handbean.Security.PathValidator

  # Separate from the 25 MiB inbound batch cap. Frozen starting value for
  # device budget; Intent adapters must not invent a different number.
  @max_bytes 80 * 1024 * 1024

  def max_bytes, do: @max_bytes

  @spec authorize(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def authorize(workspace_path, relative_path)
      when is_binary(workspace_path) and is_binary(relative_path) do
    if traversal?(relative_path) do
      {:error, :invalid_path}
    else
      abs = Path.expand(Path.join(workspace_path, relative_path))

      with :ok <- PathValidator.validate_within_workspace(abs, workspace_path),
           {:ok, %File.Stat{type: :regular, size: size}} <- File.lstat(abs),
           true <- size <= @max_bytes,
           :ok <- PathValidator.validate_readable(abs) do
        {:ok,
         %{
           path: abs,
           relative_path: relative_path,
           display_name: Path.basename(abs),
           size_bytes: size
         }}
      else
        false -> {:error, :too_large}
        {:ok, %File.Stat{type: type}} -> {:error, {:not_regular, type}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def authorize(_, _), do: {:error, :invalid_path}

  # Same component rule as WorkspaceFiles.relative_names/1: only a literal
  # ".." path component is traversal; "foo..bar.txt" is a plain file name.
  defp traversal?(relative_path) do
    String.contains?(relative_path, <<0>>) or
      Path.type(relative_path) == :absolute or
      ".." in Path.split(relative_path)
  end

  @spec fingerprint(String.t()) :: {:ok, map()} | {:error, term()}
  def fingerprint(path) when is_binary(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mtime: mtime, size: size, type: :regular}} ->
        {:ok, %{mtime: mtime, size: size}}

      {:ok, %File.Stat{type: type}} ->
        {:error, {:not_regular, type}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
