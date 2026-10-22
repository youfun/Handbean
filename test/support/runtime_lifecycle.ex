defmodule Handbean.TestSupport.RuntimeLifecycle do
  @moduledoc false

  import ExUnit.Assertions, only: [flunk: 1]

  alias Handbean.Agent.Coordinator

  @default_timeout_ms 10_000
  @runtime_observers [Handbean.Runtime.TaskTracker, Handbean.Schedule.Recorder]

  def stop_run!(conversation_id, timeout_ms \\ @default_timeout_ms)
      when is_binary(conversation_id) do
    deadline = deadline(timeout_ms)

    case Coordinator.status(conversation_id) do
      {:ok, %{run_pid: run_pid} = status} when is_pid(run_pid) ->
        processes =
          [{"Runner", run_pid}, {"run supervisor", Map.get(status, :run_supervisor)}]
          |> Enum.filter(fn {_label, pid} -> is_pid(pid) end)
          |> Enum.uniq_by(&elem(&1, 1))

        monitors = Enum.map(processes, fn {label, pid} -> {label, pid, Process.monitor(pid)} end)
        _ = Coordinator.cancel(conversation_id)

        Enum.each(monitors, fn {label, pid, ref} ->
          await_down!(pid, ref, deadline, label)
        end)

      _ ->
        :ok
    end
  end

  def drain_terminal_callbacks!(timeout_ms \\ @default_timeout_ms) do
    await_terminal_callbacks(deadline(timeout_ms))
  end

  def sync_runtime_observers! do
    Enum.each(@runtime_observers, fn name ->
      if pid = Process.whereis(name), do: :sys.get_state(pid)
    end)
  end

  defp await_terminal_callbacks(deadline) do
    tasks =
      if Process.whereis(Handbean.AgentRunTaskSupervisor) do
        Task.Supervisor.children(Handbean.AgentRunTaskSupervisor)
      else
        []
      end

    Enum.each(tasks, fn pid ->
      ref = Process.monitor(pid)
      await_down!(pid, ref, deadline, "terminal callback")
    end)

    if tasks == [], do: :ok, else: await_terminal_callbacks(deadline)
  end

  defp await_down!(pid, ref, deadline, label) do
    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} ->
        :ok
    after
      remaining_ms(deadline) ->
        Process.demonitor(ref, [:flush])
        flunk("#{label} did not stop before teardown: #{inspect(pid)}")
    end
  end

  defp deadline(timeout_ms), do: System.monotonic_time(:millisecond) + timeout_ms
  defp remaining_ms(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
