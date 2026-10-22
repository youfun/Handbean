defmodule Handbean.PubSub.Session.RecoveryProjection do
  @moduledoc false

  @spec events([Handbean.PubSub.AgentEvent.t()], String.t() | nil) ::
          [Handbean.PubSub.AgentEvent.t()]
  def events(events, run_id) do
    events
    |> Enum.filter(&(event_run_id(&1) == run_id))
    |> Enum.sort_by(& &1.seq)
    |> Enum.reduce(empty_recovery(), &reduce_recovery_event/2)
    |> recovery_event_list()
  end

  @spec pending_events([Handbean.PubSub.AgentEvent.t()]) :: [Handbean.PubSub.AgentEvent.t()]
  def pending_events(events) do
    events
    |> Enum.filter(&(&1.kind in [:candidate_message_injected, :candidate_message_deleted]))
    |> Enum.sort_by(& &1.seq)
  end

  defp empty_recovery do
    %{
      run_start: nil,
      run_resumed: nil,
      turn_start: nil,
      session_state: nil,
      usage_updated: nil,
      model_switch: nil,
      active_tools: %{},
      pending_approval: nil
    }
  end

  defp reduce_recovery_event(%{kind: :run_start} = event, _state),
    do: %{empty_recovery() | run_start: event}

  defp reduce_recovery_event(%{kind: :run_resumed} = event, state),
    do: %{state | run_resumed: event, session_state: nil, pending_approval: nil}

  defp reduce_recovery_event(%{kind: :turn_start} = event, state),
    do: %{state | turn_start: event}

  defp reduce_recovery_event(%{kind: :session_state} = event, state),
    do: %{state | session_state: event}

  defp reduce_recovery_event(%{kind: :usage_updated} = event, state),
    do: %{state | usage_updated: event}

  defp reduce_recovery_event(%{kind: kind} = event, state)
       when kind in [
              :model_switch_accepted,
              :model_switch_applied,
              :model_switch_cancelled,
              :model_switch_failed,
              :model_switch_expired
            ],
       do: %{state | model_switch: event}

  defp reduce_recovery_event(%{kind: :tool_start} = event, state) do
    put_in(state, [:active_tools, recovery_tool_id(event)], event)
  end

  defp reduce_recovery_event(%{kind: :tool_end} = event, state) do
    update_in(state.active_tools, &Map.delete(&1, recovery_tool_id(event)))
  end

  defp reduce_recovery_event(%{kind: :tool_approval_requested} = event, state),
    do: %{state | pending_approval: event}

  defp reduce_recovery_event(_event, state), do: state

  defp recovery_event_list(state) do
    [
      state.run_start,
      state.run_resumed,
      state.turn_start,
      state.session_state,
      state.usage_updated,
      state.model_switch,
      Map.values(state.active_tools),
      state.pending_approval
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp event_run_id(event),
    do: Handbean.Utils.SafeMap.get_any(event.payload, :run_id, "run_id")

  defp recovery_tool_id(event) do
    Handbean.Utils.SafeMap.get_any(event.payload, :tool_use_id, "tool_use_id") ||
      Handbean.Utils.SafeMap.get_any(event.payload, :tool, "tool") ||
      Handbean.Utils.SafeMap.get_any(event.payload, :name, "name") ||
      event.seq
  end
end
