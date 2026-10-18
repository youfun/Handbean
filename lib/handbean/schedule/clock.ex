defmodule Handbean.Schedule.Clock do
  @moduledoc """
  Application-wide single writer for due schedules.

  It claims slots and hands them to `Dispatch`. It does not run the model,
  and it does not decide that a timer firing means the slot is due.
  """

  use GenServer

  alias Handbean.Schedule.{Dispatch, Notice, Store}

  @busy_retry_ms 1_000
  @max_delay 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec tick(DateTime.t() | nil) :: :ok
  def tick(now \\ nil) do
    GenServer.call(__MODULE__, {:tick, now || Handbean.Schedule.now()})
  end

  @spec recover(DateTime.t() | nil) :: :ok
  def recover(now \\ nil) do
    GenServer.call(__MODULE__, {:recover, now || Handbean.Schedule.now()})
  end

  @impl true
  def init(_opts) do
    state = %{timer: nil, busy_retries: %{}}

    state =
      if enabled?() do
        now = Handbean.Schedule.now()
        recover_unknown(now)
        schedule(state, now)
      else
        state
      end

    {:ok, state}
  end

  @impl true
  def handle_call({:tick, now}, _from, state) do
    cancel(state.timer)
    recover_unknown(now)
    busy_retries = dispatch_due(now, state.busy_retries)

    state = %{state | busy_retries: busy_retries}
    {:reply, :ok, schedule(state, now)}
  end

  def handle_call({:recover, now}, _from, state) do
    recover_unknown(now)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    cancel(state.timer)
    now = Handbean.Schedule.now()
    recover_unknown(now)
    busy_retries = dispatch_due(now, state.busy_retries)

    state = %{state | timer: nil, busy_retries: busy_retries}
    {:noreply, schedule(state, now)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp dispatch_due(now, busy_retries) do
    if Handbean.Storage.Health.writable?() do
      due = Store.due(now)
      monotonic_now = System.monotonic_time(:millisecond)

      busy_retries =
        Map.take(busy_retries, Enum.map(due, & &1.id))

      Enum.reduce(due, busy_retries, fn entry, retries ->
        if dispatch_retry_pending?(retries, entry, monotonic_now, now) do
          retries
        else
          result =
            if Handbean.Schedule.Rule.once?(entry.rule) do
              dispatch_once(entry, now)
            else
              claim_and_handoff(entry, now)
            end

          update_retry(retries, entry.id, result)
        end
      end)
    else
      busy_retries
    end
  end

  defp dispatch_once(entry, now) do
    case Handbean.Schedule.Rule.busy_deadline(entry.rule) do
      {:ok, deadline} ->
        busy? = Dispatch.busy?(entry.conversation_id)

        cond do
          busy? and DateTime.compare(now, deadline) == :lt ->
            {:retry, busy_retry_not_before(now, deadline)}

          busy? ->
            case Store.give_up(entry, now) do
              {:ok, %{schedule: schedule, run: run}} -> Notice.skip(schedule, run, "busy")
              _ -> :ok
            end

          true ->
            claim_and_handoff(entry, now)
        end

      :error ->
        claim_and_handoff(entry, now)
    end
  end

  defp busy_retry_not_before(now, deadline) do
    remaining_ms =
      deadline
      |> DateTime.diff(now, :millisecond)
      |> max(1)
      |> min(@busy_retry_ms)

    System.monotonic_time(:millisecond) + remaining_ms
  end

  defp dispatch_retry_pending?(retries, entry, monotonic_now, now) do
    retry_pending?(retries, entry.id, monotonic_now) and before_busy_deadline?(entry, now)
  end

  defp before_busy_deadline?(entry, now) do
    case Handbean.Schedule.Rule.busy_deadline(entry.rule) do
      {:ok, deadline} -> DateTime.compare(now, deadline) == :lt
      :error -> false
    end
  end

  defp retry_pending?(retries, id, monotonic_now) do
    case Map.get(retries, id) do
      not_before when is_integer(not_before) -> not_before > monotonic_now
      _ -> false
    end
  end

  defp update_retry(retries, id, {:retry, retry_not_before}),
    do: Map.put(retries, id, retry_not_before)

  defp update_retry(retries, id, _result), do: Map.delete(retries, id)

  defp claim_and_handoff(entry, now) do
    case Store.claim(entry, now) do
      {:ok, claim} -> handoff(claim)
      {:error, _reason} -> :ok
    end
  end

  defp handoff(claim) do
    if Application.get_env(:handbean, :schedule_dispatch, :async) == :sync do
      Dispatch.run(claim)
    else
      Task.Supervisor.start_child(Handbean.AgentRunTaskSupervisor, fn ->
        Dispatch.run(claim)
      end)
    end
  end

  defp recover_unknown(now) do
    if tables_ready?() do
      Store.recover_unknown(now, &run_present?/2)
      |> notify_unknown()
    else
      :ok
    end
  end

  defp notify_unknown(runs) do
    Enum.each(runs, fn run ->
      case Store.get(run.schedule_id) do
        {:ok, schedule} -> Notice.unknown(schedule, run)
        _ -> :ok
      end
    end)
  end

  defp run_present?(conversation_id, run_id) do
    registry_alive?(conversation_id, run_id) or session_running?(conversation_id, run_id)
  end

  defp registry_alive?(conversation_id, run_id) do
    case Registry.lookup(Handbean.AgentRunRegistry, conversation_id) do
      [{pid, %{run_id: ^run_id, active?: true}}] -> Process.alive?(pid)
      [{pid, %{run_id: ^run_id}}] -> Process.alive?(pid)
      _ -> false
    end
  end

  defp session_running?(conversation_id, run_id) do
    case Handbean.Agent.Coordinator.status(conversation_id) do
      {:ok, %{running?: true, run_id: ^run_id}} -> true
      _ -> false
    end
  end

  defp schedule(state, now) do
    if enabled?() and Handbean.Storage.Health.writable?() and tables_ready?() do
      %{state | timer: Process.send_after(self(), :tick, delay(state.busy_retries, now))}
    else
      %{state | timer: nil}
    end
  end

  defp delay(busy_retries, now) do
    monotonic_now = System.monotonic_time(:millisecond)

    persistent_delay =
      now
      |> DateTime.add(@max_delay, :millisecond)
      |> Store.due()
      |> Enum.reject(&retry_pending?(busy_retries, &1.id, monotonic_now))
      |> Enum.map(&persistent_delay(&1.next_run_at, now))
      |> Enum.min(fn -> @max_delay end)

    min(persistent_delay, busy_retry_delay(busy_retries, monotonic_now))
  end

  defp persistent_delay(next_run_at, now) do
    diff = DateTime.diff(next_run_at, now, :millisecond)

    if DateTime.compare(next_run_at, now) == :gt do
      max(diff, 1)
    else
      max(diff, 0)
    end
  end

  defp busy_retry_delay(busy_retries, monotonic_now) do
    busy_retries
    |> Map.values()
    |> Enum.map(&max(&1 - monotonic_now, 0))
    |> Enum.min(fn -> @max_delay end)
  end

  defp cancel(ref) when is_reference(ref) do
    if Process.cancel_timer(ref) == false do
      receive do
        :tick -> :ok
      after
        0 -> :ok
      end
    else
      :ok
    end
  end

  defp cancel(_), do: :ok

  defp enabled? do
    Application.get_env(:handbean, :schedule_clock, enabled: true)[:enabled] != false
  end

  # A fresh install starts this process before migrations. Missing either
  # table is not a failed recovery; delay/0 also reads schedules.
  defp tables_ready? do
    query =
      "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name IN ('schedules', 'schedule_runs')"

    case Handbean.Repo.query(query) do
      {:ok, %{rows: [[2]]}} -> true
      _ -> false
    end
  rescue
    _ -> false
  end
end
