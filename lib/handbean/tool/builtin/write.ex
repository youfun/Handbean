defmodule Handbean.Tool.Builtin.Write do
  alias Handbean.Agent.Tool.Helpers

  @moduledoc """
  Write content to a file. Creates the file and parent directories as needed.

  Overwrites existing files. Used for creating new files or completely rewriting.
  For precise edits, use the Edit tool instead.
  """

  @behaviour Handbean.Agent.Tool

  @impl true
  def name, do: "write"

  @impl true
  def description do
    "Write content to a file, creating parent directories if needed. " <>
      "Overwrites existing files. Use write for new files, small full-file rewrites, " <>
      "or broad changes where replacing the whole file is clearer than many edits. " <>
      "Use edit for precise text replacements, including multiple replacements in one call."
  end

  @impl true
  def hint do
    "Use a workspace-relative file_path by default. A leading / is filesystem root, not the workspace. " <>
      "Paths outside the workspace require yolo mode. " <>
      "For a precise change to an existing file, use edit instead of rewriting the whole file."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        file_path: %{
          type: "string",
          description:
            "File path. Prefer a workspace-relative path such as workspace-check.txt or reports/summary.md. A leading / means filesystem root, not workspace root; paths outside the workspace require yolo mode."
        },
        content: %{type: "string", description: "Content to write to the file"},
        retry_of: %{
          type: "string",
          description:
            "operation_id from a failed write. Reuses the saved content; send only the small field that changed. Mutually exclusive with content."
        }
      },
      required: ["file_path"]
    }
  end

  @impl true
  def max_result_chars, do: 2_000

  @impl true
  def concurrent?, do: false

  @impl true
  def execute(%{"file_path" => file_path, "content" => content} = input, context)
      when is_binary(content) do
    with {:ok, path} <- Handbean.Agent.Tool.resolve_path(Helpers.expand_tilde(file_path), context),
         {:ok, _input, operation_id} <-
           Handbean.Agent.Tool.SavedInput.prepare("write", input, context, ["file_path"]) do
      result = write_prepared(path, content, operation_id, context)
      Handbean.Agent.Tool.SavedInput.attach(operation_id, result, context)
    end
  end

  def execute(%{"retry_of" => ref, "file_path" => _file_path} = input, context)
      when is_binary(ref) do
    with {:ok, input, operation_id} <-
           Handbean.Agent.Tool.SavedInput.prepare("write", input, context, ["file_path"]),
         {:ok, content} <- fetch_content(input, operation_id),
         {:ok, path} <-
           Handbean.Agent.Tool.resolve_path(Helpers.expand_tilde(input["file_path"]), context) do
      result = write_prepared(path, content, operation_id, context)
      Handbean.Agent.Tool.SavedInput.attach(operation_id, result, context)
    end
  end

  def execute(_input, _context) do
    {:error, "file_path and either content or retry_of are required"}
  end

  defp write_prepared(path, content, operation_id, context) do
    with :ok <- validate_within_workspace(path, context),
         :ok <- reject_directory_target(path),
         :ok <- Handbean.Security.PathValidator.validate_writeable(Path.dirname(path)),
         {:ok, before_content} <- read_before_content(path),
         :ok <- create_parent_dirs(path) do
      write_resolved(path, content, before_content, operation_id, context)
    end
  end

  defp write_resolved(path, content, before_content, operation_id, context) do
    case Handbean.Agent.Tool.FileCommit.commit(path, content, context, operation_id: operation_id) do
      {:ok, commit} ->
        _ = Handbean.Extension.HotReloader.notify_path(path)
        bytes = byte_size(content)
        lines = length(String.split(content, "\n"))
        change = Handbean.ChangeSnapshot.build_write_snapshot(path, before_content, content)
        change_details = Handbean.ChangeSnapshot.result_details(change, context)

        {:ok, "Wrote #{path} (#{bytes} bytes, #{lines} lines)",
         Map.merge(change_details, %{
           operation_id: operation_id,
           status: :succeeded,
           side_effect: commit.side_effect,
           file_path: path,
           bytes: bytes,
           lines: lines,
           diff_lines: change.diff_lines
         })}

      {:error, reason, details} ->
        {:error, reason, Map.merge(details, %{allowed_overrides: ["file_path"]})}
    end
  end

  defp fetch_content(%{"content" => content}, _operation_id) when is_binary(content),
    do: {:ok, content}

  defp fetch_content(_input, operation_id) do
    Handbean.Agent.Tool.SavedInput.failure(operation_id, "file_path and content are required", %{
      allowed_overrides: ["file_path"]
    })
  end

  defp read_before_content(path) do
    if File.exists?(path) do
      case File.read(path) do
        {:ok, content} -> {:ok, content}
        {:error, reason} -> {:error, "Cannot read existing file #{path}: #{reason}"}
      end
    else
      {:ok, nil}
    end
  end

  defp create_parent_dirs(path) do
    dir = Path.dirname(path)

    if File.exists?(dir) do
      :ok
    else
      case File.mkdir_p(dir) do
        :ok -> :ok
        {:error, reason} -> {:error, "Cannot create directory #{dir}: #{reason}"}
      end
    end
  end

  # Validates the resolved path stays within workspace, including symlink resolution.
  defp validate_within_workspace(path, %{working_directory: wd} = context)
       when is_binary(wd) do
    if Handbean.Agent.Tool.outside_workspace_allowed?(context),
      do: :ok,
      else: Handbean.Security.PathValidator.validate_within_workspace(path, wd)
  end

  defp validate_within_workspace(_path, _context), do: :ok

  # Rejects write to an existing directory target (BDD-WRITE-006).
  defp reject_directory_target(path) do
    case File.stat(path) do
      {:ok, %{type: :directory}} -> {:error, "#{path}: Is a directory"}
      _ -> :ok
    end
  end
end
