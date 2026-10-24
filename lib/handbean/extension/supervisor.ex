defmodule Handbean.Extension.Supervisor do
  @moduledoc """
  Dynamic supervisor for long-lived processes started by loaded extensions.

  Modules compiled from an extension `entry` that export `child_spec/1`
  are started here. Entry source generations use distinct module identities,
  so a successful source change starts the candidate worker before retiring
  the previous generation. An unchanged source keeps its pid. A failed compile
  must not call this with an empty module list.
  """

  use DynamicSupervisor

  require Logger

  defmodule WorkerContainer do
    @moduledoc false
    use Supervisor

    def start_link(worker_spec), do: Supervisor.start_link(__MODULE__, worker_spec)

    @impl true
    def init(worker_spec), do: Supervisor.init([worker_spec], strategy: :one_for_one)

    def worker_pid(container) do
      container
      |> Supervisor.which_children()
      |> Enum.find_value(fn
        {_id, pid, _type, _modules} when is_pid(pid) -> pid
        _ -> nil
      end)
    catch
      :exit, _ -> nil
    end
  end

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    case :ets.whereis(__MODULE__) do
      :undefined ->
        :ets.new(__MODULE__, [:named_table, :public, :set, read_concurrency: true])

      _tid ->
        :ok
    end

    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @type worker_change :: %{
          owner: term(),
          keep: [{module(), pid()}],
          drop: [{module(), pid()}],
          started: [{module(), pid()}]
        }

  @doc "Start candidate workers without retiring the owner's current workers."
  @spec prepare_workers(term(), [module()]) :: {:ok, worker_change()} | {:error, term()}
  def prepare_workers(owner, modules) when is_list(modules) do
    if Process.whereis(__MODULE__) do
      owner = normalize_owner(owner)

      wanted =
        modules
        |> Enum.filter(&function_exported?(&1, :child_spec, 1))
        |> Enum.uniq()

      current = entries_for(owner)

      {keep, drop} =
        Enum.split_with(current, fn {mod, container} ->
          Process.alive?(container) and mod in wanted
        end)

      kept_mods = MapSet.new(keep, &elem(&1, 0))
      missing = Enum.reject(wanted, &MapSet.member?(kept_mods, &1))

      case start_all(missing, []) do
        {:ok, started} ->
          {:ok, %{owner: owner, keep: keep, drop: drop, started: started}}

        {:error, reason, started} ->
          terminate_entries(started)
          {:error, {:worker_start_failed, reason}}
      end
    else
      {:ok, %{owner: normalize_owner(owner), keep: [], drop: [], started: []}}
    end
  end

  @doc "Finalize a prepared worker change after the other runtime registries commit."
  @spec commit_workers(worker_change()) :: :ok
  def commit_workers(%{owner: owner, keep: keep, drop: drop, started: started}) do
    terminate_entries(drop)
    put_entries(owner, keep ++ started)
    :ok
  end

  @doc "Stop only workers started by a prepared change, preserving the old owner state."
  @spec abort_workers(worker_change()) :: :ok
  def abort_workers(%{started: started}) do
    terminate_entries(started)
    :ok
  end

  @doc """
  Reconcile workers for `ext_name` with the modules from a successful compile.

  Alive workers whose module is still listed are kept. Missing `child_spec/1`
  modules are started. Modules no longer present are terminated.
  """
  @spec replace_workers(term(), [module()]) :: :ok | {:error, term()}
  @spec replace_workers(term(), [module()], keyword()) :: :ok | {:error, term()}
  def replace_workers(owner, modules, opts \\ []) when is_list(modules) do
    if Process.whereis(__MODULE__) do
      do_sync(normalize_owner(owner), modules, Keyword.get(opts, :restart, false))
    else
      :ok
    end
  end

  @spec workers(term()) :: [pid()]
  def workers(owner) do
    owner
    |> lookup_owner()
    |> entries_for()
    |> Enum.filter(fn {_mod, container} -> Process.alive?(container) end)
    |> Enum.map(fn {_mod, container} -> WorkerContainer.worker_pid(container) end)
    |> Enum.filter(&is_pid/1)
  end

  @doc "Return alive worker modules currently owned by an extension or mount."
  @spec worker_modules(term()) :: [module()]
  def worker_modules(owner) do
    owner
    |> lookup_owner()
    |> entries_for()
    |> Enum.filter(fn {_mod, container} -> Process.alive?(container) end)
    |> Enum.map(&elem(&1, 0))
  end

  defp do_sync(owner, modules, restart?) do
    wanted =
      modules
      |> Enum.filter(&function_exported?(&1, :child_spec, 1))
      |> Enum.uniq()

    current = entries_for(owner)

    if restart? do
      restart_workers(owner, wanted, current)
    else
      reconcile_workers(owner, wanted, current)
    end
  end

  defp reconcile_workers(owner, wanted, _current) do
    case prepare_workers(owner, wanted) do
      {:ok, change} -> commit_workers(change)
      {:error, _} = error -> error
    end
  end

  defp restart_workers(owner, wanted, current) do
    terminate_entries(current)

    case start_all(wanted, []) do
      {:ok, started} ->
        put_entries(owner, started)
        :ok

      {:error, reason, started} ->
        terminate_entries(started)
        put_entries(owner, [])
        {:error, {:worker_start_failed, reason}}
    end
  end

  defp start_all([], started), do: {:ok, Enum.reverse(started)}

  defp start_all([mod | rest], started) do
    case start_one(mod) do
      {:ok, entry} -> start_all(rest, [entry | started])
      {:error, reason} -> {:error, {mod, reason}, started}
    end
  end

  defp terminate_entries(entries) do
    Enum.each(entries, fn {_mod, container} ->
      if Process.alive?(container), do: DynamicSupervisor.terminate_child(__MODULE__, container)
    end)
  end

  defp start_one(mod) do
    worker_spec = Supervisor.child_spec(mod.child_spec([]), restart: :permanent)

    container_spec = %{
      id: {WorkerContainer, make_ref()},
      start: {WorkerContainer, :start_link, [worker_spec]},
      restart: :temporary,
      type: :supervisor
    }

    case DynamicSupervisor.start_child(__MODULE__, container_spec) do
      {:ok, container} ->
        {:ok, {mod, container}}

      {:ok, container, _info} ->
        {:ok, {mod, container}}

      {:error, reason} ->
        reason = normalize_start_error(reason)

        Logger.warning(
          "[Extension.Supervisor] failed to start #{inspect(mod)}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  rescue
    exception ->
      Logger.warning(
        "[Extension.Supervisor] invalid child spec for #{inspect(mod)}: #{Exception.message(exception)}"
      )

      {:error, {:invalid_child_spec, Exception.message(exception)}}
  end

  defp normalize_start_error({:shutdown, {:failed_to_start_child, _id, reason}}),
    do: normalize_start_error(reason)

  defp normalize_start_error(reason), do: reason

  defp normalize_owner(owner) when is_binary(owner), do: {:extension, owner}
  defp normalize_owner(owner), do: owner

  defp lookup_owner(owner) when is_binary(owner) do
    candidates = [owner, {:extension, owner}, {:mount, owner}]

    Enum.find(candidates, owner, fn candidate -> entries_for(candidate) != [] end)
  end

  defp lookup_owner(owner), do: owner

  defp entries_for(owner) do
    case :ets.whereis(__MODULE__) do
      :undefined ->
        []

      _tid ->
        case :ets.lookup(__MODULE__, owner) do
          [{^owner, entries}] -> normalize_entries(entries)
          [] -> []
        end
    end
  end

  defp normalize_entries(entries) do
    Enum.flat_map(List.wrap(entries), fn
      {mod, pid} when is_atom(mod) and is_pid(pid) -> [{mod, pid}]
      pid when is_pid(pid) -> []
      _ -> []
    end)
  end

  defp put_entries(ext_name, entries) do
    case :ets.whereis(__MODULE__) do
      :undefined -> :ok
      _tid -> :ets.insert(__MODULE__, {ext_name, entries})
    end
  end
end
