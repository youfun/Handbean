defmodule Handbean.Platform.ProcessRunner.OwnerWatch do
  @moduledoc """
  Supervised watcher for OS processes owned by a BEAM pid.

  Tracking is not atomic with `Port.open`. `ProcessRunner` inserts the
  invocation immediately after open and rechecks the owner; this process
  cleans up if the owner exits after that insert. A death in the open-to-insert
  gap is handled by that recheck, not by this watcher.
  """

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def watch(owner) when is_pid(owner) do
    GenServer.cast(__MODULE__, {:watch, owner})
  end

  @impl true
  def init(_opts) do
    table =
      case :ets.whereis(:handbean_owned_os) do
        :undefined -> :ets.new(:handbean_owned_os, [:named_table, :public, :bag])
        tid -> tid
      end

    {:ok, %{table: table}}
  end

  @impl true
  def handle_cast({:watch, owner}, state) do
    Process.monitor(owner)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, owner, _reason}, state) do
    Handbean.Platform.ProcessRunner.cleanup_owner(owner)
    {:noreply, state}
  end
end
