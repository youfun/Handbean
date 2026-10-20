defmodule Handbean.CodeIndex.Scan do
  @moduledoc """
  Lists workspace files for the code index.

  Pure Elixir. No shell, no `Handbean.Git`. Symlinks are never followed.
  A gitignore parse failure keeps the fixed directory denylist; it does not
  mean "ignore nothing".
  """

  alias Handbean.Security.PathValidator

  @max_files 5_000
  @max_bytes 256 * 1024

  @denied_dirs MapSet.new(~w(
    node_modules _build deps .git priv .gradle .elixir_ls
    cover log tmp dist build .next .handbean
  ))

  @denied_files MapSet.new(~w(
    .env .env.local .env.production .env.development
    id_rsa id_dsa id_ecdsa id_ed25519
  ))

  @denied_exts MapSet.new(~w(
    .png .jpg .jpeg .gif .webp .ico .pdf .zip .gz .tgz .jar .apk
    .so .exe .dll .dylib .beam .db .sqlite .sqlite3 .woff .woff2
    .mp3 .mp4 .mov .pem .key .p12 .pfx .cer .crt
  ))

  @lock_names MapSet.new(~w(package-lock.json yarn.lock pnpm-lock.yaml mix.lock))

  @type entry :: %{
          path: String.t(),
          abs: String.t(),
          size: non_neg_integer(),
          language: String.t()
        }

  @spec list(Path.t(), keyword()) :: {:ok, [entry()], map()} | {:error, term()}
  def list(workspace_root, opts \\ []) do
    root = Path.expand(workspace_root)
    max_files = Keyword.get(opts, :max_files, @max_files)
    deadline = Keyword.get(opts, :deadline)

    with {:ok, scope} <- resolve_scope(root, Keyword.get(opts, :path)),
         :ok <- ensure_safe_root(root) do
      case scope do
        {:directory, dir} ->
          ignore = load_ignore(root)
          acc = walk(dir, root, ignore, [], %{files: 0, partial: false}, max_files, deadline)
          {:ok, Enum.reverse(acc.entries), Map.take(acc, [:partial, :files, :ignore])}

        {:file, abs, relative} ->
          ignore = %{patterns: [], parse_error: false}
          acc = consider(abs, root, ignore, empty_acc(ignore), max_files, deadline)

          entries =
            acc.entries
            |> Enum.filter(&(&1.path == relative))
            |> Enum.reverse()

          {:ok, entries, Map.take(acc, [:partial, :files, :ignore])}
      end
    end
  end

  @doc "True when a relative path should not be indexed."
  @spec ignored?(String.t(), map()) :: boolean()
  def ignored?(relative, ignore) when is_binary(relative) and is_map(ignore) do
    names = Path.split(relative)
    base = List.last(names) || relative
    ext = base |> Path.extname() |> String.downcase()

    MapSet.member?(@denied_files, base) or
      MapSet.member?(@lock_names, base) or
      MapSet.member?(@denied_exts, ext) or
      Enum.any?(names, &MapSet.member?(@denied_dirs, &1)) or
      match_patterns?(relative, ignore.patterns)
  end

  @doc "True when a stored relative path remains inside the requested scan scope and is non-sensitive."
  @spec allowed_path?(Path.t(), String.t(), keyword()) :: boolean()
  def allowed_path?(root, relative, opts \\ [])

  def allowed_path?(root, relative, opts)
      when is_binary(root) and is_binary(relative) do
    absolute = Path.expand(relative, root)

    PathValidator.validate_under_root(absolute, root) == :ok and
      PathValidator.allowed_result?(root, relative) and
      in_requested_scope?(absolute, root, Keyword.get(opts, :path))
  end

  def allowed_path?(_root, _relative, _opts), do: false

  @doc false
  def load_ignore(root) do
    git = read_patterns(Path.join(root, ".gitignore"), root)
    extra = read_patterns(Path.join(root, ".handbeanignore"), root)

    %{
      patterns: git.patterns ++ extra.patterns,
      parse_error: git.error or extra.error
    }
  end

  defp walk(dir, root, ignore, entries, meta, max_files, deadline) do
    cond do
      meta.files >= max_files ->
        %{entries: entries, partial: true, files: meta.files, ignore: ignore}

      deadline && System.monotonic_time(:millisecond) >= deadline ->
        %{entries: entries, partial: true, files: meta.files, ignore: ignore}

      true ->
        case File.ls(dir) do
          {:ok, names} ->
            Enum.reduce(
              names,
              %{entries: entries, partial: meta.partial, files: meta.files, ignore: ignore},
              fn name, acc ->
                if acc.files >= max_files or acc.partial do
                  %{acc | partial: true}
                else
                  consider(Path.join(dir, name), root, ignore, acc, max_files, deadline)
                end
              end
            )

          {:error, _} ->
            %{entries: entries, partial: meta.partial, files: meta.files, ignore: ignore}
        end
    end
  end

  defp consider(abs, root, ignore, acc, max_files, deadline) do
    relative = Path.relative_to(abs, root)

    cond do
      not PathValidator.allowed_result?(root, relative) ->
        acc

      ignored?(relative, ignore) ->
        acc

      true ->
        case File.lstat(abs) do
          {:ok, %File.Stat{type: :directory}} ->
            nested = walk(abs, root, ignore, acc.entries, acc, max_files, deadline)
            %{nested | ignore: ignore}

          {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_bytes ->
            %{
              acc
              | entries: [entry(relative, abs, size) | acc.entries],
                files: acc.files + 1
            }

          _ ->
            acc
        end
    end
  end

  defp empty_acc(ignore), do: %{entries: [], partial: false, files: 0, ignore: ignore}

  defp resolve_scope(root, nil), do: directory_scope(root)
  defp resolve_scope(root, ""), do: directory_scope(root)

  defp resolve_scope(root, requested) when is_binary(requested) do
    absolute = Path.expand(requested, root)

    with :ok <- PathValidator.validate_under_root(absolute, root),
         :ok <- PathValidator.reject_resolved(absolute) do
      case File.lstat(absolute) do
        {:ok, %File.Stat{type: :directory}} ->
          {:ok, {:directory, absolute}}

        {:ok, %File.Stat{type: :regular}} ->
          {:ok, {:file, absolute, Path.relative_to(absolute, root)}}

        {:ok, %File.Stat{type: :symlink}} ->
          {:error, :symlink}

        {:ok, _} ->
          {:error, :unsupported_file}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_scope(_root, _requested), do: {:error, :invalid_scope}

  defp directory_scope(root) do
    case File.lstat(root) do
      {:ok, %File.Stat{type: :directory}} -> {:ok, {:directory, root}}
      {:ok, %File.Stat{type: :symlink}} -> {:error, :symlink}
      {:ok, _} -> {:error, :not_directory}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_safe_root(root) do
    case PathValidator.reject_resolved(root) do
      :ok -> :ok
      {:error, _} -> {:error, :sensitive_path}
    end
  end

  defp in_requested_scope?(absolute, root, requested) when requested in [nil, ""],
    do: PathValidator.validate_under_root(absolute, root) == :ok

  defp in_requested_scope?(absolute, root, requested) when is_binary(requested) do
    scope = Path.expand(requested, root)

    case File.lstat(scope) do
      {:ok, %File.Stat{type: :directory}} ->
        PathValidator.validate_under_root(absolute, scope) == :ok

      {:ok, %File.Stat{type: :regular}} ->
        PathValidator.resolve_symlink(absolute) == PathValidator.resolve_symlink(scope)

      _ ->
        false
    end
  end

  defp in_requested_scope?(_absolute, _root, _requested), do: false

  defp entry(relative, abs, size) do
    %{
      path: relative,
      abs: abs,
      size: size,
      language: language(relative)
    }
  end

  defp language(path) do
    case path |> Path.extname() |> String.downcase() do
      ".ex" -> "elixir"
      ".exs" -> "elixir"
      ".erl" -> "erlang"
      ".js" -> "javascript"
      ".jsx" -> "javascript"
      ".ts" -> "typescript"
      ".tsx" -> "typescript"
      ".py" -> "python"
      ".go" -> "go"
      ".rs" -> "rust"
      ".c" -> "c"
      ".h" -> "c"
      ".cpp" -> "cpp"
      ".hpp" -> "cpp"
      ".md" -> "markdown"
      ".markdown" -> "markdown"
      _ -> "text"
    end
  end

  defp read_patterns(path, root) do
    relative = Path.relative_to(path, root)

    cond do
      PathValidator.validate_under_root(path, root) != :ok ->
        %{patterns: [], error: true}

      not PathValidator.allowed_result?(root, relative) ->
        %{patterns: [], error: true}

      true ->
        case File.lstat(path) do
          {:ok, %File.Stat{type: :regular}} -> read_regular_patterns(path)
          {:ok, %File.Stat{type: :symlink}} -> %{patterns: [], error: false}
          {:ok, _} -> %{patterns: [], error: true}
          {:error, :enoent} -> %{patterns: [], error: false}
          {:error, _} -> %{patterns: [], error: true}
        end
    end
  end

  defp read_regular_patterns(path) do
    case File.read(path) do
      {:ok, body} -> %{patterns: parse_patterns(body), error: false}
      {:error, :enoent} -> %{patterns: [], error: false}
      {:error, _} -> %{patterns: [], error: true}
    end
  end

  @doc false
  def parse_patterns(body) when is_binary(body) do
    body
    |> String.split(["\n", "\r\n"], trim: false)
    |> Enum.flat_map(&parse_line/1)
  end

  defp parse_line(line) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" or String.starts_with?(trimmed, "#") ->
        []

      String.contains?(trimmed, "**") ->
        []

      true ->
        pattern =
          trimmed
          |> String.trim_leading("/")
          |> String.trim_trailing("/")

        if pattern == "", do: [], else: [pattern]
    end
  end

  defp match_patterns?(relative, patterns) do
    Enum.any?(patterns, &pattern_match?(relative, &1))
  end

  defp pattern_match?(relative, pattern) do
    cond do
      String.ends_with?(pattern, "/") ->
        false

      String.contains?(pattern, "*") ->
        glob_match?(relative, pattern) or glob_match?(Path.basename(relative), pattern)

      String.contains?(pattern, "/") ->
        relative == pattern or String.starts_with?(relative, pattern <> "/")

      true ->
        relative == pattern or
          Path.basename(relative) == pattern or
          String.contains?(relative, "/" <> pattern <> "/") or
          String.starts_with?(relative, pattern <> "/")
    end
  end

  defp glob_match?(text, pattern) do
    escaped =
      pattern
      |> Regex.escape()
      |> String.replace("\\*", ".*")

    Regex.match?(~r/\A#{escaped}\z/, text)
  end
end
