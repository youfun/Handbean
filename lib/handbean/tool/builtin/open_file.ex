defmodule Handbean.Tool.Builtin.OpenFile do
  @moduledoc "Open a workspace artifact via a fixed ExportSnapshot and the system viewer."

  @behaviour Handbean.Agent.Tool

  alias Handbean.Tool.Builtin.ArtifactFile

  @impl true
  def name, do: "open_file"

  @impl true
  def description do
    "Open a workspace file (report, image, PDF, text, or archive) with a system " <>
      "viewer. Pass only a workspace-relative path. The approved bytes come from a " <>
      "fixed export copy, not a live path. Success means the viewer UI was shown, " <>
      "not that the other app finished reading the file."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      additionalProperties: false,
      required: ["path"],
      properties: %{
        path: %{
          type: "string",
          maxLength: 1024,
          description: "Workspace-relative file path. No absolute paths or traversal."
        },
        description: %{
          type: "string",
          maxLength: 200,
          description: "Optional short label shown on the approval card."
        }
      }
    }
  end

  @impl true
  def concurrent?, do: false

  @impl true
  def execute(input, context), do: ArtifactFile.execute(:open_file, input, context)
end
