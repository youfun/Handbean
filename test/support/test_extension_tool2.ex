defmodule TestExtensionTool2 do
  @moduledoc false
  @behaviour Handbean.Agent.Tool

  @impl true
  def name, do: "ext__test__echo"

  @impl true
  def description, do: "Echo test tool"

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        message: %{type: "string", description: "Message to echo"}
      },
      required: ["message"]
    }
  end

  @impl true
  def execute(%{"message" => msg}, _context), do: {:ok, "echo: #{msg}"}
  def execute(_input, _context), do: {:error, "message is required"}

  @impl true
  def concurrent?, do: true
end
