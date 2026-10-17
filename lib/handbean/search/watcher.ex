defmodule Handbean.Search.Watcher do
  @moduledoc """
  Maintains workspace search inventories from debounced filesystem events.

  Inventory and Git updates are asynchronous. File-system watcher processes are
  monitored rather than linked so one native watcher cannot terminate all
  workspace watches.
  """

  use GenServer

  require Logger

  @debounce_ms 150
  @restart_delay_ms 1_000
  @ignore_files [".gitignore", ".handbeanignore"]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def watch(workspace, index) when is_binary(workspace) and is_pid(index) do
    cast_if_running({:watch, Path.expand(workspace), index})
  end

  def notify_path(workspace, path) when is_binary(workspace) and is_binary(path) do
    cast_if_running({:path_changed, Path.expand(workspace), Path.expand(path)})
  end

  @impl true
  def init(_opts), do: {:ok, %{workspaces: %{}, watchers: %{}, monitors: %{}}}

  @impl true
  def handle_cast({:watch, workspace, index}, state) do
    case state.workspaces do
      %{^workspace => %{index: ^index}} ->
        {:noreply, request_git_refresh(state, workspace)}

      %{^workspace => _entry} ->
        state = remove_workspace(state, workspace)
        {:noreply, add_workspace(state, workspace, index)}

      _ ->
        {:noreply, add_workspace(state, workspace, index)}
    end
  end

  def handle_cast({:path_changed, workspace, path}, state) do
    case state.workspaces do
      %{^workspace => entry} ->
        state =
          cond do
            ignore_file?(path) ->
              backend().refresh(entry.index)
              request_git_refresh(state, workspace)

            ignored_event?(workspace, path) ->
              state

            true ->
              backend().update_paths(entry.index, [path])
              request_git_refresh(state, workspace)
          end

        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:file_event, watcher, {path, _events}}, state) when is_binary(path) do
    case Map.get(state.watchers, watcher) do
      nil -> {:noreply, state}
      workspace -> {:noreply, queue_path(state, workspace, path)}
    end
  end

  def handle_info({:file_event, watcher, :stop}, state) do
    case Map.get(state.watchers, watcher) do
      nil -> {:noreply, state}
      workspace -> {:noreply, watcher_stopped(state, workspace, watcher)}
    end
  end

  def handle_info({:flush, workspace}, state) do
    case state.workspaces do
      %{^workspace => entry} ->
        if entry.refresh? do
          backend().refresh(entry.index)
        else
          backend().update_paths(entry.index, MapSet.to_list(entry.pending))
        end

        updated = %{entry | pending: MapSet.new(), timer: nil, refresh?: false}
        state = put_in(state.workspaces[workspace], updated)
        {:noreply, request_git_refresh(state, workspace)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:restart_watcher, workspace}, state) do
    case state.workspaces do
      %{^workspace => %{watcher: nil, index: index} = entry} ->
        if Process.alive?(index) do
          {watcher, monitor, state} = start_watcher(workspace, state)
          updated = %{entry | watcher: watcher, watcher_monitor: monitor}
          state = put_in(state.workspaces[workspace], updated)
          {:noreply, maybe_restart_watcher(state, workspace, watcher)}
        else
          {:noreply, remove_workspace(state, workspace)}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:git_status_ready, workspace, index, pid, entries}, state) do
    case state.workspaces do
      %{^workspace => %{index: ^index, git_pid: ^pid} = entry} ->
        Process.demonitor(entry.git_monitor, [:flush])
        backend().set_git_status(index, entries)

        monitors = Map.delete(state.monitors, entry.git_monitor)
        updated = %{entry | git_pid: nil, git_monitor: nil, git_dirty?: false}
        state = %{put_in(state.workspaces[workspace], updated) | monitors: monitors}

        state = if entry.git_dirty?, do: request_git_refresh(state, workspace), else: state
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, pid, _reason}, state) do
    case Map.pop(state.monitors, monitor) do
      {nil, _monitors} ->
        {:noreply, state}

      {{:index, workspace}, monitors} ->
        {:noreply, remove_workspace(%{state | monitors: monitors}, workspace)}

      {{:watcher, workspace}, monitors} ->
        state = %{state | monitors: monitors, watchers: Map.delete(state.watchers, pid)}
        {:noreply, watcher_stopped(state, workspace, pid)}

      {{:git, workspace}, monitors} ->
        state = %{state | monitors: monitors}

        case state.workspaces do
          %{^workspace => %{git_pid: ^pid} = entry} ->
            rerun? = entry.git_dirty?
            updated = %{entry | git_pid: nil, git_monitor: nil, git_dirty?: false}
            state = put_in(state.workspaces[workspace], updated)
            {:noreply, if(rerun?, do: request_git_refresh(state, workspace), else: state)}

          _ ->
            {:noreply, state}
        end
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp add_workspace(state, workspace, index) do
    {watcher, watcher_monitor, state} = start_watcher(workspace, state)
    index_monitor = Process.monitor(index)

    entry = %{
      index: index,
      index_monitor: index_monitor,
      watcher: watcher,
      watcher_monitor: watcher_monitor,
      pending: MapSet.new(),
      timer: nil,
      refresh?: false,
      git_pid: nil,
      git_monitor: nil,
      git_dirty?: false
    }

    state = %{
      state
      | workspaces: Map.put(state.workspaces, workspace, entry),
        monitors: Map.put(state.monitors, index_monitor, {:index, workspace})
    }

    state
    |> maybe_restart_watcher(workspace, watcher)
    |> request_git_refresh(workspace)
  end

  defp remove_workspace(state, workspace) do
    case Map.pop(state.workspaces, workspace) do
      {nil, _workspaces} ->
        state

      {entry, workspaces} ->
        if is_reference(entry.timer), do: Process.cancel_timer(entry.timer)
        demonitor(entry.index_monitor)
        demonitor(entry.watcher_monitor)
        demonitor(entry.git_monitor)

        if is_pid(entry.watcher) and Process.alive?(entry.watcher) do
          GenServer.stop(entry.watcher, :normal)
        end

        if is_pid(entry.git_pid) and Process.alive?(entry.git_pid),
          do: Process.exit(entry.git_pid, :kill)

        monitor_refs = [entry.index_monitor, entry.watcher_monitor, entry.git_monitor]
        monitors = Map.drop(state.monitors, Enum.reject(monitor_refs, &is_nil/1))

        watchers =
          if is_pid(entry.watcher),
            do: Map.delete(state.watchers, entry.watcher),
            else: state.watchers

        %{state | workspaces: workspaces, watchers: watchers, monitors: monitors}
    end
  end

  defp start_watcher(workspace, state) do
    case FileSystem.start_link(dirs: [workspace]) do
      {:ok, pid} ->
        Process.unlink(pid)
        :ok = FileSystem.subscribe(pid)
        monitor = Process.monitor(pid)

        state = %{
          state
          | watchers: Map.put(state.watchers, pid, workspace),
            monitors: Map.put(state.monitors, monitor, {:watcher, workspace})
        }

        {pid, monitor, state}

      :ignore ->
        Logger.warning("[Search.Watcher] file watcher unavailable workspace=#{workspace}")
        {nil, nil, state}

      {:error, reason} ->
        Logger.warning(
          "[Search.Watcher] file watcher unavailable workspace=#{workspace} reason=#{inspect(reason)}"
        )

        {nil, nil, state}
    end
  end

  defp watcher_stopped(state, workspace, watcher) do
    case state.workspaces do
      %{^workspace => %{watcher: ^watcher} = entry} ->
        demonitor(entry.watcher_monitor)

        monitors =
          if entry.watcher_monitor,
            do: Map.delete(state.monitors, entry.watcher_monitor),
            else: state.monitors

        updated = %{entry | watcher: nil, watcher_monitor: nil}
        schedule_watcher_restart(workspace)

        %{
          put_in(state.workspaces[workspace], updated)
          | watchers: Map.delete(state.watchers, watcher),
            monitors: monitors
        }

      _ ->
        state
    end
  end

  defp maybe_restart_watcher(state, workspace, nil) do
    schedule_watcher_restart(workspace)
    state
  end

  defp maybe_restart_watcher(state, _workspace, _watcher), do: state

  defp schedule_watcher_restart(workspace) do
    Process.send_after(self(), {:restart_watcher, workspace}, @restart_delay_ms)
  end

  defp queue_path(state, workspace, path) do
    case state.workspaces do
      %{^workspace => entry} ->
        cond do
          ignore_file?(path) ->
            schedule_flush(state, workspace, %{entry | refresh?: true})

          ignored_event?(workspace, path) ->
            state

          true ->
            schedule_flush(state, workspace, %{entry | pending: MapSet.put(entry.pending, path)})
        end

      _ ->
        state
    end
  end

  defp schedule_flush(state, workspace, entry) do
    if is_reference(entry.timer), do: Process.cancel_timer(entry.timer)
    timer = Process.send_after(self(), {:flush, workspace}, @debounce_ms)
    put_in(state.workspaces[workspace], %{entry | timer: timer})
  end

  defp request_git_refresh(state, workspace) do
    case state.workspaces do
      %{^workspace => %{git_pid: pid} = entry} when is_pid(pid) ->
        put_in(state.workspaces[workspace], %{entry | git_dirty?: true})

      %{^workspace => entry} ->
        parent = self()
        index = entry.index

        {pid, monitor} =
          spawn_monitor(fn ->
            send(parent, {:git_status_ready, workspace, index, self(), git_status(workspace)})
          end)

        updated = %{entry | git_pid: pid, git_monitor: monitor, git_dirty?: false}

        %{
          put_in(state.workspaces[workspace], updated)
          | monitors: Map.put(state.monitors, monitor, {:git, workspace})
        }

      _ ->
        state
    end
  end

  defp ignored_event?(workspace, path) do
    backend = backend()
    function_exported?(backend, :ignored_path?, 2) and backend.ignored_path?(workspace, path)
  end

  defp ignore_file?(path), do: Path.basename(path) in @ignore_files

  defp demonitor(ref) when is_reference(ref), do: Process.demonitor(ref, [:flush])
  defp demonitor(_ref), do: :ok

  defp cast_if_running(message) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.cast(__MODULE__, message)
    end
  end

  defp git_status(workspace) do
    backend = Handbean.Git.backend()

    with true <- File.dir?(workspace),
         :ok <- backend.available(),
         {:ok, repo} <- backend.open(workspace, ceiling: Path.dirname(workspace)),
         {:ok, root} <- backend.workdir(repo),
         {:ok, %{entries: entries}} <- backend.status(repo) do
      entries
      |> Enum.flat_map(fn entry ->
        status =
          if entry.staged == nil and entry.unstaged == :new,
            do: :untracked,
            else: :modified

        [
          {Path.join(root, entry.path), status}
          | if(entry[:old_path], do: [{Path.join(root, entry.old_path), :modified}], else: [])
        ]
      end)
    else
      _ -> []
    end
  end

  defp backend do
    Application.get_env(:handbean, :search_backend, Handbean.Search.ExFffBackend)
  end
end
