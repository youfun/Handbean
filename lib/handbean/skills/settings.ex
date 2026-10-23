defmodule Handbean.Skills.Settings do
  @moduledoc """
  Skill settings projection and persistence owner.

  Wraps `Handbean.Skills.Loader` for discovery and provides safe frontmatter
  updates (`disable-model-invocation`) and template/directory installation for
  workspace and user skills. Bundled skills in `priv/skills` remain read-only.
  """

  alias Handbean.Security.PathValidator
  alias Handbean.Skills.Loader

  @max_file_bytes 65_536
  @valid_name_re ~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/

  @doc """
  Lists discovered skills across workspace, user, and bundled locations.
  """
  @spec list(keyword()) :: {:ok, [map()]}
  def list(opts \\ []) do
    workspace = Keyword.get(opts, :workspace, File.cwd!())
    user_home = Keyword.get(opts, :user_home, Handbean.Home.path())

    %Loader.LoadResult{skills: skills} =
      Loader.load(workspace: workspace, user_home: user_home)

    items =
      Enum.map(skills, fn skill ->
        %{
          id: "skill:#{skill.name}",
          name: skill.name,
          description: skill.description,
          source: skill.source,
          location: skill.location,
          base_dir: skill.base_dir,
          enabled: not skill.disable_model_invocation,
          disable_model_invocation: skill.disable_model_invocation,
          readonly: skill.source == :bundled
        }
      end)

    {:ok, items}
  end

  @doc """
  Reads the `SKILL.md` content for a discovered skill.
  """
  @spec inspect_skill(String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def inspect_skill(name, opts \\ []) when is_binary(name) do
    {:ok, items} = list(opts)

    case Enum.find(items, &(&1.name == name)) do
      nil ->
        {:error, "Skill 不存在"}

      item ->
        case read_safe_skill(item.location) do
          {:ok, content} -> {:ok, %{item: item, content: content}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Toggles model auto-invocation (`disable-model-invocation` in frontmatter) for a
  workspace or user skill. Bundled skills are read-only.
  """
  @spec set_enabled(String.t(), boolean(), keyword()) :: :ok | {:error, String.t()}
  def set_enabled(name, enabled, opts \\ []) when is_binary(name) and is_boolean(enabled) do
    {:ok, items} = list(opts)

    case Enum.find(items, &(&1.name == name)) do
      nil ->
        {:error, "Skill 不存在"}

      %{source: :bundled} ->
        {:error, "内置 Skill 不可直接修改"}

      item ->
        with :ok <- validate_mutable_location(item.location, opts),
             {:ok, content} <- read_safe_skill(item.location),
             updated = update_disable_model_invocation(content, not enabled),
             true <- byte_size(updated) <= @max_file_bytes,
             :ok <- atomic_write(item.location, updated) do
          :ok
        else
          {:error, reason} when is_binary(reason) -> {:error, reason}
          _ -> {:error, "更新 Skill 失败"}
        end
    end
  end

  @doc """
  Installs a curated Skill template into the workspace or user skills directory.
  """
  @spec install_template(map(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def install_template(%{name: name, content: content}, scope, opts \\ [])
      when is_binary(name) and is_binary(content) do
    with :ok <- validate_skill_name(name),
         true <- byte_size(content) <= @max_file_bytes and String.valid?(content),
         {:ok, base_dir} <- target_base_dir(scope, opts),
         :ok <- ensure_safe_base_dir(base_dir),
         skill_dir = Path.join(base_dir, name),
         :ok <- PathValidator.validate_under_root(skill_dir, base_dir),
         :ok <- ensure_not_symlink(skill_dir),
         target_file = Path.join(skill_dir, "SKILL.md"),
         :ok <- atomic_write(target_file, content) do
      {:ok, name}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      _ -> {:error, "安装 Skill 失败"}
    end
  end

  @doc """
  Imports a `SKILL.md` directory from a local path into workspace or user skills.
  """
  @spec import_from_dir(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def import_from_dir(source_dir, scope, opts \\ []) when is_binary(source_dir) do
    expanded = Path.expand(String.trim(source_dir))

    with {:ok, %{type: :directory}} <- File.lstat(expanded),
         {:ok, canonical_dir} <- PathValidator.canonicalize(expanded),
         skill_md = Path.join(canonical_dir, "SKILL.md"),
         {:ok, content} <- read_safe_skill(skill_md),
         %Loader.LoadResult{skills: [skill]} <- Loader.load_from_dir(canonical_dir, :explicit) do
      install_template(%{name: skill.name, content: content}, scope, opts)
    else
      %Loader.LoadResult{diagnostics: [%{message: msg} | _]} ->
        {:error, msg}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      _ ->
        {:error, "未在该目录找到有效的 SKILL.md"}
    end
  end

  # ── Internal helpers ──

  defp validate_skill_name(name) do
    if String.match?(name, @valid_name_re) and String.length(name) <= 64 do
      :ok
    else
      {:error, "无效的 Skill 名称"}
    end
  end

  defp validate_mutable_location(location, opts) do
    workspace = Keyword.get(opts, :workspace, File.cwd!())
    user_home = Keyword.get(opts, :user_home, Handbean.Home.path())

    allowed_roots = [
      Path.join(workspace, ".handbean/skills"),
      Path.join(workspace, ".agents/skills"),
      Path.join(user_home, ".handbean/skills"),
      Path.join(user_home, ".agents/skills")
    ]

    with {:ok, ^location} <- PathValidator.canonicalize(location),
         true <-
           Enum.any?(allowed_roots, &(PathValidator.validate_under_root(location, &1) == :ok)) do
      :ok
    else
      _ -> {:error, "Skill 路径不在可写目录范围内"}
    end
  end

  defp read_safe_skill(path) do
    with {:ok, canonical} <- PathValidator.canonicalize(path),
         true <- canonical == Path.expand(path),
         {:ok, %{type: :regular, size: size}} when size <= @max_file_bytes <- File.lstat(path),
         {:ok, content} <- File.read(path),
         true <-
           byte_size(content) <= @max_file_bytes and String.valid?(content) and
             not String.contains?(content, "\0") do
      {:ok, content}
    else
      _ -> {:error, "无法读取 SKILL.md（文件不存在、超过 64 KiB 或包含符号链接）"}
    end
  end

  defp update_disable_model_invocation(content, disable?) do
    val_str = if disable?, do: "true", else: "false"

    case String.split(content, "\n---\n", parts: 2) do
      [front, body] ->
        lines =
          front
          |> String.trim_leading("---\n")
          |> String.trim_leading("---")
          |> String.split("\n")

        has_key? =
          Enum.any?(lines, fn line ->
            String.starts_with?(String.trim_leading(line), "disable-model-invocation:")
          end)

        updated_lines =
          if has_key? do
            Enum.map(lines, fn line ->
              if String.starts_with?(String.trim_leading(line), "disable-model-invocation:") do
                "disable-model-invocation: #{val_str}"
              else
                line
              end
            end)
          else
            lines ++ ["disable-model-invocation: #{val_str}"]
          end

        "---\n" <> Enum.join(updated_lines, "\n") <> "\n---\n" <> body

      _ ->
        "---\ndisable-model-invocation: #{val_str}\n---\n" <> content
    end
  end

  defp target_base_dir("workspace", opts) do
    with workspace when is_binary(workspace) and workspace != "" <- Keyword.get(opts, :workspace),
         {:ok, resolved} <- PathValidator.canonicalize(workspace) do
      {:ok, Path.join(resolved, ".handbean/skills")}
    else
      _ -> {:error, "未指定当前工作区路径"}
    end
  end

  defp target_base_dir("user", opts) do
    user_home = Keyword.get(opts, :user_home, Handbean.Home.path())

    case PathValidator.canonicalize(user_home) do
      {:ok, resolved} -> {:ok, Path.join(resolved, ".handbean/skills")}
      _ -> {:error, "无效的用户目录"}
    end
  end

  defp target_base_dir(_, _opts), do: {:error, "无效的安装位置"}

  defp ensure_safe_base_dir(base_dir) do
    with :ok <- File.mkdir_p(base_dir),
         {:ok, canonical} <- PathValidator.canonicalize(base_dir),
         true <- canonical == Path.expand(base_dir) do
      :ok
    else
      _ -> {:error, "Skill 目录包含符号链接或不可写"}
    end
  end

  defp ensure_not_symlink(path) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} -> {:error, "不允许使用符号链接"}
      {:ok, _} -> :ok
      {:error, :enoent} -> :ok
      {:error, _} -> {:error, "无法读取路径状态"}
    end
  end

  defp atomic_write(path, content) do
    tmp = path <> "." <> Ecto.UUID.generate() <> ".tmp"

    try do
      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(tmp, content),
           :ok <- File.rename(tmp, path) do
        :ok
      else
        _ -> {:error, "写入文件失败"}
      end
    after
      File.rm(tmp)
    end
  end
end
