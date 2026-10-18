defmodule Handbean.Tool.Builtin.ShareFile do
  @moduledoc "Share a workspace artifact via a fixed ExportSnapshot and the system chooser."

  @behaviour Handbean.Agent.Tool

  alias Handbean.Tool.Builtin.ArtifactFile

  @impl true
  def name, do: "share_file"

  @impl true
  def description do
    "Share a workspace file (report, image, PDF, or code archive) through the " <>
      "system share sheet so the user can hand it to another app. " <>
      "Pass only a workspace-relative path. The approved bytes come from a fixed " <>
      "export copy. Success means the chooser was shown, not that the file was sent."
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
  def execute(input, context), do: ArtifactFile.execute(:share_file, input, context)
end
