defmodule Handbean.Jobs.BeamCleanup do
  @moduledoc """
  Cleanup ledger independent of the temporary job owner and Jobs.Server.
  Tracks locally spawned descendants and drains them before reporting completion.
  Mix work still belongs to MixOwner; its caller-scoped cancellation is a restore fence.
  This is not isolation from malicious code, existing processes, native code or OS work.
  """
  use GenServer, restart: :temporary

  # Deliberately unlinked: an untrappable owner exit must not destroy the ledger.
  # Both owner and Server are monitored; either exit drains this process's work.
  def start(opts), do: GenServer.start(__MODULE__, opts)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    owner = self()
    server = opts[:server]
    id = opts[:id]

    worker =
      spawn_link(fn ->
        worker = self()

        spawn_link(fn ->
          ref = Process.monitor(owner)

          receive do
            {:DOWN, ^ref, :process, ^owner, _} -> Process.exit(worker, :kill)
          end
        end)

        receive do
          :go ->
            sink = fn text -> GenServer.call(server, {:beam_output, id, text}) end
            result = opts[:fun].(sink)
            send(owner, {:result, result})
            receive do: (:release -> :ok)
        end
      end)

    :erlang.trace(worker, true, [:procs, :set_on_spawn, {:tracer, self()}])

    {:ok,
     %{
       server: server,
       server_ref: Process.monitor(server),
       owner_ref: Process.monitor(opts[:owner]),
       id: id,
       kind: opts[:kind],
       worker: worker,
       managed: %{worker => Process.monitor(worker)},
       closing?: false,
       result: {:error, "BEAM worker stopped without a result"},
       barrier: nil
     }}
  end

  @impl true
  def handle_cast(:go, state) do
    if not state.closing?, do: send(state.worker, :go)
    {:noreply, state}
  end

  def handle_cast(:cancel, state), do: drain(close(state))

  @impl true
  def handle_info({:result, result}, state), do: drain(close(%{state | result: result}))

  def handle_info({:DOWN, ref, :process, _, _}, %{server_ref: ref} = state),
    do: drain(close(state))

  def handle_info({:DOWN, ref, :process, _, _}, %{owner_ref: ref} = state),
    do: drain(close(state))

  def handle_info({:DOWN, ref, :process, pid, _}, state) do
    state =
      if state.managed[pid] == ref,
        do: %{state | managed: Map.delete(state.managed, pid)},
        else: state

    state = if pid == state.worker, do: close(state), else: state
    drain(state)
  end

  def handle_info({:trace, _, :spawn, child, _}, state) do
    state =
      if Map.has_key?(state.managed, child),
        do: state,
        else: %{state | managed: Map.put(state.managed, child, Process.monitor(child))}

    if state.closing?, do: Process.exit(child, :kill)
    {:noreply, state}
  end

  def handle_info({:trace_delivered, :all, ref}, %{barrier: ref} = state) do
    if map_size(state.managed) == 0 do
      # The dead caller cannot submit fresh Mix work. The fence waits for any
      # accepted operation to restore VM state, without cancelling another caller.
      if state.kind == :mix, do: :ok = Handbean.Workspace.MixOwner.cancel_for(state.worker)
      send(state.server, {:beam_finished, state.id, state.result})
      {:stop, :normal, state}
    else
      {:noreply, %{state | barrier: nil}}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    Enum.each(Map.keys(state.managed), &Process.exit(&1, :kill))
  end

  defp close(%{closing?: true} = state), do: state

  defp close(state) do
    Enum.each(Map.keys(state.managed), &Process.exit(&1, :kill))
    %{state | closing?: true}
  end

  defp drain(%{closing?: true, managed: managed, barrier: nil} = state)
       when map_size(managed) == 0,
       do: {:noreply, %{state | barrier: :erlang.trace_delivered(:all)}}

  defp drain(state), do: {:noreply, state}
end
