defmodule Handbean.Tool.Extension.MountApply do
  @moduledoc "Compile an in-memory extension from source and register its tools."

  @behaviour Handbean.Agent.Tool

  @impl true
  def name, do: "ext__mount__apply"

  @impl true
  def description do
    "Compile Elixir source in memory and register ext__* tools / child_spec workers. " <>
      "Does not write disk. Use ext__mount__drop to remove. " <>
      "To keep a plugin, write it to .handbean/extensions instead."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        name: %{type: "string", description: "Mount id (re-apply replaces the same id)"},
        source: %{
          type: "string",
          description: "Elixir source defining Tool and/or child_spec modules"
        }
      },
      required: ["name", "source"]
    }
  end

  @impl true
  def concurrent?, do: false

  @impl true
  def execute(%{"name" => name, "source" => source}, _context)
      when is_binary(name) and is_binary(source) do
    case Handbean.Extension.Mount.mount(source, name: name) do
      {:ok, mount} ->
        tools = Enum.join(mount.tools, ", ")
        {:ok, "mounted #{mount.id} tools=[#{tools}]"}

      {:error, diags} ->
        {:error, Enum.map_join(diags, "; ", & &1.message)}
    end
  end

  def execute(_input, _context), do: {:error, "name and source are required"}
end
