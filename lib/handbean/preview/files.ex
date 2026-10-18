defmodule Handbean.Preview.Files do
  @moduledoc """
  Serve only files inside a registered preview root.

  Rejects path traversal and symlink escape. Direct file responses carry
  CSP sandbox so skipping PreviewShell still cannot inherit workbench origin.
  """

  @csp "sandbox allow-scripts"

  @spec resolve(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def resolve(root, rel) when is_binary(root) and is_binary(rel) do
    root = Path.expand(root)
    rel = normalize_rel(rel)
    candidate = Path.expand(Path.join(root, rel))

    with {:ok, real_root} <- real_path(root) do
      resolve_existing(real_root, candidate)
    end
  end

  def resolve(_root, _rel), do: {:error, :invalid_path}

  @spec content_type(String.t()) :: String.t()
  def content_type(path) do
    case Path.extname(path) do
      ".html" -> "text/html; charset=utf-8"
      ".htm" -> "text/html; charset=utf-8"
      ".css" -> "text/css; charset=utf-8"
      ".js" -> "text/javascript; charset=utf-8"
      ".json" -> "application/json; charset=utf-8"
      ".svg" -> "image/svg+xml"
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".gif" -> "image/gif"
      ".txt" -> "text/plain; charset=utf-8"
      _ -> "application/octet-stream"
    end
  end

  @spec csp() :: String.t()
  def csp, do: @csp

  defp resolve_existing(root, candidate) do
    with {:ok, candidate} <- real_path(candidate),
         :ok <- inside?(root, candidate),
         {:ok, stat} <- File.stat(candidate) do
      case stat.type do
        :directory -> resolve_existing(root, Path.join(candidate, "index.html"))
        :regular -> {:ok, candidate}
        _ -> {:error, :unsupported}
      end
    else
      {:error, :enoent} -> {:error, :not_found}
      {:error, :eloop} -> {:error, :not_found}
      other -> other
    end
  end

  defp real_path(path), do: real_path(path, 0)

  defp real_path(_path, hops) when hops > 40, do: {:error, :eloop}

  defp real_path(path, hops) do
    path = Path.expand(path)
    [root | components] = Path.split(path)
    resolve_components(root, components, hops)
  end

  defp resolve_components(current, [], _hops), do: {:ok, current}

  defp resolve_components(current, [component | rest], hops) do
    candidate = Path.join(current, component)

    with {:ok, stat} <- File.lstat(candidate) do
      if stat.type == :symlink do
        with {:ok, target} <- File.read_link(candidate) do
          target
          |> Path.expand(Path.dirname(candidate))
          |> append_components(rest)
          |> real_path(hops + 1)
        end
      else
        resolve_components(candidate, rest, hops)
      end
    end
  end

  defp append_components(path, components) do
    Enum.reduce(components, path, fn component, current -> Path.join(current, component) end)
  end

  defp normalize_rel(""), do: "index.html"

  defp normalize_rel(rel) do
    rel
    |> String.replace("\\", "/")
    |> String.trim_leading("/")
  end

  defp inside?(root, path) do
    relative = Path.relative_to(path, root)

    if Path.type(relative) == :relative and List.first(Path.split(relative)) != ".." do
      :ok
    else
      {:error, :not_found}
    end
  end
end
