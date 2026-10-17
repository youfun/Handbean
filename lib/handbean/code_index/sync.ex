defmodule Handbean.CodeIndex.Sync do
  @moduledoc """
  Incremental index sync for one workspace.

  One writer per workspace id. Cancellation is cooperative: the tool task sets
  the flag, and the loop stops before the next file. Chunks and FTS updates
  commit per file.
  """

  alias Handbean.CodeIndex.{Chunk, Scan, Store}

  @max_chunks 20_000

  @type outcome :: %{
          status: :ready | :partial | :stale,
          files: non_neg_integer(),
          cancelled: boolean()
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
        %{status: :stale, files: 0, cancelled: false}

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
        {indexed, stopped} =
          Enum.reduce_while(entries, {0, false}, fn entry, {count, _} ->
            cond do
              cancel.() ->
                {:halt, {count, true}}

              System.monotonic_time(:millisecond) >= deadline ->
                {:halt, {count, true}}

              true ->
                {:cont, {count + index_file(store, entry), false}}
            end
          end)

        if not stopped and not scan.partial and not cancel.() do
          _ = Store.remove_missing(store, Enum.map(entries, & &1.path))
        end

        status =
          cond do
            stopped or scan.partial -> :partial
            true -> :ready
          end

        if status == :ready do
          _ = Store.put_meta(store, "last_sync", DateTime.utc_now() |> DateTime.to_iso8601())
        end

        %{status: status, files: indexed, cancelled: cancel.()}

      {:error, _} ->
        %{status: :stale, files: 0, cancelled: cancel.()}
    end
  end

  defp index_file(store, entry) do
    with {:ok, body} <- File.read(entry.abs),
         true <- String.valid?(body) do
      hash = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

      if Store.file_hash(store, entry.path) == hash do
        0
      else
        chunks = Chunk.split(body, entry.language, max_chunks: @max_chunks)

        file = %{
          path: entry.path,
          size: entry.size,
          content_hash: hash,
          language: entry.language
        }

        case Store.replace_file(store, file, chunks) do
          :ok -> 1
          {:error, _} -> 0
        end
      end
    else
      _ -> 0
    end
  end
end
