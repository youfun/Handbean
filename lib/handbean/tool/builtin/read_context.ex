defmodule Handbean.Tool.Builtin.ReadContext do
  @moduledoc """
  Shows the model the context that later requests in this run will send.

  Fence lines label each message. They are not part of the text `edit_context` replaces.
  """

  @behaviour Handbean.Agent.Tool

  alias Handbean.Agent.ModelContext

  @impl true
  def name, do: "read_context"

  @impl true
  def description do
    "Read the context that later requests in this run will send. " <>
      "Each message starts with a [[ctx:N role]] line. The first message is the original task and is frozen. " <>
      "Copy old_text from the body under a fence, not from the fence line, then call edit_context."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{},
      required: []
    }
  end

  @impl true
  def concurrent?, do: false

  @impl true
  def max_result_chars, do: 200_000

  @impl true
  def execute(_input, context) when is_map(context) do
    {:ok, ModelContext.render(context[:model_messages] || [])}
  end

  def execute(_input, _context), do: {:ok, ModelContext.render([])}
end
