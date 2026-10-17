defmodule Handbean.Extension.Supervisor do
  @moduledoc """
  Dynamic supervisor for long-lived processes started by loaded extensions.

  Modules compiled from an extension `entry` that export `child_spec/1`
  are started here. A later successful reload that still lists the same
  module keeps the pid (BEAM picks up new function clauses). Workers are
  stopped only when the module disappears from a successful compile, or
  when `restart: true` is passed. A failed compile must not call this
  with an empty module list.
  """

  use DynamicSupervisor

  require Logger

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

  @doc """
  Reconcile workers for `ext_name` with the modules from a successful compile.

  Alive workers whose module is still listed are kept. Missing `child_spec/1`
  modules are started. Modules no longer present are terminated.
  """
  @spec replace_workers(term(), [module()]) :: :ok
  @spec replace_workers(term(), [module()], keyword()) :: :ok
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
    |> Enum.filter(fn {_mod, pid} -> Process.alive?(pid) end)
    |> Enum.map(&elem(&1, 1))
  end

  defp do_sync(owner, modules, restart?) do
    wanted =
      modules
      |> Enum.filter(&function_exported?(&1, :child_spec, 1))
      |> Enum.uniq()

    current = entries_for(owner)

    {keep, drop} =
      Enum.split_with(current, fn {mod, pid} ->
        Process.alive?(pid) and mod in wanted and not restart?
      end)

    Enum.each(drop, fn {_mod, pid} ->
      _ = DynamicSupervisor.terminate_child(__MODULE__, pid)
    end)

    kept_mods = MapSet.new(keep, &elem(&1, 0))

    started =
      wanted
      |> Enum.reject(&MapSet.member?(kept_mods, &1))
      |> Enum.flat_map(&start_one/1)

    put_entries(owner, keep ++ started)
    :ok
  end

  defp start_one(mod) do
    spec = Supervisor.child_spec(mod.child_spec([]), restart: :permanent)

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, pid} ->
        [{mod, pid}]

      {:ok, pid, _info} ->
        [{mod, pid}]

      {:error, {:already_started, pid}} ->
        [{mod, pid}]

      {:error, reason} ->
        Logger.warning(
          "[Extension.Supervisor] failed to start #{inspect(mod)}: #{inspect(reason)}"
        )

        []
    end
  rescue
    exception ->
      Logger.warning(
        "[Extension.Supervisor] invalid child spec for #{inspect(mod)}: #{Exception.message(exception)}"
      )

      []
  end

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
