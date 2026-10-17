defmodule Handbean.Agent.Subagent.Worktree do
  @moduledoc """
  Git worktrees that isolate write-mode subagents from the parent workspace.

  A worktree is detached at the parent's `HEAD`; uncommitted parent changes
  are not visible to the child. `apply/2` checks the whole patch before
  applying it and rolls it back if worktree cleanup fails.
  """

  @dir ".handbean/worktrees"
  @orphan_age_s 24 * 3600

  @spec path(String.t(), String.t()) :: String.t()
  def path(workspace, child_id), do: Path.join([Path.expand(workspace), @dir, child_id])

  @spec create(String.t(), String.t()) ::
          {:ok, %{path: String.t(), base: String.t()}} | {:error, String.t()}
  def create(workspace, child_id) do
    path = path(workspace, child_id)

    with :ok <- valid_id(child_id),
         {:ok, base} <- git(workspace, ["rev-parse", "HEAD"]),
         :ok <- exclude(workspace),
         {:ok, _} <- git(workspace, ["worktree", "add", "--detach", path, "HEAD"]) do
      sweep(workspace, [child_id])
      {:ok, %{path: path, base: String.trim(base)}}
    end
  end

  @doc "Diff of the child's worktree against its baseline, including new files."
  @spec diff(String.t(), String.t()) ::
          {:ok, %{base: String.t(), stat: String.t(), patch: String.t()}} | {:error, String.t()}
  def diff(workspace, child_id) do
    path = path(workspace, child_id)

    with :ok <- valid_id(child_id),
         true <- File.dir?(path) || {:error, "worktree #{child_id} does not exist"},
         {:ok, base} <- git(path, ["rev-parse", "HEAD"]),
         {:ok, _} <- git(path, ["add", "--all", "--intent-to-add", "."]),
         {:ok, stat} <- git(path, ["diff", "--stat", "HEAD"]),
         {:ok, patch} <- git(path, ["diff", "--binary", "HEAD"]) do
      {:ok, %{base: String.trim(base), stat: String.trim(stat), patch: patch}}
    end
  end

  @doc "Apply the whole diff, removing the worktree or rolling the parent patch back."
  @spec apply(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def apply(workspace, child_id) do
    with {:ok, %{patch: patch, stat: stat}} <- diff(workspace, child_id),
         :ok <- apply_patch(workspace, patch),
         :ok <- discard_after_apply(workspace, child_id, patch) do
      {:ok, stat}
    end
  end

  @spec discard(String.t(), String.t()) :: :ok | {:error, String.t()}
  def discard(workspace, child_id) do
    with :ok <- valid_id(child_id) do
      path = path(workspace, child_id)

      if File.dir?(path) do
        with {:ok, _} <- git(workspace, ["worktree", "remove", "--force", path]), do: :ok
      else
        _ = git(workspace, ["worktree", "prune"])
        :ok
      end
    end
  end

  @doc "Remove worktrees older than a day that are not in `keep`."
  @spec sweep(String.t(), [String.t()]) :: :ok
  def sweep(workspace, keep) do
    root = Path.join(Path.expand(workspace), @dir)
    now = System.os_time(:second)
    keep = keep ++ recoverable_ids(workspace)

    case File.ls(root) do
      {:ok, names} ->
        for name <- names, name not in keep, old?(Path.join(root, name), now) do
          discard(workspace, name)
        end

        :ok

      _ ->
        :ok
    end
  end

  defp recoverable_ids(workspace) do
    Handbean.ConversationArtifacts.root()
    |> Path.join("items/*/subagents/*.json")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      case File.read(path) do
        {:ok, body} ->
          case Handbean.JSON.decode(body) do
            {:ok, artifact} when is_map(artifact) ->
              id = artifact["id"]
              status = artifact["status"]

              if artifact_checkout(artifact) == workspace and is_binary(id) and
                   status not in ["applied", "discarded"] do
                [id]
              else
                []
              end

            _ ->
              []
          end

        _ ->
          []
      end
    end)
  end

  defp artifact_checkout(artifact) do
    artifact["parent_checkout_path"] || artifact["checkout_path"] || artifact["workspace"]
  end

  defp old?(path, now) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> now - mtime > @orphan_age_s
      _ -> false
    end
  end

  defp apply_patch(_workspace, ""), do: :ok

  defp apply_patch(workspace, patch) do
    run_patch(workspace, patch, [])
  end

  defp discard_after_apply(workspace, child_id, patch) do
    case discard(workspace, child_id) do
      :ok ->
        :ok

      {:error, discard_reason} ->
        case rollback_patch(workspace, patch) do
          :ok ->
            {:error, "#{discard_reason}; workspace patch was rolled back"}

          {:error, rollback_reason} ->
            {:error,
             "#{discard_reason}; rollback failed (#{rollback_reason}); workspace may contain the applied patch"}
        end
    end
  end

  defp rollback_patch(_workspace, ""), do: :ok

  defp rollback_patch(workspace, patch) do
    run_patch(workspace, patch, ["--reverse"])
  end

  defp run_patch(workspace, patch, mode) do
    file =
      Path.join(
        System.tmp_dir!(),
        "handbean-subagent-#{System.unique_integer([:positive])}.patch"
      )

    File.write!(file, patch)

    try do
      with {:ok, _} <- git(workspace, ["apply", "--check", "--binary"] ++ mode ++ [file]),
           {:ok, _} <- git(workspace, ["apply", "--binary"] ++ mode ++ [file]) do
        :ok
      end
    after
      File.rm(file)
    end
  end

  defp exclude(workspace) do
    case git(workspace, ["rev-parse", "--git-path", "info/exclude"]) do
      {:ok, rel} ->
        file = Path.expand(String.trim(rel), workspace)
        line = "/" <> @dir <> "/"
        existing = if File.exists?(file), do: File.read!(file), else: ""

        unless line in String.split(existing, "\n") do
          File.mkdir_p!(Path.dirname(file))
          prefix = if existing == "" or String.ends_with?(existing, "\n"), do: "", else: "\n"
          File.write!(file, existing <> prefix <> line <> "\n")
        end

        :ok

      error ->
        error
    end
  end

  defp valid_id(id) do
    if Regex.match?(~r/\A[A-Za-z0-9_-]{1,128}\z/, id), do: :ok, else: {:error, "invalid child id"}
  end

  defp git(dir, args) do
    case System.cmd("git", args,
           cd: dir,
           stderr_to_stdout: true,
           env: [{"GIT_TERMINAL_PROMPT", "0"}]
         ) do
      {out, 0} -> {:ok, out}
      {out, _} -> {:error, "git #{hd(args)} failed: #{String.trim(out)}"}
    end
  rescue
    error -> {:error, "git unavailable: #{Exception.message(error)}"}
  end
end
