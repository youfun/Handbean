defmodule Handbean.Agent.Middleware.ObservationalSessionStart do
  @moduledoc """
  Observational Memory middleware — injects recent observations into the
  agent's system prompt at the start of each session.

  ## Behavior
    - On `:session_start`: loads the N most recent observations for the
      current conversation and appends them to the system prompt as a
      "## Recent Context" section.
    - On all other hooks: passes through unchanged.
  """

  @behaviour Handbean.Agent.Middleware

  alias Handbean.Agent.{Message, State}
  alias Handbean.Memory.{MemoryStore, ObservationStore}
  alias Handbean.Memory.ObservationalConfig, as: Config

  @max_relevant_memories 5

  @impl true
  def call(:session_start, %State{} = state) do
    cond do
      not Config.for_state(state).enabled ->
        state

      is_nil(session_id(state)) ->
        state

      true ->
        state
        |> inject_relevant_memory()
        |> inject_recent_context()
    end
  end

  @impl true
  def call(_hook, state), do: state

  # ── Context Injection ──

  defp inject_relevant_memory(%State{} = state) do
    query = latest_user_text(state)

    if is_nil(query) or String.trim(query) == "" do
      state
    else
      memories = recall_relevant_memories(query, state)

      if memories == [] do
        state
      else
        memory_section = build_memory_section(memories)
        %{state | config: inject_into_system_prompt(state.config, memory_section)}
      end
    end
  end

  defp inject_recent_context(%State{} = state) do
    config = Config.for_state(state)
    sid = session_id(state)
    limit = config.max_recent_context
    observations = ObservationStore.load_recent(sid, limit)

    if observations == [] do
      state
    else
      context_section = build_context_section(observations)
      %{state | config: inject_into_system_prompt(state.config, context_section)}
    end
  end

  defp recall_relevant_memories(query, %State{} = state) do
    MemoryStore.recall(query,
      limit: @max_relevant_memories,
      min_matches: 3,
      workspace_id: context_value(state, :workspace_id),
      memory_scope: context_value(state, :memory_scope),
      privacy_mode: context_value(state, :privacy_mode)
    )
  end

  defp build_memory_section(memories) do
    lines =
      memories
      |> Enum.map(fn memory ->
        scope =
          metadata_value(memory, "scope") ||
            if(memory.short_term, do: "short-term", else: "long-term")

        "- [#{scope}:#{memory.kind}] #{memory.content}"
      end)

    "\n\n## Relevant Memory\n\n" <> Enum.join(lines, "\n") <> "\n"
  end

  defp build_context_section(observations) do
    lines =
      observations
      |> Enum.reverse()
      |> Enum.map(&Handbean.Memory.Observation.to_context_line/1)

    "\n\n## Recent Context\n\n" <> Enum.join(lines, "\n") <> "\n"
  end

  defp inject_into_system_prompt(config, section) do
    existing = config.system_prompt || ""
    %{config | system_prompt: existing <> section}
  end

  defp latest_user_text(%State{messages: messages}) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Message{role: :user} = message -> Message.text(message)
      _ -> nil
    end)
  end

  defp context_value(%State{config: %{context: context}, run_metadata: run_metadata}, key) do
    map_value(context, key) || map_value(run_metadata, key)
  end

  defp map_value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp map_value(_map, _key), do: nil

  defp metadata_value(%{metadata: metadata}, key) when is_map(metadata),
    do: Handbean.Utils.SafeMap.get(metadata, key)

  defp metadata_value(_, _), do: nil

  defp session_id(%State{run_metadata: %{session_id: sid}}) when is_binary(sid), do: sid
  defp session_id(_), do: nil
end
