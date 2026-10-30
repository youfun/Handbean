defmodule Handbean.Runtime.TaskTracker do
  @moduledoc """
  Tracks active Runner executions for host notifications.

  One task is one `run_id`. Follow-up messages absorbed by the current
  Runner stay on the same task. `tool_approval_requested` is waiting,
  not ended. A terminal `run_end` completes normally; a monitored Runner
  `:DOWN` removes an orphaned projection when no terminal event arrives.
  """

  use GenServer

  alias Handbean.Runtime.Notify
  alias Handbean.Runtime.NotifyAdapter

  @topic "runtime:tasks"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(Handbean.PubSub, @topic)
  end

  @spec viewing(pid(), String.t() | nil) :: :ok
  def viewing(pid, conversation_id) when is_pid(pid) do
    GenServer.cast(__MODULE__, {:viewing, pid, conversation_id})
  catch
    :exit, _ -> :ok
  end

  @spec snapshot() :: Notify.snapshot()
  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  catch
    :exit, _ -> Notify.snapshot([])
  end

  @spec reset() :: :ok
  def reset do
    GenServer.call(__MODULE__, :reset)
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(Handbean.PubSub, "runtime:runs")

    {:ok,
     %{
       tasks: %{},
       viewers: %{},
       viewer_monitors: %{},
       run_monitors: %{}
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, notify_snapshot(state), state}
  end

  def handle_call(:reset, _from, state) do
    Enum.each(Map.values(state.run_monitors), &Process.demonitor(&1.ref, [:flush]))
    Enum.each(Map.values(state.viewer_monitors), &Process.demonitor(&1, [:flush]))
    {:reply, :ok, %{state | tasks: %{}, viewers: %{}, viewer_monitors: %{}, run_monitors: %{}}}
  end

  @impl true
  def handle_cast({:viewing, pid, conversation_id}, state) do
    state =
      if Map.has_key?(state.viewer_monitors, pid) do
        state
      else
        put_in(state, [:viewer_monitors, pid], Process.monitor(pid))
      end

    {:noreply, put_in(state, [:viewers, pid], conversation_id)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Enum.find(state.run_monitors, fn {_conversation_id, monitor} -> monitor.ref == ref end) do
      {conversation_id, %{pid: ^pid, run_id: run_id}} ->
        state = update_in(state.run_monitors, &Map.delete(&1, conversation_id))

        case Map.get(state.tasks, conversation_id) do
          %{run_id: ^run_id} ->
            {:noreply,
             finish_task(state, conversation_id, %{run_id: run_id, status: "error"}, :failed)}

          _ ->
            {:noreply, state}
        end

      nil ->
        state =
          case Map.get(state.viewer_monitors, pid) do
            ^ref ->
              %{
                state
                | viewers: Map.delete(state.viewers, pid),
                  viewer_monitors: Map.delete(state.viewer_monitors, pid)
              }

            _ ->
              update_in(state.viewers, &Map.delete(&1, pid))
          end

        {:noreply, state}
    end
  end

  def handle_info({:run_lifecycle, conversation_id, kind, _payload} = event, state)
      when kind in [
             :run_start,
             :tool_approval_requested,
             :stall_check_requested,
             :run_end,
             :run_resumed
           ] do
    case conversation_summary(conversation_id) do
      {:ok, %{"visibility" => "internal"}} -> {:noreply, state}
      {:ok, summary} -> handle_lifecycle(event, state, summary)
      {:error, _reason} -> {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp handle_lifecycle({:run_lifecycle, conversation_id, :run_start, payload}, state, summary) do
    task = %{
      conversation_id: conversation_id,
      run_id: resolve_run_id(payload, conversation_id, conversation_id),
      workspace_id: summary["workspace_id"],
      scope: summary["scope"],
      title: summary["title"],
      status: :running,
      waiting_episode: nil
    }

    state = monitor_runner(state, conversation_id, task.run_id)
    state = put_in(state, [:tasks, conversation_id], task)
    dispatch(state, {:started, task})
    {:noreply, state}
  end

  defp handle_lifecycle(
         {:run_lifecycle, conversation_id, kind, payload},
         state,
         _summary
       )
       when kind in [:tool_approval_requested, :stall_check_requested] do
    {:noreply, put_waiting(state, conversation_id, payload)}
  end

  defp handle_lifecycle({:run_lifecycle, conversation_id, :run_end, payload}, state, _summary) do
    cond do
      waiting_status?(payload) ->
        {:noreply, put_waiting(state, conversation_id, payload)}

      Handbean.PubSub.AgentEvent.terminal_status?(payload_value(payload, :status)) ->
        {:noreply, finish_task(state, conversation_id, payload, end_reason(payload))}

      true ->
        {:noreply, state}
    end
  end

  defp handle_lifecycle({:run_lifecycle, conversation_id, :run_resumed, payload}, state, _summary) do
    case Map.get(state.tasks, conversation_id) do
      %{status: :waiting_confirmation} = task ->
        if event_matches_task?(task, payload) do
          task = %{task | status: :running, waiting_episode: nil}
          state = put_in(state, [:tasks, conversation_id], task)
          dispatch(state, {:started, task})
          {:noreply, state}
        else
          {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  defp dispatch(state, event) do
    Handbean.WebPush.Dispatcher.broadcast(event)
    snapshot = broadcast_snapshot(state)

    context = %{
      app_visible?: NotifyAdapter.app_visible?(),
      viewing?: viewing?(state, event_conversation_id(event))
    }

    Enum.each(Notify.actions(snapshot, event, context), &deliver/1)
  end

  defp broadcast_snapshot(state) do
    snapshot = notify_snapshot(state)
    Phoenix.PubSub.broadcast(Handbean.PubSub, @topic, {:runtime_tasks, snapshot})
    snapshot
  end

  defp deliver({:in_app_ended, task, reason}) do
    if NotifyAdapter.prefers_system_notification?() do
      NotifyAdapter.apply({:system_ended, task, reason})
    else
      Phoenix.PubSub.broadcast(Handbean.PubSub, @topic, {:in_app_ended, task, reason})
      NotifyAdapter.apply({:in_app_ended, task, reason})
    end
  end

  defp deliver(action) do
    NotifyAdapter.apply(action)
  end

  defp event_conversation_id({:started, task}), do: task.conversation_id
  defp event_conversation_id({:waiting, task}), do: task.conversation_id
  defp event_conversation_id({:ended, task, _reason}), do: task.conversation_id

  defp viewing?(state, conversation_id) do
    Enum.any?(state.viewers, fn {_pid, viewed} -> viewed == conversation_id end)
  end

  defp notify_snapshot(state) do
    state.tasks
    |> Map.values()
    |> Enum.sort_by(& &1.conversation_id)
    |> Notify.snapshot()
  end

  defp put_waiting(state, conversation_id, payload) do
    case Map.get(state.tasks, conversation_id) do
      nil ->
        state

      task ->
        if event_matches_task?(task, payload) and task.status != :waiting_confirmation do
          task = %{
            task
            | status: :waiting_confirmation,
              waiting_episode: System.unique_integer([:positive, :monotonic]),
              run_id: resolve_run_id(payload, conversation_id, task.run_id)
          }

          state = put_in(state, [:tasks, conversation_id], task)
          dispatch(state, {:waiting, task})
          state
        else
          state
        end
    end
  end

  defp finish_task(state, conversation_id, payload, reason) do
    case Map.get(state.tasks, conversation_id) do
      nil ->
        state

      task ->
        if event_matches_task?(task, payload) do
          state = drop_run_monitor(state, conversation_id)
          {_task, state} = pop_in(state, [:tasks, conversation_id])
          task = Map.put(task, :run_id, resolve_run_id(payload, conversation_id, task.run_id))
          dispatch(state, {:ended, task, reason})
          state
        else
          state
        end
    end
  end

  defp event_matches_task?(task, payload) do
    case payload_value(payload, :run_id) do
      nil -> true
      run_id -> run_id == task.run_id
    end
  end

  defp monitor_runner(state, conversation_id, run_id) do
    state = drop_run_monitor(state, conversation_id)

    case Registry.lookup(Handbean.AgentRunRegistry, conversation_id) do
      [{pid, %{run_id: ^run_id}}] when is_pid(pid) ->
        ref = Process.monitor(pid)
        put_in(state, [:run_monitors, conversation_id], %{ref: ref, pid: pid, run_id: run_id})

      _ ->
        state
    end
  end

  defp drop_run_monitor(state, conversation_id) do
    {monitor, state} = pop_in(state, [:run_monitors, conversation_id])
    if monitor, do: Process.demonitor(monitor.ref, [:flush])
    state
  end

  defp resolve_run_id(payload, conversation_id, fallback) do
    payload_value(payload, :run_id) || session_run_id(conversation_id) || fallback
  end

  defp session_run_id(conversation_id) do
    case Handbean.PubSub.Session.whereis(conversation_id) do
      nil ->
        nil

      _pid ->
        %{meta: meta} = Handbean.PubSub.Session.snapshot(conversation_id)
        Handbean.Utils.SafeMap.get_any(meta, :run_id, "run_id")
    end
  catch
    :exit, _ -> nil
  end

  defp waiting_status?(payload) do
    Handbean.PubSub.AgentEvent.waiting_status?(payload_value(payload, :status))
  end

  defp end_reason(payload) do
    case to_string(payload_value(payload, :status) || "completed") do
      "cancelled" -> :cancelled
      "error" -> :failed
      "stalled" -> :failed
      "timeout" -> :failed
      "max_turns" -> :failed
      "budget_exceeded" -> :failed
      "halted" -> :failed
      _ -> :completed
    end
  end

  defp payload_value(payload, key) when is_map(payload) do
    Map.get(payload, key) || Map.get(payload, Atom.to_string(key))
  end

  defp conversation_summary(conversation_id) do
    case Handbean.ConversationStore.get_summary(conversation_id) do
      # Session-only conversations have always been tracked without persisted metadata.
      {:error, :not_found} -> {:ok, %{}}
      result -> result
    end
  rescue
    _error -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end
end
