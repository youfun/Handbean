defmodule Handbean.StorageLock do
  @moduledoc """
  Holds the single-runtime native lock for the configured Handbean database.

  The sidecar belongs to the resolved database path, not to its parent data
  directory, so another independent SQLite database in the same host container
  does not share this ownership boundary.
  """

  use GenServer

  @name __MODULE__
  @max_symlink_hops 40

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  @doc false
  def lock_path(database_path), do: canonical_path(database_path) <> ".lock"

  @doc false
  def canonical_path(path) when is_binary(path) do
    {resolved, _remaining_hops} =
      path
      |> Path.expand()
      |> canonical_path(@max_symlink_hops)

    resolved
  end

  @impl true
  def init(opts) do
    database_path = Keyword.get_lazy(opts, :database, &Handbean.Repo.database_path/0)
    lock_path = lock_path(database_path)

    with :ok <- File.mkdir_p(Path.dirname(lock_path)),
         {:ok, resource} <- :handbean_storage.lock(lock_path) do
      {:ok, %{resource: resource}}
    else
      {:error, :locked} -> {:stop, :database_locked}
      {:error, reason} -> {:stop, {:database_lock_failed, reason}}
    end
  end

  @impl true
  def terminate(_reason, %{resource: resource}) do
    :handbean_storage.close(resource)
    :ok
  end

  defp canonical_path(path, remaining_hops) do
    path
    |> Path.split()
    |> Enum.reduce({nil, remaining_hops}, fn component, {resolved_parent, hops_left} ->
      resolve_path_component(component, resolved_parent, hops_left)
    end)
  end

  defp resolve_path_component(component, nil, remaining_hops),
    do: {component, remaining_hops}

  defp resolve_path_component(component, resolved_parent, 0),
    do: {Path.join(resolved_parent, component), 0}

  defp resolve_path_component(component, resolved_parent, remaining_hops) do
    candidate = Path.join(resolved_parent, component)

    case :file.read_link_all(String.to_charlist(candidate)) do
      {:ok, target} ->
        target
        |> List.to_string()
        |> Path.expand(Path.dirname(candidate))
        |> canonical_path(remaining_hops - 1)

      {:error, _reason} ->
        {candidate, remaining_hops}
    end
  end
end
