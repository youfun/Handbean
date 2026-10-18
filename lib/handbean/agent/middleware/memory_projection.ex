defmodule Handbean.Agent.Middleware.MemoryProjection do
  @moduledoc """
  Projects scoped semantic memory into the prompt at session start.

  Long-term rules and preferences are bounded but do not depend on a keyword
  match. Remaining active memories are recalled against the latest user text.
  The projection is runtime context, not a third persistence layer.
  """

  @behaviour Handbean.Agent.Middleware

  alias Handbean.Agent.{Message, State}
  alias Handbean.Memory.MemoryStore

  @max_persistent_memories 8
  @max_persistent_chars 2_400
  @max_relevant_memories 5

  @impl true
  def call(:session_start, %State{config: %{builtin_memory_enabled: true}} = state) do
    {persistent, persistent_ids} = persistent_memories(state)
    relevant = relevant_memories(state, persistent_ids)

    case build_section(persistent, relevant) do
      nil -> state
      section -> %{state | config: inject_into_system_prompt(state.config, section)}
    end
  end

  def call(:session_start, %State{} = state), do: state

  @impl true
  def call(_hook, state), do: state

  defp persistent_memories(%State{} = state) do
    opts =
      state
      |> scope_opts()
      |> Keyword.put(:lifecycle, :long_term)
      |> Keyword.put(:preload_synapses, false)

    memories =
      [:rule, :preference]
      |> Enum.flat_map(fn kind -> MemoryStore.list_engrams(Keyword.put(opts, :kind, kind)) end)
      |> Enum.sort_by(&persistent_sort_key/1)
      |> take_with_budget(@max_persistent_memories, @max_persistent_chars)

    {memories, MapSet.new(memories, & &1.id)}
  end

  defp relevant_memories(%State{} = state, persistent_ids) do
    case latest_user_text(state) do
      query when is_binary(query) and query != "" ->
        query
        |> MemoryStore.recall(
          Keyword.merge(scope_opts(state),
            limit: @max_relevant_memories + MapSet.size(persistent_ids),
            match_percent: 20,
            max_required_matches: 3,
            token_window: :head_tail
          )
        )
        |> Enum.reject(&MapSet.member?(persistent_ids, &1.id))
        |> Enum.take(@max_relevant_memories)

      _ ->
        []
    end
  end

  defp build_section([], []), do: nil

  defp build_section(persistent, relevant) do
    parts =
      [
        memory_group("Persistent Rules & Preferences", persistent),
        memory_group("Relevant Memory", relevant)
      ]
      |> Enum.reject(&is_nil/1)

    "\n\n## Memory Context\n\n" <> Enum.join(parts, "\n\n") <> "\n"
  end

  defp memory_group(_title, []), do: nil

  defp memory_group(title, memories) do
    lines = Enum.map_join(memories, "\n", &memory_line/1)
    "### #{title}\n\n#{lines}"
  end

  defp memory_line(memory) do
    scope = metadata_value(memory, "scope") || "legacy"
    "- [#{scope}:#{memory.kind}:##{memory.id}] #{memory.content}"
  end

  defp take_with_budget(memories, max_count, max_chars) do
    memories
    |> Enum.reduce_while({[], 0}, fn memory, {kept, chars} ->
      size = String.length(memory.content || "")

      cond do
        length(kept) >= max_count ->
          {:halt, {kept, chars}}

        kept == [] and size > max_chars ->
          truncated = %{memory | content: String.slice(memory.content || "", 0, max_chars)}
          {:halt, {[truncated], max_chars}}

        chars + size > max_chars ->
          {:halt, {kept, chars}}

        true ->
          {:cont, {[memory | kept], chars + size}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp persistent_sort_key(memory) do
    scope_rank = if metadata_value(memory, "scope") == "workspace", do: 0, else: 1
    kind_rank = if memory.kind == :rule, do: 0, else: 1

    {scope_rank, kind_rank, -(memory.reinforced_count || 0), updated_desc(memory)}
  end

  defp updated_desc(%{updated_at: %DateTime{} = updated_at}),
    do: -DateTime.to_unix(updated_at, :microsecond)

  defp updated_desc(_memory), do: 0

  defp scope_opts(%State{} = state) do
    workspace_id = context_value(state, :workspace_id)
    privacy_mode = normalize_privacy_mode(context_value(state, :privacy_mode))
    memory_scope = normalize_scope(context_value(state, :memory_scope))

    scope = if privacy_mode == :local_only, do: :workspace, else: memory_scope || :workspace

    [workspace_id: workspace_id, scope: scope, memory_scope: scope, privacy_mode: privacy_mode]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp inject_into_system_prompt(config, section) do
    %{config | system_prompt: (config.system_prompt || "") <> section}
  end

  defp latest_user_text(%State{messages: messages}) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Message{role: :user} = message -> Message.text(message)
      _ -> nil
    end)
    |> case do
      text when is_binary(text) -> String.trim(text)
      _ -> nil
    end
  end

  defp context_value(%State{config: %{context: context}, run_metadata: run_metadata}, key) do
    map_value(context, key) || map_value(run_metadata, key)
  end

  defp map_value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp map_value(_map, _key), do: nil

  defp metadata_value(%{metadata: metadata}, key) when is_map(metadata),
    do: Handbean.Utils.SafeMap.get(metadata, key)

  defp metadata_value(_memory, _key), do: nil

  defp normalize_scope(scope) when scope in [:global, :workspace, :both], do: scope
  defp normalize_scope("global"), do: :global
  defp normalize_scope("workspace"), do: :workspace
  defp normalize_scope("both"), do: :both
  defp normalize_scope(_scope), do: nil

  defp normalize_privacy_mode(mode) when mode in [:standard, :local_only], do: mode
  defp normalize_privacy_mode("standard"), do: :standard
  defp normalize_privacy_mode("local_only"), do: :local_only
  defp normalize_privacy_mode(_mode), do: nil
end
