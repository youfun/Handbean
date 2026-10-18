defmodule Handbean.Workspace.MixCompat do
  @moduledoc """
  Host-conflict and package-kind checks for Mix projects running in this VM.

  Pure Elixir/Erlang Mix packages are allowed. Native compilers, non-Mix
  managers, host application version mismatches, and module name collisions
  are rejected with an explicit error. This is not a sandbox.
  """

  @allowed_compilers MapSet.new(
                       Mix.compilers() ++
                         [:elixir, :erlang, :app, :yecc, :leex, :xref, :protocols, :consolidate]
                     )

  @native_compilers MapSet.new([
                      :elixir_make,
                      :rustler,
                      :rustler_precompiled,
                      :zigler,
                      :cc_precompiler,
                      :elixir_cmake
                    ])

  @native_root_entries MapSet.new([
                         "c_src",
                         "native",
                         "Makefile",
                         "makefile",
                         "CMakeLists.txt",
                         "rebar.config",
                         "rebar.config.script"
                       ])

  @native_mix_markers [
    ~r/\belixir_make\b/,
    ~r/\brustler\b/,
    ~r/\bzigler\b/,
    ~r/\bcc_precompiler\b/,
    ~r/\b:make\b/,
    ~r/\b:rebar3\b/
  ]

  # Packaged into the mobile OTP tree. Workspace Mix may reuse these instead
  # of compiling C on the device. Version must match the host copy exactly, or
  # the host copy must satisfy the project's Mix requirement.
  @host_native_apps MapSet.new([:bcrypt_elixir, :exqlite])

  defstruct apps: %{}, app_paths: %{}, modules: MapSet.new(), code_paths: MapSet.new()

  @type app_source :: Path.t() | {:beams, [{module(), Path.t()}], keyword()}
  @type t :: %__MODULE__{
          apps: %{atom() => String.t()},
          app_paths: %{atom() => app_source() | nil},
          modules: MapSet.t(module()),
          code_paths: MapSet.t(Path.t())
        }

  @spec snapshot() :: t()
  def snapshot do
    apps =
      (Application.loaded_applications() ++ Application.started_applications())
      |> Enum.uniq_by(&elem(&1, 0))
      |> Map.new(fn {app, _desc, vsn} -> {app, List.to_string(vsn)} end)

    modules =
      :code.all_loaded()
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    app_paths =
      Map.new(apps, fn {app, _version} ->
        {app, host_app_source(app)}
      end)

    code_paths =
      :code.get_path()
      |> Enum.map(&(&1 |> List.to_string() |> Path.expand()))
      |> MapSet.new()

    %__MODULE__{apps: apps, app_paths: app_paths, modules: modules, code_paths: code_paths}
  end

  @spec refresh_loaded_modules(t(), [Path.t()], MapSet.t(module())) :: t()
  def refresh_loaded_modules(
        %__MODULE__{} = host,
        workspace_roots \\ [],
        owned_modules \\ MapSet.new()
      ) do
    workspace_roots = Enum.map(workspace_roots, &Path.expand/1)

    workspace_modules =
      workspace_roots
      |> Enum.flat_map(&workspace_modules/1)
      |> MapSet.new()
      |> MapSet.union(owned_modules)

    modules =
      :code.all_loaded()
      |> Enum.reject(fn {module, path} ->
        MapSet.member?(workspace_modules, module) or workspace_path?(path, workspace_roots)
      end)
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    %{host | modules: MapSet.union(host.modules, modules)}
  end

  @spec project_module_names(Path.t()) :: MapSet.t(module())
  def project_module_names(project_path) do
    project_path |> project_modules() |> MapSet.new()
  end

  @spec check([Mix.Dep.t()], t()) :: :ok | {:error, String.t()}
  def check(deps, host \\ snapshot()) when is_list(deps) do
    Enum.reduce_while(flatten_deps(deps), :ok, fn dep, :ok ->
      case check_dep(dep, host) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec host_dependencies([Mix.Dep.t()], t()) ::
          {:ok, [{Mix.Dep.t(), app_source()}]} | {:error, String.t()}
  def host_dependencies(deps, %__MODULE__{} = host) do
    deps
    |> flatten_deps()
    |> Enum.reduce_while({:ok, []}, fn dep, {:ok, acc} ->
      case Map.fetch(host.apps, dep.app) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, _version} ->
          case Map.get(host.app_paths, dep.app) do
            source when not is_nil(source) ->
              {:cont, {:ok, [{dep, source} | acc]}}

            _ ->
              {:halt,
               {:error,
                "host application #{dep.app} has no reusable library path; a project-local copy will not be compiled"}}
          end
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp flatten_deps(deps) do
    Enum.flat_map(List.wrap(deps), fn
      %Mix.Dep{deps: nested} = dep -> [dep | flatten_deps(nested)]
      other -> [other]
    end)
  end

  @spec check_project(keyword(), t()) :: :ok | {:error, String.t()}
  def check_project(config, host \\ snapshot()) when is_list(config) do
    cond do
      config[:apps_path] ->
        {:error, "umbrella projects are not supported on this host"}

      native_compilers?(List.wrap(config[:compilers])) ->
        {:error,
         "project compilers #{inspect(config[:compilers])} need a native toolchain, which this host does not provide"}

      true ->
        check_app_conflict(config[:app], config[:version], host)
    end
  end

  @spec check_project_sources(Path.t(), t()) :: :ok | {:error, String.t()}
  def check_project_sources(project_path, host \\ snapshot()) do
    check_module_ownership("project", project_path, host)
  end

  @spec check_run_module(module(), Path.t(), t()) :: :ok | {:error, String.t()}
  def check_run_module(module, project_path, host) when is_atom(module) do
    cond do
      host_module?(module, host) ->
        {:error,
         "run module #{inspect(module)} belongs to the host and cannot be used as a workspace entry point"}

      module in project_modules(project_path, include_mix?: false) ->
        :ok

      true ->
        {:error, "run module #{inspect(module)} is not defined by this workspace project"}
    end
  end

  defp check_dep(%Mix.Dep{} = dep, host) do
    if host_native_reuse?(dep, host) do
      :ok
    else
      check_dep_sources(dep, host)
    end
  end

  defp check_dep_sources(%Mix.Dep{} = dep, host) do
    app = dep.app
    dest = dep.opts[:dest]

    with :ok <- check_manager(app, dep.manager),
         :ok <- check_compilers(app, List.wrap(dep.opts[:compilers])),
         :ok <- check_mix_exs(app, dest),
         :ok <- check_app_conflict(app, dep_version(dep), host),
         :ok <- check_native_tree(app, dest) do
      check_module_ownership("dependency #{app}", dest, host)
    end
  end

  defp check_manager(app, manager) when manager in [:rebar, :rebar3, :make] do
    {:error,
     "dependency #{app} uses #{manager}, which requires an external build tool this host does not provide"}
  end

  defp check_manager(_app, _manager), do: :ok

  defp check_compilers(app, compilers) do
    native = Enum.filter(compilers, &native_compiler?/1)
    extra = Enum.reject(compilers, &allowed_compiler?/1)

    cond do
      native != [] ->
        {:error,
         "dependency #{app} compilers #{inspect(native)} need a native toolchain, which this host does not provide"}

      extra != [] ->
        {:error, "dependency #{app} compilers #{inspect(extra)} are not supported on this host"}

      true ->
        :ok
    end
  end

  defp check_mix_exs(_app, dest) when dest in [nil, ""], do: :ok

  defp check_mix_exs(app, dest) do
    mix_exs = Path.join(dest, "mix.exs")

    case File.read(mix_exs) do
      {:ok, source} ->
        if Enum.any?(@native_mix_markers, &Regex.match?(&1, source)) do
          {:error,
           "dependency #{app} mix.exs requests a native or Rebar build this host does not provide"}
        else
          :ok
        end

      {:error, _} ->
        :ok
    end
  end

  defp check_app_conflict(nil, _version, _host), do: :ok

  defp check_app_conflict(app, version, %__MODULE__{} = host) do
    case host_app_vsn(app, host) do
      nil ->
        :ok

      host_vsn ->
        if compatible_versions?(host_vsn, version) do
          :ok
        else
          {:error,
           "dependency #{app} #{format_version(version)} conflicts with host application #{app} #{host_vsn}; the host copy will not be replaced"}
        end
    end
  end

  defp host_app_vsn(app, %__MODULE__{apps: apps}), do: Map.get(apps, app)

  defp host_native_reuse?(dep, host) do
    MapSet.member?(@host_native_apps, dep.app) and
      case host_app_vsn(dep.app, host) do
        nil ->
          false

        host_vsn ->
          compatible_versions?(host_vsn, dep_version(dep)) or
            host_requirement_ok?(host_vsn, dep.requirement)
      end
  end

  defp host_requirement_ok?(host_vsn, req) when is_binary(req) do
    case parse_version(host_vsn) do
      {:ok, version} -> Version.match?(version, req)
      :error -> false
    end
  rescue
    Version.InvalidRequirementError -> false
  end

  defp host_requirement_ok?(_host_vsn, _req), do: false

  defp check_native_tree(_app, dest) when dest in [nil, ""], do: :ok

  defp check_native_tree(app, dest) do
    case File.ls(dest) do
      {:ok, entries} ->
        hits = Enum.filter(entries, &MapSet.member?(@native_root_entries, &1))

        if hits == [] do
          :ok
        else
          {:error,
           "dependency #{app} contains #{Enum.join(hits, ", ")}, which needs a native or Rebar build this host does not provide"}
        end

      {:error, _} ->
        :ok
    end
  end

  defp check_module_ownership(_owner, dest, _host) when dest in [nil, ""], do: :ok

  defp check_module_ownership(owner, dest, %__MODULE__{} = host) do
    app = owner_app(owner)

    if app && Map.has_key?(host.apps, app) do
      :ok
    else
      collisions =
        dest
        |> project_modules()
        |> Enum.filter(&host_module?(&1, host))

      case collisions do
        [] ->
          :ok

        names ->
          shown = names |> Enum.take(8) |> Enum.map_join(", ", &inspect/1)

          {:error,
           "#{owner} redefines host modules (#{shown}); the host copy will not be replaced"}
      end
    end
  end

  defp owner_app("dependency " <> app) when is_binary(app) do
    case existing_app(app) do
      {:ok, app_atom} -> app_atom
      :error -> nil
    end
  end

  defp owner_app(_), do: nil

  defp existing_app(app) do
    case :erlang.binary_to_existing_atom(app, :utf8) do
      app_atom when is_atom(app_atom) -> {:ok, app_atom}
    end
  catch
    :error, :badarg -> :error
  end

  defp project_modules(dest, opts \\ []) do
    patterns = [Path.join(dest, "{lib,src}/**/*.{ex,erl}")]

    patterns =
      if Keyword.get(opts, :include_mix?, true),
        do: [Path.join(dest, "mix.exs") | patterns],
        else: patterns

    patterns
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.flat_map(&file_modules/1)
    |> Enum.uniq()
  end

  defp workspace_modules(project_path) do
    [project_path | Path.wildcard(Path.join(project_path, "deps/*"))]
    |> Enum.flat_map(&project_modules/1)
  end

  defp file_modules(path) do
    case Path.extname(path) do
      ".erl" -> erlang_file_modules(path)
      _ -> elixir_file_modules(path)
    end
  end

  defp elixir_file_modules(path) do
    with {:ok, source} <- File.read(path),
         {:ok, ast} <- Code.string_to_quoted(source, file: path) do
      {_ast, modules} =
        Macro.prewalk(ast, [], fn
          {:defmodule, _, [{:__aliases__, _, parts} | _]} = node, acc ->
            {node, [Module.concat(parts) | acc]}

          node, acc ->
            {node, acc}
        end)

      modules
    else
      _ -> []
    end
  end

  defp erlang_file_modules(path) do
    case :epp.parse_file(String.to_charlist(path), [], []) do
      {:ok, forms} ->
        for {:attribute, _line, :module, module} <- forms, do: module

      _ ->
        []
    end
  end

  defp host_module?(module, %__MODULE__{} = host) do
    MapSet.member?(host.modules, module) or host_code_path?(module, host.code_paths)
  end

  defp host_code_path?(module, code_paths) do
    case :code.which(module) do
      path when is_list(path) and path != [] ->
        path = path |> List.to_string() |> Path.expand()
        Enum.any?(code_paths, &path_within?(path, &1))

      _ ->
        false
    end
  end

  defp workspace_path?(path, roots) when is_list(path) and path != [] do
    expanded = path |> List.to_string() |> Path.expand()
    Enum.any?(roots, &path_within?(expanded, &1))
  end

  defp workspace_path?(_path, _roots), do: false

  defp path_within?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp host_app_source(app) do
    case :code.lib_dir(app) do
      path when is_list(path) -> List.to_string(path)
      _ -> flat_app_source(app)
    end
  end

  defp flat_app_source(app) do
    spec = Application.spec(app)

    beams =
      for module <- List.wrap(spec && spec[:modules]),
          path = :code.which(module),
          is_list(path) and path != [],
          do: {module, List.to_string(path)}

    if spec && beams != [], do: {:beams, beams, spec}
  end

  defp dep_version(%Mix.Dep{opts: opts} = dep) do
    lock_version(opts[:lock]) || status_version(dep.status) ||
      requirement_version(dep.requirement)
  end

  defp lock_version({:hex, _app, version, _checksum, _managers, _deps, _repo, _outer_checksum})
       when is_binary(version),
       do: version

  defp lock_version({:hex, _app, version, _checksum, _managers, _deps, _repo})
       when is_binary(version),
       do: version

  defp lock_version(_), do: nil

  defp status_version({:ok, vsn}) when is_binary(vsn), do: vsn
  defp status_version({:ok, vsn}) when is_list(vsn), do: List.to_string(vsn)
  defp status_version(_), do: nil

  defp requirement_version(req) when is_binary(req), do: req
  defp requirement_version(_), do: nil

  defp compatible_versions?(_host, nil), do: true

  defp compatible_versions?(host, required) do
    case parse_version(host) do
      {:ok, host_vsn} ->
        case parse_version(required) do
          {:ok, required_vsn} ->
            Version.compare(host_vsn, required_vsn) == :eq

          :error ->
            Version.match?(host_vsn, required)
        end

      :error ->
        host == required
    end
  end

  defp parse_version(value) when is_binary(value) do
    case Version.parse(value) do
      {:ok, version} -> {:ok, version}
      :error -> :error
    end
  end

  defp parse_version(_), do: :error

  defp format_version(version), do: to_string(version)

  defp native_compilers?(compilers), do: Enum.any?(compilers, &native_compiler?/1)
  defp native_compiler?(compiler), do: MapSet.member?(@native_compilers, compiler)
  defp allowed_compiler?(compiler), do: MapSet.member?(@allowed_compilers, compiler)
end
