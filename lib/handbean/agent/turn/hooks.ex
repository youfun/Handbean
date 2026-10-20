defmodule Handbean.Agent.Turn.Hooks do
  @moduledoc false

  alias Handbean.Agent.{ModelContext, State}
  alias Handbean.Extension.HookPipeline

  def before_agent_start(state, opts) do
    session_id = Keyword.get(opts, :session_id)

    if session_id do
      payload = %{model: state.config.model, max_turns: state.config.max_turns}

      case run(state, session_id, {:before_agent_start, payload}) do
        {:block, reason} ->
          %{state | status: :halted, error: "Blocked by extension: #{reason}"}

        {:transform, transformed} ->
          config =
            case Map.fetch(transformed, :system_prompt) do
              {:ok, prompt} when is_binary(prompt) -> %{state.config | system_prompt: prompt}
              _ -> state.config
            end

          state =
            case Map.fetch(transformed, :metadata) do
              {:ok, meta} when is_map(meta) -> State.merge_run_metadata(state, meta)
              _ -> state
            end

          %{state | config: config}

        _ ->
          state
      end
    else
      state
    end
  end

  def apply_context(state, provider_config, opts) do
    session_id = Keyword.get(opts, :session_id)
    messages = ModelContext.visible(state)

    if session_id do
      payload = %{messages: messages, system_prompt: provider_config.system_prompt}

      case run(state, session_id, {:context, payload}) do
        {:block, reason} ->
          {:block, reason}

        {:transform, transformed} ->
          outbound_messages =
            case Map.fetch(transformed, :messages) do
              {:ok, msgs} when is_list(msgs) -> msgs
              _ -> messages
            end

          provider_config =
            case Map.fetch(transformed, :system_prompt) do
              {:ok, prompt} when is_binary(prompt) -> %{provider_config | system_prompt: prompt}
              _ -> provider_config
            end

          {outbound_messages, provider_config}

        _ ->
          {messages, provider_config}
      end
    else
      {messages, provider_config}
    end
  end

  defp run(%State{config: %{delegated?: true}}, _session_id, _event), do: :ok
  defp run(_state, session_id, event), do: HookPipeline.run(session_id, event)
end
