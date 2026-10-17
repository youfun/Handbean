defmodule Handbean.Tool.Extension.MountDrop do
  @moduledoc "Unmount an in-memory extension created by ext__mount__apply."

  @behaviour Handbean.Agent.Tool

  @impl true
  def name, do: "ext__mount__drop"

  @impl true
  def description do
    "Remove an in-memory mount by id: unregister its tools and stop its workers."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        name: %{type: "string", description: "Mount id from ext__mount__apply"}
      },
      required: ["name"]
    }
  end

  @impl true
  def concurrent?, do: false

  @impl true
  def execute(%{"name" => name}, _context) when is_binary(name) do
    :ok = Handbean.Extension.Mount.unmount(name)
    {:ok, "unmounted #{name}"}
  end

  def execute(_input, _context), do: {:error, "name is required"}
end
