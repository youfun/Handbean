defmodule Handbean.CodeIndex.Sync do
  @moduledoc """
  Incremental index sync for one workspace.

  One writer per workspace id. Cancellation is cooperative: the tool task sets
  the flag, and the loop stops before the next file. Chunks and FTS updates
  commit per file.
  """

  alias Handbean.CodeIndex.{Chunk, Scan, Store}
  alias Handbean.Security.PathValidator

  @max_chunks 20_000

  @type outcome :: %{
          status: :ready | :partial | :stale,
          files: non_neg_integer(),
          cancelled: boolean(),
          safety: :checked | :not_checked | :failed
        }

  @spec writer_key(String.t()) :: {:code_index_writer, String.t()}
  def writer_key(workspace_id), do: {:code_index_writer, workspace_id}

  @spec claim(String.t()) :: :ok | :busy
  def claim(workspace_id) do
    key = writer_key(workspace_id)

    case :global.register_name(key, self()) do
      :yes ->
        :ok

      :no ->
        case :global.whereis_name(key) do
          :undefined -> claim(workspace_id)
          pid when is_pid(pid) -> if Process.alive?(pid), do: :busy, else: reclaim(key)
        end
    end
  end

  defp reclaim({:code_index_writer, workspace_id}) do
    :global.unregister_name(writer_key(workspace_id))
    claim(workspace_id)
  end

  @spec release(String.t()) :: :ok
  def release(workspace_id) do
    key = writer_key(workspace_id)

    if :global.whereis_name(key) == self() do
      :global.unregister_name(key)
    end

    :ok
  end

  @spec sync(Store.t(), Path.t(), non_neg_integer(), keyword()) :: outcome()
  def sync(store, workspace_root, budget_ms, opts \\ []) do
    deadline = System.monotonic_time(:millisecond) + budget_ms
    cancel = Keyword.get(opts, :cancel, fn -> false end)

    case claim(store.workspace_id) do
      :busy ->
        %{status: :stale, files: 0, cancelled: false, safety: :not_checked}

      :ok ->
        try do
          do_sync(store, workspace_root, deadline, cancel, opts)
        after
          release(store.workspace_id)
        end
    end
  end

  defp do_sync(store, workspace_root, deadline, cancel, opts) do
    case Scan.list(workspace_root, Keyword.merge(opts, deadline: deadline)) do
      {:ok, entries, scan} ->
        case remove_disallowed(store, workspace_root, opts) do
          :ok -> sync_entries(store, entries, scan, workspace_root, deadline, cancel, opts)
          {:error, _reason} -> %{status: :stale, files: 0, cancelled: cancel.(), safety: :failed}
        end

      {:error, _} ->
        %{status: :stale, files: 0, cancelled: cancel.(), safety: :failed}
    end
  end

  defp sync_entries(store, entries, scan, workspace_root, deadline, cancel, opts) do
    {indexed, stopped, failed} =
      Enum.reduce_while(entries, {0, false, false}, fn entry, {count, _stopped, _failed} ->
        cond do
          cancel.() ->
            {:halt, {count, true, false}}

          System.monotonic_time(:millisecond) >= deadline ->
            {:halt, {count, true, false}}

          true ->
            case index_file(store, entry, workspace_root, opts) do
              {:ok, changed} -> {:cont, {count + changed, false, false}}
              {:error, _reason} -> {:halt, {count, false, true}}
            end
        end
      end)

    cleanup =
      if not failed and not stopped and not scan.partial and not cancel.() do
        Store.remove_missing(store, Enum.map(entries, & &1.path))
      else
        :ok
      end

    cond do
      failed or match?({:error, _}, cleanup) ->
        %{status: :stale, files: indexed, cancelled: cancel.(), safety: :failed}

      stopped or scan.partial ->
        %{status: :partial, files: indexed, cancelled: cancel.(), safety: :checked}

      true ->
        _ = Store.put_meta(store, "last_sync", DateTime.utc_now() |> DateTime.to_iso8601())
        %{status: :ready, files: indexed, cancelled: cancel.(), safety: :checked}
    end
  end

  defp remove_disallowed(store, workspace_root, opts) do
    allowed_paths =
      store
      |> Store.paths()
      |> Enum.filter(&Scan.allowed_path?(workspace_root, &1, opts))

    Store.remove_missing(store, allowed_paths)
  end

  defp index_file(store, entry, workspace_root, opts) do
    with true <- Scan.allowed_path?(workspace_root, entry.path, opts),
         :ok <- PathValidator.validate_under_root(entry.abs, workspace_root),
         :ok <- PathValidator.reject_resolved(entry.abs),
         {:ok, body} <- File.read(entry.abs),
         true <- String.valid?(body) do
      hash = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

      if Store.file_hash(store, entry.path) == hash do
        {:ok, 0}
      else
        chunks = Chunk.split(body, entry.language, max_chunks: @max_chunks)

        file = %{
          path: entry.path,
          size: entry.size,
          content_hash: hash,
          language: entry.language
        }

        case Store.replace_file(store, file, chunks) do
          :ok -> {:ok, 1}
          {:error, reason} -> {:error, reason}
        end
      end
    else
      false -> {:error, :scope_changed}
      {:error, reason} -> {:error, reason}
      reason -> {:error, reason}
    end
  end
end
