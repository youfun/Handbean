defmodule Handbean.Tool.Memory.MemLearn do
  @moduledoc """
  Memory learn tool — stores new knowledge.

  Creates short-term engrams that expire after 24h unless reinforced.
  """

  @behaviour Handbean.Agent.Tool

  alias Handbean.Memory.Policy
  alias Handbean.Tool.Memory.Scope

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
      opts =
        Scope.options(context) ++
          [
            short_term: Map.get(input, "short_term", true),
            metadata: provenance_metadata(context)
          ]

      case Handbean.Memory.MemoryStore.learn(safe_content, kind, opts) do
        {:ok, engram} ->
          {:ok, "Learned: [#{engram.kind}] #{engram.content}", %{id: engram.id, kind: kind_str}}

        {:error, reason} ->
          {:error, Scope.error_message(reason)}
      end
    else
      {:error, :invalid_kind} ->
        {:error, "Invalid kind. Must be: fact, pattern, preference, rule, or context"}

      {:error, reason} when is_binary(reason) ->
        {:error, "Rejected memory: #{reason}"}
    end
  end

  def execute(_input, _context), do: {:error, "content and kind are required"}

  defp provenance_metadata(context) do
    %{"source" => "agent_tool"}
    |> put_context_value("conversation_id", context, :conversation_id)
    |> put_context_value("run_id", context, :run_id)
  end

  defp put_context_value(metadata, metadata_key, context, context_key) do
    case Map.get(context, context_key) || Map.get(context, Atom.to_string(context_key)) do
      value when is_binary(value) and value != "" -> Map.put(metadata, metadata_key, value)
      _other -> metadata
    end
  end

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
end
