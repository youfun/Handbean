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
  @max_baseline_files 128
  @max_baseline_bytes 8_000_000
  @max_capture_files 32
  @max_candidate_files 128
  @max_capture_bytes 8_000_000

  @type capture :: map() | nil

  @spec start(Path.t() | nil) :: capture()
  def start(workspace) when is_binary(workspace) and workspace != "" do
    workspace = Path.expand(workspace)

    case CLI.open(workspace, ceiling: Path.dirname(workspace)) do
      {:ok, repo} -> start_repo(repo, workspace)
      {:error, _reason} -> nil
    end
  end

  def start(_workspace), do: nil

  defp start_repo(repo, workspace) do
    with {:ok, repo_root} <- CLI.workdir(repo),
         true <- inside?(workspace, repo_root),
         {:ok, status} <- CLI.status(repo),
         {:ok, tracked} <- CLI.tracked_files(repo) do
      paths = status_paths(status, repo_root, workspace) |> Enum.sort()
      {before, _bytes} = capture_baseline(paths, workspace)

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
        before: before
      }
    else
      _ -> %{unavailable: true}
    end
  end

  @spec finish(capture(), map()) :: map()
  def finish(nil, _context), do: empty_result()

  def finish(%{unavailable: true}, _context) do
    Map.merge(empty_result(), %{
      truncated: true,
      omitted_paths: nil,
      reason: "baseline_unavailable"
    })
  end

  def finish(capture, context) when is_map(capture) and is_map(context) do
    with {:ok, status} <- CLI.status(capture.repo) do
      after_paths = status_paths(status, capture.repo_root, capture.workspace)
      committed_paths = committed_paths(capture)

      paths =
        capture.before_paths
        |> MapSet.union(MapSet.new(after_paths))
        |> MapSet.union(MapSet.new(committed_paths))
        |> Enum.sort()

      result = Enum.reduce(paths, empty_result(), &record_change(&1, capture, context, &2))
      %{result | changes: Enum.reverse(result.changes)}
    else
      _ ->
        Map.merge(empty_result(), %{
          truncated: true,
          omitted_paths: nil,
          reason: "status_unavailable"
        })
    end
  end

  def finish(_capture, _context), do: empty_result()

  defp empty_result do
    %{changes: [], truncated: false, omitted_paths: 0, snapshot_bytes: 0, examined_paths: 0}
  end

  defp capture_baseline(paths, workspace) do
    paths
    |> Enum.take(@max_baseline_files)
    |> Enum.reduce({%{}, 0}, fn path, {before, bytes} ->
      state = file_state(path, workspace)
      size = state_bytes(state)

      if bytes + size <= @max_baseline_bytes do
        {Map.put(before, path, state), bytes + size}
      else
        {before, bytes}
      end
    end)
  end

  defp state_bytes({:file, content}), do: byte_size(content)
  defp state_bytes(_state), do: 0

  @spec persist(map(), map(), keyword()) :: map()
  def persist(result, context, opts \\ [])

  def persist(%{changes: changes} = result, context, opts) when is_map(context) do
    conversation_id = context[:conversation_id] || context["conversation_id"]
    run_id = context[:run_id] || context["run_id"]
    tool_call_id = context[:tool_call_id] || context["tool_call_id"]
    entry_id = Keyword.get(opts, :entry_id) || effect_entry_id(tool_call_id)

    if (changes != [] or result.truncated) and is_binary(conversation_id) and
         is_binary(entry_id) do
      entry = %{
        "id" => entry_id,
        "role" => "system",
        "content_type" => "file_change_batch",
        "status" => "completed",
        "run_id" => run_id,
        "tool_call_id" => tool_call_id,
        "details" => %{
          "changes" => changes,
          "truncated" => result.truncated,
          "omitted_paths" => result.omitted_paths,
          "snapshot_bytes" => result.snapshot_bytes,
          "reason" => Map.get(result, :reason)
        }
      }

      try do
        case Handbean.ConversationTranscriptStore.append(
               conversation_id,
               entry,
               Keyword.take(opts, [:transcript_store])
             ) do
          {:ok, _entry} ->
            result

          {:error, reason} when reason in [:duplicate_id, :not_found] ->
            if Handbean.ConversationTranscriptStore.impl(opts) ==
                 Handbean.ConversationTranscriptStore.ConversationStore do
              discard_uncommitted(result)
            else
              result
            end

          {:error, _reason} ->
            result
        end
      rescue
        _error -> result
      catch
        :exit, _reason -> result
      end
    else
      result
    end
  end

  def persist(result, _context, _opts), do: result

  defp discard_uncommitted(result) do
    outcomes =
      result.changes
      |> Enum.map(&Map.get(&1, :change_snapshot_ref))
      |> Enum.filter(&is_binary/1)
      |> ChangeSnapshot.delete_uncommitted_batch()
      |> Map.new()

    changes =
      Enum.map(result.changes, fn change ->
        ref = Map.get(change, :change_snapshot_ref)

        case Map.fetch(outcomes, ref) do
          {:ok, {:error, :snapshot_referenced}} ->
            change

          {:ok, _outcome} ->
            change
            |> Map.delete(:change_snapshot_ref)
            |> Map.merge(%{
              reversible: false,
              revert_status: "unavailable",
              revert_reason: "snapshot_unavailable"
            })

          :error ->
            change
        end
      end)

    %{result | changes: changes}
  end

  defp effect_entry_id(tool_call_id) when is_binary(tool_call_id) and tool_call_id != "" do
    digest = :crypto.hash(:sha256, tool_call_id) |> Base.url_encode64(padding: false)
    "file-effects-tool-#{digest}"
  end

  defp effect_entry_id(_tool_call_id), do: nil

  defp record_change(_path, _capture, _context, %{changes: changes} = result)
       when length(changes) >= @max_capture_files do
    omit_path(result)
  end

  defp record_change(_path, _capture, _context, %{examined_paths: count} = result)
       when count >= @max_candidate_files do
    omit_path(result)
  end

  defp record_change(path, capture, context, result) do
    result = %{result | examined_paths: result.examined_paths + 1}
    before = before_state(path, capture)

    if before in [:unknown, :unsupported] do
      omit_path(result)
    else
      after_state = file_state(path, capture.workspace)

      cond do
        after_state == :unsupported ->
          omit_path(result)

        before == after_state ->
          result

        true ->
          case snapshot(path, before, after_state) do
            nil -> omit_path(result)
            snapshot -> add_snapshot(snapshot, context, result)
          end
      end
    end
  end

  defp add_snapshot(snapshot, context, result) do
    encoded = Handbean.JSON.encode!(Handbean.JsonSafe.normalize(snapshot))
    bytes = byte_size(encoded)

    if result.snapshot_bytes + bytes > @max_capture_bytes do
      omit_path(result)
    else
      change = ChangeSnapshot.result_details(snapshot, context)

      %{
        result
        | changes: [change | result.changes],
          snapshot_bytes: result.snapshot_bytes + bytes
      }
    end
  end

  defp omit_path(result) do
    %{result | truncated: true, omitted_paths: result.omitted_paths + 1}
  end

  defp before_state(path, capture) do
    case Map.fetch(capture.before, path) do
      {:ok, state} ->
        state

      :error ->
        if MapSet.member?(capture.before_paths, path),
          do: :unknown,
          else: head_state(path, capture)
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
        with {:ok, size} <- CLI.revision_file_size(capture.repo, capture.head, relative),
             true <- size <= @max_file_bytes,
             {:ok, content} <- CLI.read_revision_file(capture.repo, capture.head, relative),
             true <- byte_size(content) <= @max_file_bytes do
          {:file, content}
        else
          _ -> :unsupported
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
        case File.open(path, [:read, :binary], &IO.binread(&1, @max_file_bytes + 1)) do
          {:ok, content} when is_binary(content) and byte_size(content) <= @max_file_bytes ->
            {:file, content}

          {:ok, :eof} ->
            {:file, ""}

          _ ->
            :unsupported
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
