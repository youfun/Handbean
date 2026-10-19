defmodule Handbean.Security.PathValidator do
  @moduledoc """
  Path security validation — prevent path traversal and ensure safe file access.

  Validates that resolved paths stay within the workspace and checks file
  accessibility. Sensitive credential paths are a fixed code denylist, not a
  workspace setting.

  `reject_sensitive_command/2` is a best-effort scan of path-like tokens. It
  closes the sandbox hole where the host filesystem is readable by default. It
  is not a shell parser and does not expand variables, command substitutions,
  globs, or encoded payloads.
  """

  @doc """
  Validate that a path exists and is readable.
  Returns `:ok` or `{:error, reason}`.
  """
  @spec validate_readable(String.t()) :: :ok | {:error, String.t()}
  def validate_readable(path) do
    with :ok <- check_exists(path),
         :ok <- check_not_directory(path) do
      case File.stat(path) do
        {:ok, %{access: access}} when access in [:read, :read_write] -> :ok
        {:ok, _} -> {:error, "#{path}: Permission denied (EACCES)"}
        {:error, reason} -> {:error, "#{path}: #{inspect(reason)}"}
      end
    end
  end

  @doc """
  Validate that a path, or the nearest existing ancestor, is writeable.

  A missing file is writeable when its parent is. A missing parent is not a
  permission error: walk up to the nearest existing ancestor and check that.
  Callers that create directories, such as `write`, can then mkdir_p.
  """
  @spec validate_writeable(String.t()) :: :ok | {:error, String.t()}
  def validate_writeable(path) do
    cond do
      File.exists?(path) ->
        if is_writeable?(path), do: :ok, else: {:error, "#{path}: Read-only file (EACCES)"}

      ancestor = nearest_existing_ancestor(path) ->
        if is_writeable?(ancestor) do
          :ok
        else
          {:error, "#{path}: Parent directory not writeable (EACCES)"}
        end

      true ->
        {:error, "#{path}: No such file"}
    end
  end

  @doc """
  Validate that a resolved path is within the allowed workspace.

  Each path component is canonicalized, including intermediate symlinks.
  A workspace-relative name such as `escape/repo` whose `escape` component
  points outside the workspace is rejected.
  """
  @spec validate_within_workspace(String.t(), String.t()) :: :ok | {:error, String.t()}
  def validate_within_workspace(path, workspace) when is_binary(workspace) do
    with {:ok, resolved} <- canonicalize(path),
         {:ok, ws} <- canonicalize(workspace) do
      if contained?(resolved, ws) do
        :ok
      else
        {:error, "Path traversal blocked: #{path} is outside workspace"}
      end
    else
      {:error, _} ->
        {:error, "Path traversal blocked: #{path} is outside workspace"}
    end
  end

  @doc """
  Validate that a directory path is under the allowed root directory.

  Canonicalizes both paths, resolving every existing symlink ancestor while
  retaining nonexistent tails. Like other path-based checks, this is not an
  atomic filesystem operation and cannot prevent a concurrent symlink swap.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec validate_under_root(String.t(), String.t()) :: :ok | {:error, String.t()}
  def validate_under_root(path, root) do
    with {:ok, resolved_path} <- canonicalize(path),
         {:ok, resolved_root} <- canonicalize(root),
         true <- contained?(resolved_path, resolved_root) do
      :ok
    else
      _ -> {:error, "Path traversal blocked: #{path} is outside #{root}"}
    end
  end

  @doc """
  Canonicalize `path` by expanding `.`/`..` and resolving every existing
  symlink component. Missing tail components are appended lexically so
  `init` of a new directory still has a containment check.
  """
  @spec canonicalize(String.t()) :: {:ok, String.t()} | {:error, :symlink_loop}
  def canonicalize(path) when is_binary(path) do
    walk_parts(Path.split(Path.expand(path)), [], MapSet.new(), %{})
  end

  @doc false
  @spec resolve_symlink(String.t()) :: String.t()
  def resolve_symlink(path) do
    case canonicalize(path) do
      {:ok, resolved} -> resolved
      {:error, _} -> Path.expand(path)
    end
  end

  @sensitive_reason "sensitive path blocked"

  @sensitive_dirs MapSet.new(~w(
    .ssh .aws .gcloud .gnupg .gpg .docker .kube
  ))

  @sensitive_files MapSet.new(~w(
    id_rsa id_rsa.pub
    id_dsa id_dsa.pub
    id_ecdsa id_ecdsa.pub
    id_ed25519 id_ed25519.pub
    authorized_keys known_hosts ssh_config
    ssh_host_rsa_key ssh_host_rsa_key.pub
    ssh_host_ed25519_key ssh_host_ed25519_key.pub
    .bash_history .zsh_history .zhistory .sh_history
    .netrc .git-credentials
  ))

  @sensitive_exts ~w(.pem .key .p12 .pfx)

  @doc "Stable short reason for a sensitive-path rejection. Does not include the path."
  @spec sensitive_reason() :: String.t()
  def sensitive_reason, do: @sensitive_reason

  @doc """
  Reject a credential path.

  `path` should already be a canonical absolute path. Matching is case-insensitive
  against any path component. Returns `{:error, #{inspect(@sensitive_reason)}}` or `:ok`.
  The error never includes the path or file contents.
  """
  @spec reject_sensitive(String.t()) :: :ok | {:error, String.t()}
  def reject_sensitive(path) when is_binary(path) do
    parts = sensitive_parts(path)

    if sensitive_parts?(parts) do
      {:error, @sensitive_reason}
    else
      :ok
    end
  end

  def reject_sensitive(_path), do: :ok

  @doc """
  Canonicalize `path` when possible, then `reject_sensitive/1`.

  Missing tails are still matched lexically. A symlink to a credential file is
  rejected without reading it.
  """
  @spec reject_resolved(String.t()) :: :ok | {:error, String.t()}
  def reject_resolved(path) when is_binary(path) do
    expanded = expand_home(path)

    canonical =
      case canonicalize(expanded) do
        {:ok, resolved} -> resolved
        {:error, _} -> Path.expand(expanded)
      end

    case reject_sensitive(canonical) do
      :ok -> reject_sensitive(expanded)
      error -> error
    end
  end

  def reject_resolved(_path), do: :ok

  @doc false
  @spec allowed_result?(String.t(), String.t()) :: boolean()
  def allowed_result?(root, relative) when is_binary(root) and is_binary(relative) do
    expanded =
      if Path.type(relative) == :absolute do
        Path.expand(relative)
      else
        Path.expand(relative, root)
      end

    reject_sensitive(relative) == :ok and reject_resolved(expanded) == :ok
  end

  def allowed_result?(_root, _relative), do: false

  @doc false
  @spec rg_exclude_globs() :: [String.t()]
  def rg_exclude_globs do
    dirs =
      Enum.flat_map(@sensitive_dirs, fn dir ->
        ["!**/#{dir}/**", "!**/#{dir}"]
      end)

    files = Enum.map(@sensitive_files, &"!**/#{&1}")
    exts = Enum.map(@sensitive_exts, &"!**/*#{&1}")

    dirs ++
      files ++
      exts ++
      ["!**/.env", "!**/.env.*", "!**/.config/gcloud/**", "!**/.config/gcloud"]
  end

  @doc """
  Best-effort rejection of a shell command that names a sensitive path.

  Extracts absolute paths, `~/` paths, and relative tokens that contain a denied
  component or that exist under `cwd`. Expands `~`, canonicalizes, then calls
  `reject_sensitive/1`. Does not evaluate the shell. Quotes, variable expansion,
  globs, and payloads such as a dynamically built `base64` of a credential file
  are not fully solved.
  """
  @spec reject_sensitive_command(String.t(), String.t() | nil) :: :ok | {:error, String.t()}
  def reject_sensitive_command(command, cwd \\ nil)

  def reject_sensitive_command(command, cwd) when is_binary(command) do
    with :ok <- reject_cwd(cwd) do
      command
      |> command_tokens()
      |> Enum.reduce_while(:ok, fn token, :ok ->
        case reject_token(token, cwd) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  def reject_sensitive_command(_command, _cwd), do: :ok

  defp reject_cwd(cwd) when is_binary(cwd) and cwd != "" do
    case reject_resolved(cwd) do
      :ok -> reject_sensitive(cwd)
      error -> error
    end
  end

  defp reject_cwd(_cwd), do: :ok

  defp command_tokens(command) do
    command
    |> String.split(~r/[[:space:]|&;<>()`$'"#\\=]+/u, trim: true)
    |> Enum.map(&clean_token/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp clean_token(token) do
    token
    |> String.trim()
    |> String.trim("\"'")
    |> String.trim_trailing(",")
  end

  defp reject_token(token, cwd) do
    cond do
      skip_token?(token) ->
        :ok

      lexical_sensitive?(token) ->
        {:error, @sensitive_reason}

      path_like?(token) or existing_relative?(token, cwd) ->
        check_token_path(token, cwd)

      true ->
        :ok
    end
  end

  defp skip_token?(token) do
    String.contains?(token, "://") or
      (String.starts_with?(token, "-") and not String.contains?(token, "/") and
         not lexical_sensitive?(token))
  end

  defp path_like?(token) do
    String.starts_with?(token, ["~", "/", "./", "../"]) or String.contains?(token, "/")
  end

  defp lexical_sensitive?(token) do
    reject_sensitive(token) != :ok or
      reject_sensitive(String.replace(token, ":", "/")) != :ok
  end

  defp existing_relative?(token, cwd) do
    case token_absname(token, cwd) do
      {:ok, path} -> File.exists?(path)
      :error -> false
    end
  end

  defp check_token_path(token, cwd) do
    case token_absname(token, cwd) do
      {:ok, path} -> reject_resolved(path)
      :error -> :ok
    end
  end

  # Command tokens are not always paths. Elixir 1.20 `Path.type/1` on Windows
  # treats any `X:...` as `:volumerelative` (letter is unguarded), so `[:0]`
  # looks expandable. `Path.expand/2` then raises `FunctionClauseError`.
  # `expandable_token?/1` skips that case; `/[:0]` still matches a leading slash,
  # so `expand_or_join/2` also rescues that one clause and joins onto cwd.
  defp token_absname(token, cwd) do
    expanded = expand_home(token)
    base = cwd_base(cwd)

    cond do
      not is_binary(expanded) or expanded == "" ->
        :error

      not is_binary(base) or base == "" ->
        :error

      expandable_token?(expanded) ->
        expand_or_join(expanded, base)

      true ->
        {:ok, Path.join(base, expanded)}
    end
  end

  defp expandable_token?(<<drive, ?:, _::binary>>)
       when drive in ?A..?Z or drive in ?a..?z,
       do: true

  defp expandable_token?(<<sep, _::binary>>) when sep in [?/, ?\\], do: true
  defp expandable_token?(_path), do: false

  defp expand_or_join(path, base) do
    {:ok, Path.expand(path, base)}
  rescue
    FunctionClauseError ->
      {:ok, Path.join(base, path)}
  end

  defp cwd_base(cwd) when is_binary(cwd) and cwd != "", do: expand_home(cwd)
  defp cwd_base(_cwd), do: File.cwd!()

  defp expand_home("~"), do: Handbean.Home.path()
  defp expand_home("~/" <> rest), do: Path.join(Handbean.Home.path(), rest)
  defp expand_home("~" <> rest), do: Path.join(Handbean.Home.path(), rest)
  defp expand_home(path), do: path

  defp sensitive_parts(path) do
    path
    |> Path.split()
    |> Enum.map(&String.downcase/1)
    |> Enum.reject(&(&1 in ["", "/"]))
  end

  defp sensitive_parts?(parts) do
    Enum.any?(parts, &sensitive_part?/1) or config_gcloud?(parts)
  end

  defp sensitive_part?(part) do
    MapSet.member?(@sensitive_dirs, part) or
      MapSet.member?(@sensitive_files, part) or
      part == ".env" or
      String.starts_with?(part, ".env.") or
      Enum.any?(@sensitive_exts, &String.ends_with?(part, &1))
  end

  defp config_gcloud?(parts) do
    parts
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.any?(fn
      [".config", "gcloud"] -> true
      _ -> false
    end)
  end

  defp walk_parts([], acc, _stack, _cache) do
    {:ok, join_parts(acc)}
  end

  defp walk_parts([part | rest], acc, stack, cache) do
    current = join_parts(acc ++ [part])

    cond do
      MapSet.member?(stack, current) ->
        {:error, :symlink_loop}

      is_map_key(cache, current) ->
        walk_parts(rest, Path.split(cache[current]), stack, cache)

      true ->
        case File.lstat(current) do
          {:ok, %File.Stat{type: :symlink}} ->
            follow_symlink(current, rest, stack, cache)

          {:ok, _} ->
            walk_parts(rest, acc ++ [part], stack, cache)

          {:error, :enoent} ->
            {:ok, join_parts(acc ++ [part | rest])}

          {:error, _} ->
            {:ok, join_parts(acc ++ [part | rest])}
        end
    end
  end

  defp follow_symlink(current, rest, stack, cache) do
    case File.read_link(current) do
      {:ok, target} ->
        resolved =
          if Path.type(target) == :absolute do
            Path.expand(target)
          else
            Path.expand(target, Path.dirname(current))
          end

        stacked = MapSet.put(stack, current)

        with {:ok, prefix} <- walk_parts(Path.split(resolved), [], stacked, cache) do
          cache = Map.put(cache, current, prefix)
          walk_parts(rest, Path.split(prefix), stack, cache)
        end

      {:error, _} ->
        {:ok, join_parts(Path.split(current) ++ rest)}
    end
  end

  defp join_parts([]), do: ""
  defp join_parts(parts), do: Path.join(parts)

  defp contained?(path, root) do
    path = String.trim_trailing(path, "/")
    root = String.trim_trailing(root, "/")
    path == root or String.starts_with?(path, root <> "/")
  end

  # ── Private helpers ──

  defp check_exists(path) do
    if File.exists?(path), do: :ok, else: {:error, "#{path}: No such file"}
  end

  defp check_not_directory(path) do
    case File.stat(path) do
      {:ok, %{type: :directory}} -> {:error, "#{path}: Is a directory"}
      _ -> :ok
    end
  end

  defp nearest_existing_ancestor(path) do
    path
    |> Path.dirname()
    |> Stream.iterate(&Path.dirname/1)
    |> Enum.reduce_while(nil, fn dir, _acc ->
      cond do
        File.exists?(dir) -> {:halt, dir}
        dir == Path.dirname(dir) -> {:halt, nil}
        true -> {:cont, nil}
      end
    end)
  end

  defp is_writeable?(path) do
    case File.stat(path) do
      {:ok, %{access: access, type: type}}
      when access in [:write, :read_write] and type in [:directory, :regular] ->
        true

      _ ->
        false
    end
  end
end
