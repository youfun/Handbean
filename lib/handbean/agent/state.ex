defmodule Handbean.Agent.State do
  @moduledoc """
  Agent state — holds messages, turn counter, and execution status.

  Immutable struct passed through the agent loop as a pure data value.
  """

  alias Handbean.Agent.Config
  alias Handbean.Agent.Message

  defstruct [
    :config,
    :messages,
    :turn,
    :status,
    :error,
    :usage,
    :tool_calls,
    :provider_state,
    :response_metadata,
    :run_metadata,
    :provider_response_metadata,
    :tool_guard_overrides,
    :tool_guard_session_allow,
    :tool_guard_pending_grants,
    :tool_guard_execution_grants,
    :tool_guard_admission_contexts,
    :interrupt_data,
    :tool_guard_denied_calls,
    :tool_guard_result_blocks,
    :advisor,
    :progress,
    :auto_review,
    :model_context,
    :context_base_count,
    :usage_anchor,
    context_edited: false,
    context_generation: 0
  ]

  @type status ::
          :running
          | :completed
          | :error
          | :max_turns
          | :budget_exceeded
          | :halted
          | :interrupted
          | :stalled

  @type t :: %__MODULE__{
          config: Config.t(),
          messages: [Message.t()],
          turn: non_neg_integer(),
          status: status(),
          error: String.t() | nil,
          usage: map(),
          tool_calls: [map()],
          provider_state: map(),
          response_metadata: map(),
          run_metadata: map(),
          provider_response_metadata: map(),
          tool_guard_overrides: map(),
          tool_guard_session_allow: [String.t()],
          tool_guard_pending_grants: map(),
          tool_guard_execution_grants: map(),
          tool_guard_admission_contexts: map(),
          interrupt_data: map() | nil,
          tool_guard_denied_calls: [map()],
          tool_guard_result_blocks: [map()],
          advisor: map(),
          model_context: [Message.t()] | nil,
          context_base_count: non_neg_integer(),
          usage_anchor: map() | nil,
          context_edited: boolean(),
          context_generation: non_neg_integer()
        }

  @doc "Create initial state from config and user prompt."
  @spec init(Config.t(), String.t() | Message.t()) :: t()
  def init(%Config{} = config, %Message{} = prompt) do
    new(config, [prompt])
  end

  def init(%Config{} = config, prompt) when is_binary(prompt) do
    new(config, [Message.user(prompt)])
  end

  def init(%Config{} = config, prompts) when is_list(prompts) do
    new(config, prompts)
  end

  defp advisor_mode(%{mode: mode}), do: mode
  defp advisor_mode(_advisor), do: nil

  defp new(%Config{} = config, messages) do
    %__MODULE__{
      config: config,
      messages: messages,
      turn: 0,
      status: :running,
      error: nil,
      usage: %{input_tokens: 0, output_tokens: 0},
      tool_calls: [],
      provider_state: %{},
      response_metadata: %{},
      run_metadata: %{},
      provider_response_metadata: %{},
      tool_guard_overrides: %{},
      tool_guard_session_allow: [],
      tool_guard_pending_grants: %{},
      tool_guard_execution_grants: %{},
      tool_guard_admission_contexts: %{},
      interrupt_data: nil,
      tool_guard_denied_calls: [],
      tool_guard_result_blocks: [],
      advisor: Handbean.Agent.Advisor.initial_state(advisor_mode(config.advisor)),
      progress: Handbean.Agent.ProgressGuard.initial(),
      auto_review: Handbean.Permissions.AutoReview.initial_ledger(),
      model_context: nil,
      context_base_count: 0,
      usage_anchor: nil,
      context_edited: false,
      context_generation: 0
    }
  end

  @doc "Append messages to the conversation history."
  @spec append_messages(t(), [Message.t()]) :: t()
  def append_messages(%__MODULE__{} = state, messages) do
    %{state | messages: state.messages ++ List.wrap(messages)}
  end

  @doc "Increment the turn counter."
  @spec increment_turn(t()) :: t()
  def increment_turn(%__MODULE__{} = state) do
    %{state | turn: state.turn + 1}
  end

  @doc "Merge usage stats into cumulative totals."
  @spec merge_usage(t(), map()) :: t()
  def merge_usage(%__MODULE__{} = state, usage) when is_map(usage) do
    unknown? =
      Map.get(state.usage, :unknown?, false) or
        Map.get(usage, :unknown?, false) or
        Map.get(usage, "unknown?", false)

    merged = %{
      input_tokens: (state.usage[:input_tokens] || 0) + (usage[:input_tokens] || 0),
      total_input_tokens:
        (state.usage[:total_input_tokens] || 0) +
          Map.get(
            usage,
            :total_input_tokens,
            (usage[:input_tokens] || 0) + (usage[:cache_read_input_tokens] || 0) +
              (usage[:cache_creation_input_tokens] || 0)
          ),
      output_tokens: (state.usage[:output_tokens] || 0) + (usage[:output_tokens] || 0),
      cache_read_input_tokens:
        (state.usage[:cache_read_input_tokens] || 0) +
          (usage[:cache_read_input_tokens] || 0),
      cache_creation_input_tokens:
        (state.usage[:cache_creation_input_tokens] || 0) +
          (usage[:cache_creation_input_tokens] || 0),
      unknown?: unknown?
    }

    %{state | usage: Map.merge(state.usage, merged)}
  end

  @doc "Merge provider state for the next turn."
  @spec merge_provider_state(t(), map()) :: t()
  def merge_provider_state(%__MODULE__{} = state, provider_state) when is_map(provider_state) do
    merged =
      (state.provider_state || %{})
      |> Map.merge(provider_state)
      |> Map.put(:context_generation, state.context_generation || 0)

    %{state | provider_state: merged}
  end

  @doc "Store provider response metadata."
  @spec put_provider_response_metadata(t(), map()) :: t()
  def put_provider_response_metadata(%__MODULE__{} = state, metadata) when is_map(metadata) do
    %{state | provider_response_metadata: metadata}
  end

  @doc "Append tool call metadata."
  @spec append_tool_calls(t(), [map()]) :: t()
  def append_tool_calls(%__MODULE__{} = state, calls) do
    %{state | tool_calls: state.tool_calls ++ calls}
  end

  @doc "Merge run metadata."
  @spec merge_run_metadata(t(), map()) :: t()
  def merge_run_metadata(%__MODULE__{} = state, metadata) when is_map(metadata) do
    %{state | run_metadata: Map.merge(state.run_metadata, metadata)}
  end

  @doc "Return all messages in the conversation."
  @spec messages(t()) :: [Message.t()]
  def messages(%__MODULE__{} = state), do: state.messages

  @doc "Materialize final state — freeze for external consumption."
  @spec materialize(t()) :: t()
  def materialize(%__MODULE__{} = state), do: state
end
