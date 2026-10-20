defmodule Handbean.Tool.Memory.MemUpdate do
  @moduledoc """
  Memory update tool — corrects the content or kind of an existing memory.
  """

  @behaviour Handbean.Agent.Tool

  alias Handbean.Memory.{MemoryStore, Policy}
  alias Handbean.Tool.Memory.Scope

  @engram_kinds [:fact, :pattern, :preference, :rule, :context]

  @impl true
  def name, do: "mem_update"

  @impl true
  def description do
    "Correct an existing memory's content or kind. " <>
      "Use when the user explicitly updates previously remembered information."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        id: %{type: "integer", description: "ID of the memory to update"},
        content: %{type: "string", description: "Corrected memory content"},
        kind: %{
          type: "string",
          description: "Corrected type: fact, pattern, preference, rule, or context"
        },
        sources: %{
          type: "array",
          maxItems: 10,
          description: "Persisted conversation entry anchors supporting this correction",
          items: Scope.citation_schema()
        }
      },
      required: ["id"]
    }
  end

  @impl true
  def max_result_chars, do: 1_000

  @impl true
  def concurrent?, do: false

  @impl true
  def execute(%{"id" => id} = input, context) do
    with {:ok, attrs} <- update_attrs(input),
         {:ok, engram} <-
           MemoryStore.update(
             id,
             attrs,
             Scope.options(context, citations: Map.get(input, "sources", []))
           ) do
      {:ok, "Updated: [#{engram.kind}] #{engram.content}", %{id: engram.id, kind: engram.kind}}
    else
      {:error, :missing_update} ->
        {:error, "Provide content or kind to update"}

      {:error, :invalid_kind} ->
        {:error, "Invalid kind. Must be: fact, pattern, preference, rule, or context"}

      {:error, reason} when is_binary(reason) ->
        {:error, "Rejected memory: #{reason}"}

      {:error, reason} ->
        {:error, Scope.error_message(reason)}
    end
  end

  def execute(_input, _context), do: {:error, "id is required"}

  defp update_attrs(input) do
    with {:ok, attrs} <- maybe_put_content(%{}, input),
         {:ok, attrs} <- maybe_put_kind(attrs, input) do
      if map_size(attrs) == 0, do: {:error, :missing_update}, else: {:ok, attrs}
    end
  end

  defp maybe_put_content(attrs, %{"content" => content}) do
    case Policy.validate_candidate_memory(content) do
      {:ok, safe_content} -> {:ok, Map.put(attrs, :content, safe_content)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_put_content(attrs, _input), do: {:ok, attrs}

  defp maybe_put_kind(attrs, %{"kind" => kind_str}) do
    with {:ok, kind} <- parse_kind(kind_str), do: {:ok, Map.put(attrs, :kind, kind)}
  end

  defp maybe_put_kind(attrs, _input), do: {:ok, attrs}

  defp parse_kind(kind_str) when is_binary(kind_str) do
    kind = String.to_existing_atom(kind_str)
    if kind in @engram_kinds, do: {:ok, kind}, else: {:error, :invalid_kind}
  rescue
    ArgumentError -> {:error, :invalid_kind}
  end

  defp parse_kind(_kind_str), do: {:error, :invalid_kind}
end
