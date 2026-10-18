defmodule Handbean.PubSub.AgentEvent do
  @moduledoc """
  Agent event struct — emitted during the agent loop.

  Events carry a monotonically increasing `seq` within their Session `epoch`.
  Single topic per session prevents cross-topic ordering issues.
  """

  defstruct [:seq, :epoch, :topic, :kind, :payload, :ts_ms]

  # `Session.broadcast_event/3` does not validate kinds; this type lists every
  # kind emitted today so consumers get exhaustive matching.
  @type kind ::
          :message_delta
          | :thinking_delta
          | :usage_updated
          | :delegation_usage
          | :tool_start
          | :tool_end
          | :tool_approval_requested
          | :session_state
          | :run_start
          | :run_resumed
          | :run_end
          | :agent_end
          | :turn_start
          | :turn_end
          | :candidate_message_injected
          | :stall_check_requested
          | :subagent_start
          | :subagent_progress
          | :subagent_end
          | :subagent_approval_requested

  @type t :: %__MODULE__{
          seq: non_neg_integer(),
          epoch: String.t() | nil,
          topic: String.t(),
          kind: kind(),
          payload: map(),
          ts_ms: integer()
        }

  @doc """
  Create a new event with auto-incrementing sequence.
  """
  @spec new(String.t(), kind(), map(), non_neg_integer()) :: t()
  def new(topic, kind, payload, seq) do
    %__MODULE__{
      topic: topic,
      kind: kind,
      payload: payload,
      seq: seq,
      ts_ms: System.os_time(:millisecond)
    }
  end

  @doc "Approval suspension is not a terminal run, including restored JSON values."
  def waiting_status?(status),
    do: status in [:interrupted, "interrupted", :awaiting_approval, "awaiting_approval"]

  @doc "Only known terminal statuses close a run; missing/unknown values do not."
  def terminal_status?(status) do
    status in [
      :completed,
      "completed",
      :cancelled,
      "cancelled",
      :error,
      "error",
      :timeout,
      "timeout",
      :max_turns,
      "max_turns",
      :budget_exceeded,
      "budget_exceeded",
      :halted,
      "halted",
      :stalled,
      "stalled"
    ]
  end

  @doc "Create a message delta event (streaming chunk)."
  def message_delta(topic, chunk, seq) do
    new(topic, :message_delta, %{chunk: chunk}, seq)
  end

  @doc "Create a tool start event."
  def tool_start(topic, tool_name, input, seq) do
    new(topic, :tool_start, %{tool: tool_name, input: input}, seq)
  end

  @doc "Create a tool end event."
  def tool_end(topic, tool_name, duration_ms, error, seq) do
    new(topic, :tool_end, %{tool: tool_name, duration_ms: duration_ms, error: error}, seq)
  end

  @doc "Create a run start event."
  def run_start(topic, model, prompt, seq) do
    new(topic, :run_start, %{model: model, prompt: prompt}, seq)
  end

  @doc "Create a run end event."
  def run_end(topic, status, turns, seq) do
    new(topic, :run_end, %{status: status, turns: turns}, seq)
  end
end
