defmodule Handbean.Jobs.Beam do
  @moduledoc "Temporary job control process; cleanup ownership survives its exit."
  use GenServer, restart: :temporary

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def cancel(pid), do: GenServer.cast(pid, :cancel)

  @impl true
  def init(opts) do
    with {:ok, cleanup} <- Handbean.Jobs.BeamCleanup.start(Keyword.put(opts, :owner, self())) do
      {:ok, %{cleanup: cleanup, monitor: Process.monitor(cleanup)}}
    end
  end

  @impl true
  def handle_cast(message, state) when message in [:go, :cancel] do
    GenServer.cast(state.cleanup, message)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _, reason}, %{monitor: ref} = state) do
    {:stop, reason, state}
  end
end
