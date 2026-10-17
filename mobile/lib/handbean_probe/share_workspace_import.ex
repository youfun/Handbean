defmodule HandbeanProbe.ShareWorkspaceImport do
  @moduledoc """
  Confirmed workspace copy for general/mixed share files.
  Owns only `.handbean/shared/<intake_id>/` under the current workspace.
  """

  use Gettext, backend: HandbeanProbe.Gettext

  alias Handbean.Security.PathValidator
  alias HandbeanProbe.ShareIntake

  @max_batch_bytes 25 * 1024 * 1024

  def destination(workspace, intake_id) when is_map(workspace) and is_binary(intake_id) do
    Path.join([workspace["path"], ".handbean", "shared", intake_id])
  end

  @spec accept(map(), map()) :: {:ok, [String.t()]} | {:error, term()}
  def accept(rec, workspace) when is_map(rec) and is_map(workspace) do
    with {:ok, workspace_path, intake_id, dest} <-
           validated_destination(workspace, rec["intake_id"]) do
      case copy_ready_files(rec, dest, workspace_path) do
        {:ok, paths} ->
          {:ok, paths}

        {:error, reason, :owned} ->
          _ = rollback(workspace, intake_id)
          {:error, reason}

        {:error, reason, :not_owned} ->
          {:error, reason}
      end
    end
  end

  @spec schedule_rollback(map(), String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def schedule_rollback(workspace, intake_id, opts \\ [])
      when is_map(workspace) and is_binary(intake_id) do
    supervisor = Keyword.get(opts, :supervisor, HandbeanProbe.TaskSupervisor)

    Task.Supervisor.start_child(supervisor, fn ->
      result = rollback(workspace, intake_id)
      Enum.each(notify_pids(opts), &send(&1, {:share_rollback, intake_id, result}))
      result
    end)
  end

  @spec rollback(map(), String.t()) :: :ok | {:error, term()}
  def rollback(workspace, intake_id) when is_map(workspace) and is_binary(intake_id) do
    with {:ok, _workspace_path, _intake_id, dest} <-
           validated_destination(workspace, intake_id) do
      case File.rm_rf(dest) do
        {:ok, _} -> :ok
        {:error, reason, _} -> {:error, reason}
      end
    end
  end

  def merge_draft(draft, rec, paths) do
    shared =
      [String.trim(to_string(rec["subject"] || "")), String.trim(to_string(rec["text"] || ""))]
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> then(fn text_parts ->
        if paths == [] do
          text_parts
        else
          text_parts ++
            [
              gettext("Shared files (imported into the current workspace):") <>
                "\n" <> Enum.map_join(paths, "\n", &"- #{&1}")
            ]
        end
      end)
      |> Enum.join("\n\n")

    [String.trim(draft || ""), shared]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  def item_label(%{"status" => "ready"} = item) do
    name = string(item["name"])
    size = item["size"] || 0
    "#{name} · #{format_size(size)}"
  end

  def item_label(item) when is_map(item) do
    name = string(item["name"])
    label = if name == "", do: gettext("Shared file"), else: name
    "#{label} · #{reason_label(item["reason"])}"
  end

  def item_label(_), do: gettext("Shared file")

  defp copy_ready_files(rec, destination, workspace_path) do
    intake_id = rec["intake_id"]
    ready = Enum.filter(List.wrap(rec["files"]), &(&1["status"] == "ready"))

    if ready == [] do
      {:ok, []}
    else
      case create_destination(destination, workspace_path) do
        :ok -> copy_ready_files(ready, intake_id, destination, workspace_path)
        {:error, _} -> {:error, :copy_failed, :not_owned}
      end
    end
  end

  defp copy_ready_files(ready, intake_id, destination, workspace_path) do
    Enum.reduce_while(ready, {:ok, [], 0}, fn item, {:ok, paths, total} ->
      source = item["path"]

      with true <- is_binary(source),
           :ok <- validate_source(source, intake_id),
           {:ok, %{type: :regular, size: size}} <- File.lstat(source),
           true <- total + size <= @max_batch_bytes,
           target <- Path.join(destination, Path.basename(source)),
           :ok <- validate_target(target, destination, workspace_path),
           :ok <- copy_exclusive(source, target, size) do
        relative = Path.relative_to(target, workspace_path)
        {:cont, {:ok, paths ++ [relative], total + size}}
      else
        _ -> {:halt, {:error, :copy_failed, :owned}}
      end
    end)
    |> case do
      {:ok, paths, _total} -> {:ok, paths}
      error -> error
    end
  end

  defp create_destination(destination, workspace_path) do
    shared_root = Path.dirname(destination)

    with :ok <- validate_destination(shared_root, workspace_path),
         :ok <- File.mkdir_p(shared_root),
         :ok <- validate_destination(shared_root, workspace_path),
         :ok <- File.mkdir(destination),
         :ok <- validate_destination(destination, workspace_path) do
      :ok
    end
  end

  defp copy_exclusive(source, target, expected_size) do
    with {:ok, body} <- File.read(source),
         true <- byte_size(body) == expected_size,
         {:ok, :ok} <-
           File.open(target, [:write, :binary, :exclusive], &IO.binwrite(&1, body)) do
      :ok
    else
      _ -> {:error, :copy_failed}
    end
  end

  defp validate_source(source, id) do
    expected = Path.join(ShareIntake.root(), id)

    with :ok <- PathValidator.validate_within_workspace(source, expected),
         :ok <- PathValidator.validate_within_workspace(expected, ShareIntake.root()) do
      :ok
    end
  end

  defp validated_destination(workspace, intake_id) do
    workspace_path = workspace["path"]

    with true <- is_binary(workspace_path),
         {:ok, intake_id} <- Ecto.UUID.cast(intake_id),
         destination = destination(workspace, intake_id),
         :ok <- validate_destination(destination, workspace_path) do
      {:ok, workspace_path, intake_id, destination}
    else
      _ -> {:error, :outside_workspace}
    end
  end

  defp validate_destination(destination, workspace_path) when is_binary(workspace_path),
    do: PathValidator.validate_within_workspace(destination, workspace_path)

  defp validate_destination(_destination, _workspace_path), do: {:error, :outside_workspace}

  defp validate_target(target, destination, workspace_path) do
    with :ok <- PathValidator.validate_within_workspace(target, workspace_path),
         :ok <- PathValidator.validate_within_workspace(target, destination) do
      :ok
    end
  end

  defp string(value) when is_binary(value), do: value
  defp string(_), do: ""

  defp format_size(size) when is_integer(size) and size >= 1024 * 1024,
    do: "#{Float.round(size / (1024 * 1024), 1)} MB"

  defp format_size(size) when is_integer(size) and size >= 1024,
    do: "#{Float.round(size / 1024, 1)} KB"

  defp format_size(size) when is_integer(size), do: "#{size} B"
  defp format_size(_), do: gettext("Unknown size")

  defp notify_pids(opts) do
    [Keyword.get(opts, :notify), Application.get_env(:handbean_probe, :share_io_notify)]
    |> Enum.filter(&(is_pid(&1) and Process.alive?(&1)))
    |> Enum.uniq()
  end

  defp reason_label("too_many_files"), do: gettext("Up to 4 files per share")
  defp reason_label("file_too_large"), do: gettext("File exceeds 20 MB")
  defp reason_label("batch_too_large"), do: gettext("Shared files exceed 25 MB")
  defp reason_label("unsupported_uri"), do: gettext("Unsupported file source")
  defp reason_label(_), do: gettext("Could not read file")
end
