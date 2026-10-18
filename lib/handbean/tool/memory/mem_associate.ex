defmodule Handbean.Tool.Memory.MemAssociate do
  @moduledoc """
  Memory associate tool — links two engrams with a synapse.
  """

  @behaviour Handbean.Agent.Tool

  alias Handbean.Memory.MemoryStore
  alias Handbean.Tool.Memory.Scope

  @association_kinds [:related, :contradicts, :example_of, :context_for, :reinforces]

  @impl true
  def name, do: "mem_associate"

  @impl true
  def description do
    "Associate two memories together. " <>
      "Use to link related facts, patterns, or preferences."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        source_id: %{type: "integer", description: "ID of the source engram"},
        target_id: %{type: "integer", description: "ID of the target engram"},
        kind: %{
          type: "string",
          description: "Relationship: related, contradicts, example_of, context_for, reinforces"
        }
      },
      required: ["source_id", "target_id", "kind"]
    }
  end

  @impl true
  def max_result_chars, do: 500

  @impl true
  def concurrent?, do: false

  @impl true
  def execute(%{"source_id" => source_id, "target_id" => target_id, "kind" => kind_str}, context) do
    with {:ok, kind} <- parse_kind(kind_str),
         {:ok, _synapse} <-
           MemoryStore.associate(source_id, target_id, kind, Scope.options(context)) do
      {:ok, "Associated engram #{source_id} #{kind} #{target_id}"}
    else
      {:error, :invalid_kind} ->
        {:error, "Invalid kind. Use: related, contradicts, example_of, context_for, reinforces"}

      {:error, :not_found} ->
        {:error, "One or both engrams are not accessible from this memory scope"}

      {:error, reason} ->
        {:error, Scope.error_message(reason)}
    end
  end

  def execute(_input, _context), do: {:error, "source_id, target_id, and kind are required"}

  defp parse_kind(kind_str) when is_binary(kind_str) do
    kind = String.to_existing_atom(kind_str)

    if kind in @association_kinds, do: {:ok, kind}, else: {:error, :invalid_kind}
  rescue
    ArgumentError -> {:error, :invalid_kind}
  end

  defp parse_kind(_kind_str), do: {:error, :invalid_kind}
end
