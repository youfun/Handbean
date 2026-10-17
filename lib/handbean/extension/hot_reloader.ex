defmodule Handbean.Extension.HotReloader do
  @moduledoc """
  Reloads extension manifests and compiled entry modules in place.

  `reload/1` can be called explicitly. `start_link/1` watches
  `{project}/.handbean/extensions` and `{user_home}/.handbean/extensions`,
  debounces filesystem events, then reloads without stopping an
  active `RunSupervisor`.

  On start (when enabled) existing extensions are loaded once so a
  release or `mix phx.server` picks up plugins already on disk.

  `notify_path/1` lets `write`/`edit` trigger the same reload when the
  conversation workspace is not the process cwd (watcher only sees cwd
  and `~/.handbean/extensions`).
  """

  use GenServer

  require Logger

  alias Handbean.Agent.ExtensionBridge
  alias Handbean.Extension.Loader
  alias Handbean.Extension.Registry, as: ExtRegistry
  alias Handbean.ProjectTrust

  @default_debounce_ms 200

  @spec reload(keyword()) :: {:ok, [Handbean.Extension.Diagnostic.t()]}
  def reload(opts \\ []) do
    ext_registry = Keyword.get(opts, :ext_registry, ExtRegistry)
    :global.trans({__MODULE__, ext_registry}, fn -> reload_unlocked(opts) end)
  end

  defp reload_unlocked(opts) do
    project = trusted_project(opts)
    user_home = Keyword.get(opts, :user_home, default_user_home())
    ext_registry = Keyword.get(opts, :ext_registry, ExtRegistry)

    result = Loader.load(project: project, user_home: user_home)
    previous = ExtRegistry.list(ext_registry)

    integration_diagnostics =
      Enum.flat_map(result.extensions, fn ext ->
        case ExtensionBridge.prepare(ext) do
          {:ok, prepared} ->
            case ExtensionBridge.commit_prepared(prepared, ext_registry: ext_registry) do
              :ok -> prepared.diagnostics
              {:error, reason} -> prepared.diagnostics ++ [commit_diagnostic(ext, reason)]
            end

          {:error, diags} ->
            diags
        end
      end)

    removed_diagnostics =
      reconcile_removed(previous, result.extensions,
        project: project,
        user_home: user_home,
        ext_registry: ext_registry
      )

    {:ok, result.diagnostics ++ integration_diagnostics ++ removed_diagnostics}
  end

  @doc """
  Notify the default HotReloader that an extension path changed.

  Used by builtin `write`/`edit` so a plugin created in any workspace
  is compiled even when that workspace is not the server cwd.
  No-ops if the process is not running or is disabled.
  """
  @spec notify_path(String.t()) :: :ok
  def notify_path(path), do: notify_path(path, __MODULE__)

  @spec notify_path(String.t(), atom() | pid()) :: :ok
  def notify_path(path, server) when is_binary(path) do
    cond do
      is_pid(server) and Process.alive?(server) ->
        GenServer.cast(server, {:path_changed, path})

      is_atom(server) ->
        case Process.whereis(server) do
          nil -> :ok
          pid -> GenServer.cast(pid, {:path_changed, path})
        end

      true ->
        :ok
    end
  end

  def notify_path(_path, _server), do: :ok

  @doc """
  If `path` is under `{project}/.handbean/extensions`, return that project root.
  """
  @spec project_from_extension_path(String.t()) :: {:ok, String.t()} | :error
  def project_from_extension_path(path) when is_binary(path) do
    parts = path |> Path.expand() |> Path.split()

    case Enum.split_while(parts, &(&1 != ".handbean")) do
      {prefix, [".handbean", "extensions" | _rest]} when prefix != [] ->
        {:ok, Path.join(prefix)}

      _ ->
        :error
    end
  end

  def project_from_extension_path(_), do: :error

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    configured_project = Keyword.get(opts, :project, File.cwd!())
    project = trusted_project(opts)
    trust_opts = Keyword.take(opts, [:trusted_project?])
    user_home = Keyword.get(opts, :user_home, default_user_home())
    ext_registry = Keyword.get(opts, :ext_registry, ExtRegistry)
    debounce_ms = Keyword.get(opts, :debounce_ms, @default_debounce_ms)
    enabled? = Keyword.get(opts, :enabled, true)
    preload? = Keyword.get(opts, :preload, enabled?)

    watcher =
      if enabled? do
        dirs = ensure_watch_dirs(project, user_home)

        case start_watcher(dirs) do
          {:ok, pid} when is_pid(pid) ->
            _ = FileSystem.subscribe(pid)
            Logger.info("[HotReloader] watching #{inspect(dirs)}")
            pid

          {:error, reason} ->
            Logger.warning("[HotReloader] file watcher unavailable: #{inspect(reason)}")
            nil

          other ->
            Logger.warning("[HotReloader] file watcher unavailable: #{inspect(other)}")
            nil
        end
      else
        nil
      end

    if preload? do
      {elapsed_us, result} =
        :timer.tc(fn ->
          reload(
            [project: configured_project, user_home: user_home, ext_registry: ext_registry] ++
              trust_opts
          )
        end)

      log_reload_result(elapsed_us, result)
    end

    {:ok,
     %{
       project: project,
       configured_project: configured_project,
       trust_opts: trust_opts,
       user_home: user_home,
       ext_registry: ext_registry,
       debounce_ms: debounce_ms,
       enabled: enabled?,
       watcher: watcher,
       timer: nil,
       pending_project: nil
     }}
  end

  @impl true
  def handle_cast({:path_changed, _path}, %{enabled: false} = state) do
    {:noreply, state}
  end

  def handle_cast({:path_changed, path}, state) do
    with {:ok, discovered} <- project_from_extension_path(path),
         {:ok, reload_project} <- reload_project_for(path, discovered, state) do
      {:noreply, schedule_reload(%{state | pending_project: reload_project})}
    else
      :error -> {:noreply, state}
    end
  end

  @impl true
  def handle_info({:file_event, _watcher, {path, _events}}, state) do
    if extension_path?(path, state) do
      {:noreply, schedule_reload(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:file_event, _watcher, :stop}, state) do
    {:noreply, state}
  end

  def handle_info(:reload, state) do
    project = state.pending_project || state.project

    {elapsed_us, result} =
      :timer.tc(fn ->
        reload(
          [
            project: project,
            user_home: state.user_home,
            ext_registry: state.ext_registry
          ] ++ state.trust_opts
        )
      end)

    log_reload_result(elapsed_us, result)

    {:noreply, %{state | timer: nil, pending_project: nil}}
  end

  defp log_reload_result(elapsed_us, {:ok, diags}) do
    Logger.info(
      "[HotReloader] reloaded in #{div(elapsed_us, 1000)}ms (#{length(diags)} diagnostics)"
    )
  end

  defp log_reload_result(_elapsed_us, other) do
    Logger.warning("[HotReloader] reload failed: #{inspect(other)}")
  end

  defp schedule_reload(%{timer: timer, debounce_ms: debounce_ms} = state) do
    if is_reference(timer), do: Process.cancel_timer(timer)
    %{state | timer: Process.send_after(self(), :reload, debounce_ms)}
  end

  defp reload_project_for(path, discovered, state) do
    user_dir = Path.expand(Path.join(state.user_home, ".handbean/extensions"))
    expanded = Path.expand(path)

    cond do
      expanded == user_dir or String.starts_with?(expanded, user_dir <> "/") ->
        {:ok, state.configured_project}

      ProjectTrust.enabled?(state.trust_opts) ->
        {:ok, discovered}

      true ->
        :error
    end
  end

  defp trusted_project(opts) do
    if ProjectTrust.enabled?(opts),
      do: Keyword.get(opts, :project, File.cwd!()),
      else: nil
  end

  defp default_user_home, do: Handbean.Home.path()

  defp ensure_watch_dirs(project, user_home) do
    [
      project && Path.join(project, ".handbean/extensions"),
      Path.join(user_home, ".handbean/extensions")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn dir ->
      dir = Path.expand(dir, default_user_home())
      File.mkdir_p!(dir)
      dir
    end)
  end

  defp start_watcher([]), do: {:error, :no_dirs}

  defp start_watcher(dirs) do
    FileSystem.start_link(dirs: dirs)
  end

  defp extension_path?(path, state) do
    user_dir = Path.expand(Path.join(state.user_home, ".handbean/extensions"))
    expanded = Path.expand(path)

    project_path? =
      state.project &&
        String.starts_with?(
          expanded,
          Path.expand(Path.join(state.project, ".handbean/extensions"))
        )

    project_path? or String.starts_with?(expanded, user_dir)
  end

  defp commit_diagnostic(ext, reason) do
    %Handbean.Extension.Diagnostic{
      type: :warning,
      message: "Failed to commit extension #{ext.name}: #{inspect(reason)}"
    }
  end

  defp reconcile_removed(previous, loaded, opts) do
    project = Keyword.fetch!(opts, :project)
    user_home = Keyword.fetch!(opts, :user_home)
    ext_registry = Keyword.fetch!(opts, :ext_registry)
    loaded_names = MapSet.new(loaded, & &1.name)

    previous
    |> Enum.reject(&MapSet.member?(loaded_names, &1.name))
    |> Enum.filter(&removed_from_scanned_roots?(&1, project, user_home))
    |> Enum.flat_map(fn ext ->
      owner = {:extension, ext.name}
      _ = Handbean.Tool.Registry.remove_owner(owner)
      _ = Handbean.Extension.Supervisor.replace_workers(owner, [])
      :ok = ExtRegistry.unregister(ext_registry, ext.name)
      []
    end)
  end

  defp removed_from_scanned_roots?(ext, project, user_home) do
    root = Path.expand(ext.root)
    user_dir = Path.expand(Path.join(user_home, ".handbean/extensions"))

    roots =
      [project && Path.expand(Path.join(project, ".handbean/extensions")), user_dir]
      |> Enum.reject(&is_nil/1)

    under_root? =
      Enum.any?(roots, fn dir ->
        root == dir or String.starts_with?(root, dir <> "/")
      end)

    under_root? and
      not File.exists?(Path.join(root, "extension.json")) and
      not File.exists?(Path.join(root, "manifest.json"))
  end
end
