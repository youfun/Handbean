defmodule Handbean.Extension.Settings do
  @moduledoc """
  Extension settings projection and persistence owner.

  Reads extension manifests from project and user directories, projects runtime
  state from `Handbean.Extension.Registry` and `Handbean.ProjectTrust`, and
  persists `enabled` changes or template/directory installations back to disk
  before triggering `Handbean.Extension.HotReloader`.
  """

  alias Handbean.Extension.{HotReloader, Loader}
  alias Handbean.Extension.Registry, as: ExtRegistry
  alias Handbean.ProjectTrust
  alias Handbean.Security.PathValidator

  @max_source_preview_bytes 131_072
  @max_install_file_bytes 262_144

  @doc """
  Lists discovered extensions across workspace and user directories with their
  current runtime status.
  """
  @spec list(keyword()) :: {:ok, [map()]}
  def list(opts \\ []) do
    project = Keyword.get(opts, :project)
    user_home = Keyword.get(opts, :user_home, Handbean.Home.path())
    ext_registry = Keyword.get(opts, :ext_registry, ExtRegistry)
    trusted_project? = ProjectTrust.enabled?(opts)

    project_exts =
      if is_binary(project) and project != "" do
        project
        |> Loader.from_project()
        |> Map.get(:extensions, [])
        |> Enum.map(&{&1, :project})
      else
        []
      end

    project_names =
      if trusted_project?,
        do: MapSet.new(project_exts, fn {ext, _source} -> ext.name end),
        else: MapSet.new()

    user_exts =
      if is_binary(user_home) and user_home != "" do
        user_home
        |> Loader.from_user()
        |> Map.get(:extensions, [])
        |> Enum.reject(fn ext -> MapSet.member?(project_names, ext.name) end)
        |> Enum.map(&{&1, :user})
      else
        []
      end

    items =
      (project_exts ++ user_exts)
      |> Enum.sort_by(fn {ext, source} -> {source_rank(source), ext.name} end)
      |> Enum.map(fn {ext, source} ->
        build_item(ext, source, trusted_project?, ext_registry)
      end)

    {:ok, items}
  end

  @doc """
  Reads source/manifest details and diagnostics for a single extension by name.
  """
  @spec inspect_extension(String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def inspect_extension(identifier, opts \\ []) when is_binary(identifier) do
    {:ok, items} = list(opts)

    case find_item(items, identifier) do
      nil ->
        {:error, "扩展不存在"}

      item ->
        {:ok,
         %{
           item: item,
           code: read_extension_preview(item.root, item.entry),
           diagnostic: item.diagnostic
         }}
    end
  end

  @doc """
  Updates the `"enabled"` flag in an extension's manifest file and reloads runtime state.
  """
  @spec set_enabled(String.t(), boolean(), keyword()) :: :ok | {:error, String.t()}
  def set_enabled(identifier, enabled, opts \\ [])
      when is_binary(identifier) and is_boolean(enabled) do
    {:ok, items} = list(opts)

    case find_item(items, identifier) do
      nil ->
        {:error, "扩展不存在"}

      item ->
        with :ok <- validate_extension_root(item.root, opts),
             {:ok, manifest_path} <- find_safe_manifest(item.root),
             {:ok, content} <- File.read(manifest_path),
             {:ok, data} when is_map(data) <- Handbean.JSON.decode(content),
             updated_json = Handbean.JSON.encode!(Map.put(data, "enabled", enabled), pretty: true),
             :ok <- atomic_write(manifest_path, updated_json),
             :ok <- reload_runtime(opts) do
          :ok
        else
          {:error, reason} when is_binary(reason) -> {:error, reason}
          _ -> {:error, "无法更新扩展配置"}
        end
    end
  end

  @doc """
  Installs a curated extension template (`manifest` map + `entry_code`) into the
  workspace or user extension directory.
  """
  @spec install_template(map(), String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def install_template(
        %{name: name, manifest: manifest, entry_code: entry_code},
        scope,
        opts \\ []
      )
      when is_binary(name) and is_map(manifest) and is_binary(entry_code) do
    with {:ok, base_dir} <- target_base_dir(scope, opts),
         :ok <- ensure_safe_base_dir(base_dir),
         {:ok, _target_dir} <-
           publish_extension(base_dir, name, fn stage_dir ->
             manifest_path = Path.join(stage_dir, "extension.json")
             entry_rel = Map.get(manifest, "entry", "extension.ex")
             entry_path = Path.expand(entry_rel, stage_dir)

             with :ok <- PathValidator.validate_under_root(entry_path, stage_dir),
                  :ok <-
                    atomic_write(manifest_path, Handbean.JSON.encode!(manifest, pretty: true)),
                  :ok <- atomic_write(entry_path, entry_code) do
               :ok
             end
           end),
         :ok <- reload_runtime(opts) do
      {:ok, name}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      _ -> {:error, "安装扩展失败"}
    end
  end

  @doc """
  Imports an extension from a local directory into the workspace or user extension root.
  """
  @spec import_from_dir(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def import_from_dir(source_dir, scope, opts \\ []) when is_binary(source_dir) do
    expanded = Path.expand(String.trim(source_dir))

    with {:ok, canonical_dir} <- validate_source_dir(expanded),
         %Loader.Result{extensions: [ext], diagnostics: []} <- Loader.from_explicit(canonical_dir),
         {:ok, base_dir} <- target_base_dir(scope, opts),
         :ok <- ensure_safe_base_dir(base_dir),
         {:ok, _target_dir} <-
           publish_extension(base_dir, ext.name, fn stage_dir ->
             copy_extension_dir(canonical_dir, stage_dir)
           end),
         :ok <- reload_runtime(opts) do
      {:ok, ext.name}
    else
      %Loader.Result{diagnostics: [diag | _]} ->
        {:error, diag.message}

      %Loader.Result{} ->
        {:error, "未在该目录找到有效的 extension.json"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      _ ->
        {:error, "导入扩展目录失败"}
    end
  end

  # ── Internal helpers ──

  defp find_item(items, identifier) do
    Enum.find(items, &(&1.id == identifier)) ||
      Enum.find(items, &(&1.name == identifier and &1.status == :enabled)) ||
      Enum.find(items, &(&1.name == identifier))
  end

  defp source_rank(:project), do: 0
  defp source_rank(:user), do: 1

  defp build_item(ext, source, trusted_project?, ext_registry) do
    {status, diagnostic} = resolve_status(ext, source, trusted_project?, ext_registry)

    %{
      id: "ext:#{source}:#{ext.name}",
      name: ext.name,
      version: ext.version || "0.1.0",
      description: ext.description || "",
      source: source,
      root: ext.root,
      entry: ext.entry,
      enabled: ext.enabled,
      status: status,
      diagnostic: diagnostic,
      tool_count: length(ext.tools),
      hook_count: length(ext.hooks)
    }
  end

  defp resolve_status(%{enabled: false}, _source, _trusted_project?, _ext_registry) do
    {:disabled, nil}
  end

  defp resolve_status(_ext, :project, false, _ext_registry) do
    {:untrusted_project, "当前工作区未启用扩展代码执行权限"}
  end

  defp resolve_status(ext, _source, _trusted_project?, ext_registry) do
    case lookup_registered(ext_registry, ext.name) do
      {:ok, %{enabled: true, root: root}} when is_binary(root) ->
        if Path.expand(root) == Path.expand(ext.root),
          do: {:enabled, nil},
          else: {:inactive, "扩展尚未载入或最近一次载入失败"}

      _ ->
        {:inactive, "扩展尚未载入或最近一次载入失败"}
    end
  end

  defp lookup_registered(ext_registry, name) when is_atom(ext_registry) do
    if Process.whereis(ext_registry) do
      ExtRegistry.get(ext_registry, name)
    else
      {:error, :not_running}
    end
  end

  defp lookup_registered(ext_registry, name) when is_pid(ext_registry) do
    if Process.alive?(ext_registry) do
      ExtRegistry.get(ext_registry, name)
    else
      {:error, :not_running}
    end
  end

  defp lookup_registered(_, _), do: {:error, :not_running}

  defp reload_runtime(opts) do
    project = Keyword.get(opts, :project, File.cwd!())
    user_home = Keyword.get(opts, :user_home, Handbean.Home.path())
    ext_registry = Keyword.get(opts, :ext_registry, ExtRegistry)
    trust_opts = Keyword.take(opts, [:trusted_project?])

    if (is_atom(ext_registry) and Process.whereis(ext_registry) != nil) or
         (is_pid(ext_registry) and Process.alive?(ext_registry)) do
      case HotReloader.reload(
             [project: project, user_home: user_home, ext_registry: ext_registry] ++ trust_opts
           ) do
        {:ok, []} ->
          :ok

        {:ok, diagnostics} ->
          message = Enum.map_join(diagnostics, "; ", & &1.message)
          {:error, "扩展已写入磁盘，但未成功激活: #{message}"}

        {:error, reason} ->
          {:error, "扩展已写入磁盘，但重新载入失败: #{inspect(reason)}"}
      end
    else
      :ok
    end
  end

  defp validate_extension_root(root, opts) do
    allowed_roots =
      [
        Keyword.get(opts, :project) &&
          Path.join(Keyword.get(opts, :project), ".handbean/extensions"),
        Path.join(Keyword.get(opts, :user_home, Handbean.Home.path()), ".handbean/extensions")
      ]
      |> Enum.reject(&is_nil/1)

    if Enum.any?(allowed_roots, &(PathValidator.validate_under_root(root, &1) == :ok)) and
         ensure_not_symlink(root) == :ok do
      :ok
    else
      {:error, "扩展目录不在受信任路径内"}
    end
  end

  defp find_safe_manifest(root) do
    ext_json = Path.join(root, "extension.json")
    manifest_json = Path.join(root, "manifest.json")

    path =
      cond do
        File.exists?(ext_json) -> ext_json
        File.exists?(manifest_json) -> manifest_json
        true -> nil
      end

    case path do
      nil ->
        {:error, "未找到 extension.json"}

      file ->
        case File.lstat(file) do
          {:ok, %{type: :regular}} -> {:ok, file}
          _ -> {:error, "非法配置文件类型"}
        end
    end
  end

  defp read_extension_preview(root, entry) do
    target =
      if is_binary(entry) and File.exists?(entry) do
        entry
      else
        Path.join(root, "extension.json")
      end

    with :ok <- PathValidator.validate_under_root(target, root),
         {:ok, %{type: :regular, size: size}} when size <= @max_source_preview_bytes <-
           File.lstat(target),
         {:ok, content} <- File.read(target),
         true <- String.valid?(content) do
      content
    else
      _ -> ""
    end
  end

  defp target_base_dir("workspace", opts) do
    with project when is_binary(project) and project != "" <- Keyword.get(opts, :project),
         {:ok, resolved} <- PathValidator.canonicalize(project) do
      {:ok, Path.join(resolved, ".handbean/extensions")}
    else
      _ -> {:error, "未指定当前工作区路径"}
    end
  end

  defp target_base_dir("user", opts) do
    user_home = Keyword.get(opts, :user_home, Handbean.Home.path())

    case PathValidator.canonicalize(user_home) do
      {:ok, resolved} -> {:ok, Path.join(resolved, ".handbean/extensions")}
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
      _ -> {:error, "扩展根目录包含符号链接或不可写"}
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

  defp validate_source_dir(dir) do
    with {:ok, %{type: :directory}} <- File.lstat(dir),
         {:ok, parent} <- PathValidator.canonicalize(Path.dirname(dir)),
         {:ok, canonical} <- PathValidator.canonicalize(dir),
         true <- canonical == Path.join(parent, Path.basename(dir)) do
      {:ok, canonical}
    else
      _ -> {:error, "导入目录不存在或包含符号链接"}
    end
  end

  defp publish_extension(base_dir, name, writer) when is_function(writer, 1) do
    target_dir = Path.join(base_dir, name)
    stage_dir = Path.join(Path.dirname(base_dir), ".extension-stage-#{Ecto.UUID.generate()}")

    try do
      with :ok <- PathValidator.validate_under_root(target_dir, base_dir),
           :ok <- PathValidator.validate_under_root(stage_dir, Path.dirname(base_dir)),
           false <- File.exists?(target_dir),
           :ok <- File.mkdir(stage_dir),
           :ok <- writer.(stage_dir),
           :ok <- validate_staged_extension(stage_dir, name),
           :ok <- File.rename(stage_dir, target_dir) do
        {:ok, target_dir}
      else
        true -> {:error, "同名扩展已存在；请先移除后再安装"}
        %Loader.Result{diagnostics: [diag | _]} -> {:error, diag.message}
        %Loader.Result{} -> {:error, "扩展目录缺少有效 manifest"}
        {:error, reason} when is_binary(reason) -> {:error, reason}
        {:error, reason} -> {:error, "发布扩展失败: #{inspect(reason)}"}
        other -> {:error, "发布扩展失败: #{inspect(other)}"}
      end
    after
      File.rm_rf(stage_dir)
    end
  end

  defp validate_staged_extension(stage_dir, expected_name) do
    case Loader.from_explicit(stage_dir) do
      %Loader.Result{extensions: [%{name: ^expected_name}], diagnostics: []} ->
        :ok

      %Loader.Result{extensions: [_], diagnostics: []} ->
        {:error, "扩展 manifest 名称与安装名称不一致"}

      %Loader.Result{diagnostics: [diag | _]} ->
        {:error, diag.message}

      %Loader.Result{} ->
        {:error, "扩展目录缺少有效 manifest"}
    end
  end

  defp copy_extension_dir(source_dir, target_dir) do
    with {:ok, files, _total} <- collect_install_files(source_dir, "", [], 0),
         :ok <- copy_install_files(source_dir, target_dir, files) do
      :ok
    end
  end

  defp collect_install_files(_root, _relative, _files, total) when total > 2 * 1024 * 1024,
    do: {:error, "导入扩展总大小超过 2 MiB"}

  defp collect_install_files(root, relative, files, total) do
    dir = if relative == "", do: root, else: Path.join(root, relative)

    with {:ok, entries} <- File.ls(dir) do
      Enum.reduce_while(entries, {:ok, files, total}, fn entry, {:ok, acc, used} ->
        child_relative = if relative == "", do: entry, else: Path.join(relative, entry)
        child = Path.join(root, child_relative)

        case File.lstat(child) do
          {:ok, %{type: :regular, size: size}}
          when size <= @max_install_file_bytes and length(acc) < 64 and
                 used + size <= 2 * 1024 * 1024 ->
            {:cont, {:ok, [child_relative | acc], used + size}}

          {:ok, %{type: :directory}} ->
            case collect_install_files(root, child_relative, acc, used) do
              {:ok, nested, nested_total} -> {:cont, {:ok, nested, nested_total}}
              {:error, _} = error -> {:halt, error}
            end

          {:ok, %{type: :symlink}} ->
            {:halt, {:error, "导入目录不允许包含符号链接"}}

          _ ->
            {:halt, {:error, "扩展文件过大、过多或不可读: #{child_relative}"}}
        end
      end)
    else
      _ -> {:error, "无法读取扩展目录"}
    end
  end

  defp copy_install_files(source_dir, target_dir, files) do
    Enum.reduce_while(files, :ok, fn relative, :ok ->
      source = Path.join(source_dir, relative)
      destination = Path.join(target_dir, relative)

      with {:ok, bytes} <- File.read(source),
           :ok <- atomic_write(destination, bytes) do
        {:cont, :ok}
      else
        _ -> {:halt, {:error, "复制扩展文件失败: #{relative}"}}
      end
    end)
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
