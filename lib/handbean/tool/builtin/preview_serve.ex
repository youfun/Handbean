defmodule Handbean.Tool.Builtin.PreviewServe do
  @moduledoc """
  Register a workspace directory or loopback port as a preview.

  Does not execute arbitrary `.exs`. Showing the shell is a separate
  user action from the conversation card.
  """

  @behaviour Handbean.Agent.Tool

  alias Handbean.Preview

  @impl true
  def name, do: "preview_serve"

  @impl true
  def description do
    "Register a static workspace directory or an already-running loopback " <>
      "port for in-app preview. Returns a preview_id. The user opens the " <>
      "unified PreviewShell card; this tool does not replace the chat WebView."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      additionalProperties: false,
      required: ["kind"],
      properties: %{
        kind: %{
          type: "string",
          enum: ["files", "port"],
          description: "files serves a directory; port reverse-proxies 127.0.0.1:<port>."
        },
        path: %{
          type: "string",
          description: "Workspace-relative or absolute directory for kind=files."
        },
        port: %{
          type: "integer",
          minimum: 1,
          maximum: 65_535,
          description: "Already-listening loopback port for kind=port."
        },
        title: %{type: "string", description: "Optional title shown on the preview card."}
      }
    }
  end

  @impl true
  def concurrent?, do: false

  @impl true
  def execute(input, context) when is_map(input) and is_map(context) do
    conversation_id = context[:conversation_id] || "anon"
    workspace_id = context[:workspace_id]
    workspace_path = context[:working_directory]

    case field(input, "kind") do
      "files" ->
        register_files(input, conversation_id, workspace_id, workspace_path)

      "port" ->
        register_port(input, conversation_id, workspace_id)

      nil ->
        {:error, "kind is required"}

      other ->
        {:error, "unsupported preview kind: #{other}"}
    end
  end

  def execute(_input, _context), do: {:error, "invalid preview_serve input"}

  defp register_files(input, conversation_id, workspace_id, workspace_path) do
    case field(input, "path") do
      path when is_binary(path) and path != "" ->
        abs = resolve_dir(path, workspace_path)

        case Preview.register_files(conversation_id, abs,
               workspace_id: workspace_id,
               workspace_path: workspace_path,
               title: field(input, "title")
             ) do
          {:ok, record} -> {:ok, card_text(record), details(record)}
          {:error, :not_a_directory} -> {:error, "preview path is not a directory"}
          {:error, :outside_workspace} -> {:error, "preview path is outside the workspace"}
          {:error, reason} -> {:error, format(reason)}
        end

      _ ->
        {:error, "path is required"}
    end
  end

  defp register_port(input, conversation_id, workspace_id) do
    case field(input, "port") do
      port when is_integer(port) ->
        case Preview.register_port(conversation_id, port,
               workspace_id: workspace_id,
               title: field(input, "title")
             ) do
          {:ok, record} -> {:ok, card_text(record), details(record)}
          {:error, :invalid_port} -> {:error, "port must be a loopback TCP port"}
          {:error, reason} -> {:error, format(reason)}
        end

      _ ->
        {:error, "port is required"}
    end
  end

  defp resolve_dir(path, workspace_path) when is_binary(workspace_path) do
    if Path.type(path) == :absolute,
      do: Path.expand(path),
      else: Path.expand(path, workspace_path)
  end

  defp resolve_dir(path, _), do: Path.expand(path)

  defp card_text(record) do
    "Preview ready: #{record.title} (#{record.id})"
  end

  defp details(record) do
    %{
      preview_id: record.id,
      conversation_id: record.conversation_id,
      kind: Atom.to_string(record.kind),
      title: record.title,
      preview_path: Preview.shell_path(record.id),
      return_href: Preview.return_href(record.conversation_id)
    }
  end

  defp field(map, key), do: Map.get(map, key) || Map.get(map, field_atom(key))
  defp field_atom("kind"), do: :kind
  defp field_atom("path"), do: :path
  defp field_atom("port"), do: :port
  defp field_atom("title"), do: :title
  defp field_atom(_), do: nil

  defp format(reason) when is_binary(reason), do: reason
  defp format(reason), do: inspect(reason)
end
