defmodule Handbean.Tool.Memory.MemLearn do
  @moduledoc """
  Memory learn tool — stores new knowledge.

  Creates short-term engrams that expire after 24h unless reinforced.
  """

  @behaviour Handbean.Agent.Tool

  alias Handbean.Memory.Policy

  @impl true
  def name, do: "mem_learn"

  @impl true
  def description do
    "Learn and remember new information. " <>
      "Memory starts as short-term (24h expiry) and becomes long-term when reinforced."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        content: %{type: "string", description: "The fact, pattern, or preference to remember"},
        kind: %{type: "string", description: "Type: fact, pattern, preference, rule, or context"},
        short_term: %{type: "boolean", description: "Store as short-term memory?", default: true}
      },
      required: ["content", "kind"]
    }
  end

  @impl true
  def max_result_chars, do: 1_000

  @impl true
  def concurrent?, do: false

  @impl true
  def execute(%{"content" => content, "kind" => kind_str} = input, context) do
    with {:ok, kind} <- parse_kind(kind_str),
         {:ok, safe_content} <- Policy.validate_candidate_memory(content) do
      short_term = Map.get(input, "short_term", true)

      case Handbean.Memory.MemoryStore.learn(safe_content, kind,
             short_term: short_term,
             metadata: scope_metadata(context)
           ) do
        {:ok, engram} ->
          {:ok, "Learned: [#{engram.kind}] #{engram.content}", %{id: engram.id, kind: kind_str}}

        {:error, changeset} ->
          {:error, "Failed to learn: #{inspect(changeset.errors)}"}
      end
    else
      {:error, :invalid_kind} ->
        {:error, "Invalid kind. Must be: fact, pattern, preference, rule, or context"}

      {:error, reason} when is_binary(reason) ->
        {:error, "Rejected memory: #{reason}"}
    end
  end

  def execute(_input, _context), do: {:error, "content and kind are required"}

  defp parse_kind(kind_str) when is_binary(kind_str) do
    kind = String.to_existing_atom(kind_str)

    if kind in [:fact, :pattern, :preference, :rule, :context] do
      {:ok, kind}
    else
      {:error, :invalid_kind}
    end
  rescue
    ArgumentError -> {:error, :invalid_kind}
  end

  defp parse_kind(_kind_str), do: {:error, :invalid_kind}

  defp scope_metadata(context) when is_map(context) do
    memory_scope = context_value(context, :memory_scope)
    workspace_id = context_value(context, :workspace_id)
    privacy_mode = context_value(context, :privacy_mode)

    scope =
      case memory_scope do
        scope when scope in [:global, "global"] -> "global"
        _ when is_binary(workspace_id) -> "workspace"
        _ -> nil
      end

    %{}
    |> put_if_present("scope", scope)
    |> put_if_present("workspace_id", if(scope == "workspace", do: workspace_id, else: nil))
    |> put_if_present("privacy_mode", privacy_mode && to_string(privacy_mode))
  end

  defp scope_metadata(_context), do: %{}

  defp context_value(context, key),
    do: Map.get(context, key) || Map.get(context, Atom.to_string(key))

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)
end
