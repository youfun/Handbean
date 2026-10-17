defmodule Handbean.Agent.Middleware.ObservationalAfterCompletion do
  @moduledoc """
  Observational Memory middleware — records a summary observation when
  the agent completes a turn (provider returns `:end_turn`).

  ## Behavior
    - On `:after_completion`: extracts key information from the assistant's
      response and the run state, creates a medium-priority observation,
      and appends it to the ObservationStore.
    - On all other hooks: passes through unchanged.

  This is a no-LLM observation — it captures metadata (model, tokens, turn)
  and a brief summary of the assistant response.
  """

  @behaviour Handbean.Agent.Middleware

  alias Handbean.Agent.{Message, State}
  alias Handbean.Memory.{Observation, ObservationStore}
  alias Handbean.Memory.ObservationalConfig, as: Config

  @impl true
  def call(:after_completion, %State{} = state) do
    cond do
      not Config.for_state(state).enabled ->
        state

      is_nil(session_id(state)) ->
        state

      true ->
        record_completion(state)
        state
    end
  end

  @impl true
  def call(_hook, state), do: state

  # ── Recording ──

  defp record_completion(%State{} = state) do
    sid = session_id(state)

    content =
      build_completion_summary(
        state.turn,
        state.config.model,
        state.usage,
        last_assistant_text(state)
      )

    obs =
      Observation.new(content,
        priority: :medium,
        source: :completion,
        metadata:
          %{
            turn: state.turn,
            model: state.config.model,
            input_tokens: state.usage[:input_tokens] || 0,
            output_tokens: state.usage[:output_tokens] || 0,
            status: to_string(state.status)
          }
          |> Map.merge(scope_metadata(state))
      )

    ObservationStore.append(sid, obs)
  end

  defp build_completion_summary(turn, model, usage, assistant_text) do
    input_tokens = usage[:input_tokens] || 0
    output_tokens = usage[:output_tokens] || 0
    text_preview = summarize_text(assistant_text)

    "Turn #{turn} completed (model: #{model}, in: #{input_tokens}, out: #{output_tokens})#{text_preview}"
  end

  defp summarize_text(nil), do: ""
  defp summarize_text(""), do: ""

  defp summarize_text(text) when is_binary(text) do
    trimmed = String.trim(text)

    cond do
      trimmed == "" -> ""
      String.length(trimmed) <= 150 -> ": #{trimmed}"
      true -> ": #{String.slice(trimmed, 0, 150)}..."
    end
  end

  defp last_assistant_text(%State{messages: messages}) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Message{role: :assistant} = msg ->
        Message.text(msg)

      _ ->
        nil
    end)
  end

  defp scope_metadata(%State{} = state) do
    memory_scope = context_value(state, :memory_scope)
    workspace_id = context_value(state, :workspace_id)
    privacy_mode = context_value(state, :privacy_mode)

    scope =
      case memory_scope do
        scope when scope in [:global, "global"] -> "global"
        _ when is_binary(workspace_id) -> "workspace"
        _ -> nil
      end

    %{}
    |> maybe_put(:scope, scope)
    |> maybe_put(:workspace_id, if(scope == "workspace", do: workspace_id, else: nil))
    |> maybe_put(:privacy_mode, privacy_mode && to_string(privacy_mode))
  end

  defp context_value(%State{config: %{context: context}, run_metadata: run_metadata}, key) do
    map_value(context, key) || map_value(run_metadata, key)
  end

  defp map_value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp map_value(_map, _key), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp session_id(%State{run_metadata: %{session_id: sid}}) when is_binary(sid), do: sid
  defp session_id(_), do: nil
end
