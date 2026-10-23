defmodule Handbean.WebPush.Dispatcher do
  @moduledoc "Bounded, best-effort delivery queue for normalized runtime notifications."

  use GenServer

  alias Handbean.WebPush
  alias Handbean.WebPush.Delivery

  require Logger

  @topic "runtime:web_push"
  @max_pending 100
  @max_age_ms 3_600_000
  @max_attempts 3

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc "Publish the lifecycle owner's decision, independently of native-host visibility."
  def broadcast(event) do
    Phoenix.PubSub.broadcast(Handbean.PubSub, @topic, {:web_push_event, event})
  end

  @impl true
  def init(opts) do
    enabled =
      Keyword.get(
        opts,
        :enabled,
        Application.get_env(:handbean, :web_push, [])[:dispatch] != false
      )

    if enabled, do: Phoenix.PubSub.subscribe(Handbean.PubSub, @topic)
    {:ok, %{pending: %{}, active: nil, timer: nil}}
  end

  @impl true
  def handle_info({:web_push_event, event}, state) do
    key = event_key(event)
    pending = Map.delete(state.pending, key)

    pending =
      if WebPush.configured?() and notifiable?(event) do
        if map_size(pending) < @max_pending do
          now = System.monotonic_time(:millisecond)

          Map.put(pending, key, %{
            event: event,
            token: make_ref(),
            created_at: now,
            ready_at: now,
            attempt: 1,
            subscriptions: nil
          })
        else
          Logger.warning("Web Push queue is full; notification skipped")
          pending
        end
      else
        pending
      end

    {:noreply, advance(%{state | pending: pending})}
  end

  def handle_info({ref, result}, %{active: %{task: %{ref: ref}} = active} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, state |> complete(active, result) |> advance()}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{active: %{task: %{ref: ref}} = active} = state
      ) do
    # A task crash is isolated from the runtime owner. Never log subscription data.
    Logger.warning("Web Push delivery worker stopped")
    {:noreply, state |> complete(active, :failed) |> advance()}
  end

  def handle_info(:dispatch, state), do: {:noreply, advance(%{state | timer: nil})}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{active: %{task: task}}), do: Task.shutdown(task, :brutal_kill)
  def terminate(_reason, _state), do: :ok

  defp advance(%{active: active} = state) when not is_nil(active), do: state

  defp advance(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    now = System.monotonic_time(:millisecond)
    pending = Map.reject(state.pending, fn {_key, job} -> now - job.created_at >= @max_age_ms end)
    state = %{state | pending: pending, timer: nil}

    case Enum.min_by(pending, fn {_key, job} -> job.ready_at end, fn -> nil end) do
      nil ->
        state

      {key, %{ready_at: ready_at} = job} when ready_at <= now ->
        task =
          Task.Supervisor.async_nolink(Handbean.WebPush.TaskSupervisor, fn ->
            Delivery.deliver(job.event, job.subscriptions)
          end)

        %{state | active: %{task: task, key: key, token: job.token}}

      {_key, job} ->
        %{state | timer: Process.send_after(self(), :dispatch, max(job.ready_at - now, 1))}
    end
  end

  defp complete(state, active, result) do
    :telemetry.execute([:handbean, :web_push, :delivery], %{attempts: 1}, %{})

    pending =
      case Map.get(state.pending, active.key) do
        %{token: token} = job when token == active.token ->
          retry_or_remove(state.pending, active.key, job, result)

        _ ->
          state.pending
      end

    %{state | active: nil, pending: pending}
  end

  defp retry_or_remove(pending, key, job, %{
         subscriptions: [_ | _] = subscriptions,
         retry_after: delay
       })
       when job.attempt < @max_attempts do
    backoff = max(delay, 1_000 * Integer.pow(2, job.attempt - 1)) + :rand.uniform(500)

    Map.put(pending, key, %{
      job
      | subscriptions: subscriptions,
        attempt: job.attempt + 1,
        ready_at: System.monotonic_time(:millisecond) + backoff
    })
  end

  defp retry_or_remove(pending, key, job, :failed) when job.attempt < @max_attempts do
    backoff = 1_000 * Integer.pow(2, job.attempt - 1) + :rand.uniform(500)

    Map.put(pending, key, %{
      job
      | attempt: job.attempt + 1,
        ready_at: System.monotonic_time(:millisecond) + backoff
    })
  end

  defp retry_or_remove(pending, key, _job, _result), do: Map.delete(pending, key)

  defp notifiable?({:waiting, _}), do: true
  defp notifiable?({:ended, _, reason}), do: reason in [:completed, :failed]
  defp notifiable?(_), do: false
  defp event_key({:ended, task, _}), do: {task.conversation_id, task.run_id}
  defp event_key({_kind, task}), do: {task.conversation_id, task.run_id}
end
