defmodule Handbean.WorkspaceChangeCapture do
  @moduledoc """
  Captures Git-worktree file effects around one trusted tool execution.

  The capture starts from the workspace's current dirty state, so pre-existing
  changes are not attributed to the tool. Only paths whose content changes
  between `start/1` and `finish/2` produce persisted change snapshots.

  This is execution-window capture, not process-level filesystem attribution.
  A writer outside Handbean that overlaps the same window can still affect the
  observed result; callers must not present it as strict concurrent attribution.
  """

  alias Handbean.ChangeSnapshot
  alias Handbean.Git.CLI
  alias Handbean.Security.PathValidator

  @max_file_bytes 1_000_000

  @type capture :: map() | nil

  @spec start(Path.t() | nil) :: capture()
  def start(workspace) when is_binary(workspace) and workspace != "" do
    workspace = Path.expand(workspace)

    with {:ok, repo} <- CLI.open(workspace, ceiling: Path.dirname(workspace)),
         {:ok, repo_root} <- CLI.workdir(repo),
         true <- inside?(workspace, repo_root),
         {:ok, status} <- CLI.status(repo),
         {:ok, tracked} <- CLI.tracked_files(repo) do
      paths = status_paths(status, repo_root, workspace)

      head =
        case CLI.head_oid(repo) do
          {:ok, oid} -> oid
          {:error, _reason} -> nil
        end

      %{
        repo: repo,
        repo_root: repo_root,
        workspace: workspace,
        head: head,
        tracked: tracked,
        before_paths: MapSet.new(paths),
        before: Map.new(paths, &{&1, file_state(&1, workspace)})
      }
    else
      _ -> nil
    end
  end

  def start(_workspace), do: nil

  @spec finish(capture(), map()) :: [map()]
  def finish(nil, _context), do: []

  def finish(capture, context) when is_map(capture) and is_map(context) do
    with {:ok, status} <- CLI.status(capture.repo) do
      after_paths = status_paths(status, capture.repo_root, capture.workspace)
      committed_paths = committed_paths(capture)

      capture.before_paths
      |> MapSet.union(MapSet.new(after_paths))
      |> MapSet.union(MapSet.new(committed_paths))
      |> Enum.sort()
      |> Enum.flat_map(&record_change(&1, capture, context))
    else
      _ -> []
    end
  end

  def finish(_capture, _context), do: []

  @spec persist([map()], map(), keyword()) :: :ok
  def persist(changes, context, opts \\ [])

  def persist(changes, context, opts) when is_list(changes) and is_map(context) do
    conversation_id = context[:conversation_id] || context["conversation_id"]
    run_id = context[:run_id] || context["run_id"]
    tool_call_id = context[:tool_call_id] || context["tool_call_id"]
    entry_id = Keyword.get(opts, :entry_id) || effect_entry_id(tool_call_id)

    if changes != [] and is_binary(conversation_id) and is_binary(entry_id) do
      entry = %{
        "id" => entry_id,
        "role" => "system",
        "content_type" => "file_change_batch",
        "status" => "completed",
        "run_id" => run_id,
        "tool_call_id" => tool_call_id,
        "details" => %{"changes" => changes}
      }

      try do
        case Handbean.ConversationTranscriptStore.append(conversation_id, entry) do
          {:ok, _entry} -> :ok
          {:error, :duplicate_id} -> :ok
          {:error, _reason} -> :ok
        end
      rescue
        _error -> :ok
      catch
        :exit, _reason -> :ok
      end
    else
      :ok
    end
  end

  def persist(_changes, _context, _opts), do: :ok

  defp effect_entry_id(tool_call_id) when is_binary(tool_call_id) and tool_call_id != "" do
    digest = :crypto.hash(:sha256, tool_call_id) |> Base.url_encode64(padding: false)
    "file-effects-tool-#{digest}"
  end

  defp effect_entry_id(_tool_call_id), do: nil

  defp record_change(path, capture, context) do
    before = before_state(path, capture)
    after_state = file_state(path, capture.workspace)

    if before == after_state do
      []
    else
      case snapshot(path, before, after_state) do
        nil -> []
        snapshot -> [ChangeSnapshot.result_details(snapshot, context)]
      end
    end
  end

  defp before_state(path, capture) do
    case Map.fetch(capture.before, path) do
      {:ok, state} -> state
      :error -> head_state(path, capture)
    end
  end

  defp head_state(path, capture) do
    relative = Path.relative_to(path, capture.repo_root)

    cond do
      not MapSet.member?(capture.tracked, relative) ->
        :missing

      not is_binary(capture.head) ->
        :unsupported

      true ->
        case CLI.read_revision_file(capture.repo, capture.head, relative) do
          {:ok, content} when byte_size(content) <= @max_file_bytes -> {:file, content}
          {:ok, _content} -> :unsupported
          {:error, _reason} -> :unsupported
        end
    end
  end

  defp file_state(path, workspace) do
    with :ok <- PathValidator.validate_within_workspace(path, workspace),
         :ok <- PathValidator.reject_resolved(path) do
      read_file_state(path)
    else
      _ -> :unsupported
    end
  end

  defp read_file_state(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_file_bytes ->
        case File.read(path) do
          {:ok, content} -> {:file, content}
          {:error, _reason} -> :unsupported
        end

      {:error, :enoent} ->
        :missing

      _ ->
        :unsupported
    end
  end

  defp snapshot(path, :missing, {:file, after_content}) do
    ChangeSnapshot.build_write_snapshot(path, nil, after_content)
  end

  defp snapshot(path, {:file, before_content}, {:file, after_content}) do
    ChangeSnapshot.build_edit_snapshot(path, before_content, after_content)
  end

  defp snapshot(path, {:file, before_content}, :missing) do
    ChangeSnapshot.build_delete_snapshot(path, before_content)
  end

  defp snapshot(_path, _before, _after), do: nil

  defp status_paths(%{entries: entries}, repo_root, workspace) when is_list(entries) do
    entries
    |> Enum.flat_map(fn entry -> [entry[:path], entry[:old_path]] end)
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&Path.expand(&1, repo_root))
    |> Enum.filter(&inside?(&1, workspace))
    |> Enum.uniq()
  end

  defp status_paths(_status, _repo_root, _workspace), do: []

  defp committed_paths(%{head: head} = capture) when is_binary(head) do
    with {:ok, current_head} <- CLI.head_oid(capture.repo),
         false <- current_head == head,
         {:ok, paths} <- CLI.changed_paths(capture.repo, head, current_head) do
      paths
      |> Enum.map(&Path.expand(&1, capture.repo_root))
      |> Enum.filter(&inside?(&1, capture.workspace))
    else
      _ -> []
    end
  end

  defp committed_paths(_capture), do: []

  defp inside?(path, root) do
    relative = Path.relative_to(Path.expand(path), Path.expand(root))
    relative == "." or (relative != ".." and not String.starts_with?(relative, "../"))
  end
end
