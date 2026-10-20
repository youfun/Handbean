defmodule Handbean.Agent.Turn.CandidateMessages do
  @moduledoc false

  alias Handbean.Agent.State
  alias Handbean.Agent.Turn.Events

  def inject(%State{} = state, opts, deliver_as) do
    case drain(opts, deliver_as) do
      [] ->
        state

      messages ->
        emit_injected(opts, deliver_as, messages)
        State.append_messages(state, messages)
    end
  end

  def drain(opts, :steer) do
    case Keyword.get(opts, :candidate_queue) do
      nil -> []
      queue -> Handbean.Agent.CandidateQueue.drain_steer(queue)
    end
  end

  def drain(opts, :follow_up) do
    case Keyword.get(opts, :candidate_queue) do
      nil -> []
      queue -> Handbean.Agent.CandidateQueue.drain_follow_up(queue)
    end
  end

  def emit_injected(opts, deliver_as, messages) do
    Events.emit(opts, :candidate_message_injected, %{
      deliver_as: deliver_as,
      count: length(messages),
      message_ids: Enum.map(messages, & &1.id)
    })
  end
end
