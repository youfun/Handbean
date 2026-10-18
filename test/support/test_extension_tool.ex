defmodule TestExtensionTool do
  @moduledoc false
  @behaviour Handbean.Agent.Tool

  @impl true
  def name, do: "ext__test__ping"

  @impl true
  def description, do: "Simple ping test tool"

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{},
      required: []
    }
  end

  @impl true
  def execute(_input, _context), do: {:ok, "pong"}

  @impl true
  def concurrent?, do: true
end
