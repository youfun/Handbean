defmodule Handbean.Jobs.Cleaner do
  @moduledoc """
  Application-level cleanup ledger, independent of the job Port owner and run tree.
  Registration precedes releasing a shell's input gate. Owner death requests cleanup
  even when terminate/2 never ran. Failed cleanup remains registered and retries.
  """
  use GenServer

  alias Handbean.Platform.ProcessManager

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def register(id, group, owner, timeout \\ 5_000) do
    GenServer.call(__MODULE__, {:register, id, group, owner}, max(timeout, 1))
  catch
    :exit, _ -> {:error, "Cleanup registration unavailable or timed out"}
  end

  def cancel(id), do: GenServer.cast(__MODULE__, {:cancel, id})

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:register, _id, _group, _owner}, _from, entries)
      when map_size(entries) >= 256 do
    {:reply, {:error, "Cleanup ledger capacity exhausted"}, entries}
  end

  def handle_call({:register, id, group, owner}, _from, entries) do
    with {:ok, identity} <- ProcessManager.verify_job_group(group) do
      entry = %{group: identity, owner: owner, monitor: Process.monitor(owner), cleaning?: false}
      {:reply, {:ok, identity}, Map.put(entries, id, entry)}
    else
      error -> {:reply, error, entries}
    end
  end

  @impl true
  def handle_cast({:cancel, id}, entries) do
    {:noreply, request_cleanup(entries, id)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, entries) do
    entries =
      Enum.reduce(entries, entries, fn {id, entry}, acc ->
        if entry.monitor == ref, do: request_cleanup(acc, id), else: acc
      end)

    {:noreply, entries}
  end

  def handle_info({:clean, id}, entries) do
    case entries[id] do
      nil ->
        {:noreply, entries}

      entry ->
        case ProcessManager.cleanup_job_group(entry.group) do
          :ok ->
            send(entry.owner, {:job_cleanup, id, :ok})
            Process.demonitor(entry.monitor, [:flush])
            {:noreply, Map.delete(entries, id)}

          {:error, reason} ->
            send(entry.owner, {:job_cleanup, id, {:error, reason}})
            Process.send_after(self(), {:clean, id}, 1_000)
            {:noreply, entries}
        end
    end
  end

  defp request_cleanup(entries, id) do
    case entries[id] do
      %{cleaning?: false} = entry ->
        send(self(), {:clean, id})
        Map.put(entries, id, %{entry | cleaning?: true})

      _ ->
        entries
    end
  end
end
