defmodule Handbean.Tool.Memory.MemForget do
  @moduledoc """
  Memory forget tool — deletes an existing memory from its validated scope.
  """

  @behaviour Handbean.Agent.Tool

  alias Handbean.Memory.MemoryStore
  alias Handbean.Tool.Memory.Scope

  @impl true
  def name, do: "mem_forget"

  @impl true
  def description do
    "Forget a memory that the user explicitly asks to remove. " <>
      "The memory must be accessible in the current scope."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        id: %{type: "integer", description: "ID of the memory to forget"}
      },
      required: ["id"]
    }
  end

  @impl true
  def max_result_chars, do: 500

  @impl true
  def concurrent?, do: false

  @impl true
  def execute(%{"id" => id}, context) do
    case MemoryStore.delete(id, Scope.options(context)) do
      {:ok, engram} ->
        {:ok, "Forgot: [#{engram.kind}] #{engram.content}", %{id: engram.id}}

      {:error, reason} ->
        {:error, Scope.error_message(reason)}
    end
  end

  def execute(_input, _context), do: {:error, "id is required"}
end
