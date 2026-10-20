defmodule Handbean.Tool.Memory.MemReinforce do
  @moduledoc """
  Memory reinforce tool — promotes short-term memory to long-term.

  Increments the reinforcement counter and prevents auto-expiry.
  """

  @behaviour Handbean.Agent.Tool

  alias Handbean.Memory.MemoryStore
  alias Handbean.Tool.Memory.Scope

  @impl true
  def name, do: "mem_reinforce"

  @impl true
  def description do
    "Reinforce a memory, promoting it from short-term to long-term. " <>
      "Use when you encounter information worth remembering permanently."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        id: %{type: "integer", description: "ID of the engram to reinforce"},
        query: %{
          type: "string",
          description: "Alternative: reinforce by content match (use most recent match)"
        },
        sources: %{
          type: "array",
          maxItems: 10,
          description: "Persisted conversation entry anchors that confirm this memory",
          items: Scope.citation_schema()
        }
      },
      required: []
    }
  end

  @impl true
  def max_result_chars, do: 500

  @impl true
  def concurrent?, do: false

  @impl true
  def execute(%{"id" => id} = input, context) do
    reinforce(id, Scope.options(context, citations: Map.get(input, "sources", [])))
  end

  def execute(%{"query" => query} = input, context) do
    opts = Scope.options(context, citations: Map.get(input, "sources", []))

    with :ok <- MemoryStore.validate_scope(opts),
         [engram | _] <- MemoryStore.recall(query, [limit: 1] ++ opts) do
      reinforce(engram.id, opts)
    else
      [] -> {:error, "No memory found matching '#{query}'"}
      {:error, reason} -> {:error, Scope.error_message(reason)}
    end
  end

  def execute(_input, _context), do: {:error, "Provide id or query of the memory to reinforce"}

  defp reinforce(id, opts) do
    case MemoryStore.reinforce(id, opts) do
      {:ok, reinforced} ->
        {:ok, "Reinforced: [#{reinforced.kind}] #{reinforced.content} (now long-term)"}

      {:error, :not_found} ->
        {:error, "No accessible engram found with id #{id}"}

      {:error, reason} ->
        {:error, Scope.error_message(reason)}
    end
  end
end
