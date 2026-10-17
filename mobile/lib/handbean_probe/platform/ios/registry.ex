defmodule HandbeanProbe.Platform.IOS.Registry do
  @moduledoc """
  In-process iOS export snapshots. Owner is the originating `request_id`.
  """

  alias Handbean.ExportSnapshot
  alias Handbean.Security.PathValidator

  @table __MODULE__
  @picks __MODULE__.Picks

  @spec ensure_started() :: :ok
  def ensure_started do
    case Process.whereis(__MODULE__) do
      nil ->
        case start_owner() do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
    end
  end

  # Unlinked so Mix tests do not kill the ETS owner when the test process exits.
  defp start_owner do
    Agent.start(
      fn ->
        _ = table!(@table)
        _ = table!(@picks)
        :ok
      end,
      name: __MODULE__
    )
  end

  @doc "Remember an in-flight photo pick until the Mob picker receipt arrives."
  @spec put_pick(pid(), map()) :: :ok
  def put_pick(caller, session) when is_pid(caller) and is_map(session) do
    ensure_started()
    true = :ets.insert(@picks, {caller, session})
    :ok
  end

  def put_pick(_, _), do: :ok

  @spec take_pick(pid()) :: {:ok, map()} | :error
  def take_pick(caller) when is_pid(caller) do
    ensure_started()

    try do
      case :ets.take(@picks, caller) do
        [{^caller, session}] -> {:ok, session}
        _ -> :error
      end
    rescue
      ArgumentError -> :error
    end
  end

  def take_pick(_), do: :error

  @spec peek_pick(pid()) :: {:ok, map()} | :error
  def peek_pick(caller) when is_pid(caller) do
    ensure_started()

    case :ets.lookup(@picks, caller) do
      [{^caller, session}] -> {:ok, session}
      _ -> :error
    end
  end

  def peek_pick(_), do: :error

  @spec cancel_pick(pid(), String.t()) :: :ok
  def cancel_pick(caller, target_request_id)
      when is_pid(caller) and is_binary(target_request_id) do
    ensure_started()

    case :ets.lookup(@picks, caller) do
      [{^caller, %{request_id: ^target_request_id} = session}] ->
        true = :ets.insert(@picks, {caller, Map.put(session, :cancelled, true)})
        :ok

      _ ->
        :ok
    end
  end

  def cancel_pick(_, _), do: :ok

  @spec put_copy(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def put_copy(source_path, workspace_path, owner_request_id)
      when is_binary(source_path) and is_binary(workspace_path) and is_binary(owner_request_id) do
    ensure_started()

    with :ok <- PathValidator.validate_within_workspace(source_path, workspace_path),
         {:ok, authorized} <- fingerprint_source(source_path),
         {:ok, dest} <- copy_checked(source_path, authorized.size_bytes) do
      case File.lstat(source_path) do
        {:ok, after_stat} ->
          case unchanged?(authorized, after_stat) do
            :ok ->
              snap = %{
                snapshot_id: Path.basename(dest),
                path: dest,
                display_name: authorized.display_name,
                size_bytes: File.stat!(dest).size,
                mime: mime_for(authorized.display_name),
                state: "held",
                owner_request_id: owner_request_id
              }

              true = :ets.insert(@table, {snap.snapshot_id, snap})
              {:ok, snap}

            {:error, reason} ->
              File.rm(dest)
              {:error, reason}
          end

        {:error, reason} ->
          File.rm(dest)
          {:error, reason}
      end
    end
  end

  def put_copy(_, _, _), do: {:error, :invalid_path}

  @spec fetch(String.t(), String.t()) :: {:ok, map()} | :error
  def fetch(snapshot_id, owner_request_id)
      when is_binary(snapshot_id) and is_binary(owner_request_id) do
    ensure_started()

    case :ets.lookup(@table, snapshot_id) do
      [{^snapshot_id, %{owner_request_id: ^owner_request_id} = snap}] -> {:ok, snap}
      _ -> :error
    end
  end

  def fetch(_, _), do: :error

  @spec mark_handed_off(String.t()) :: :ok
  def mark_handed_off(snapshot_id) when is_binary(snapshot_id) do
    ensure_started()

    case :ets.lookup(@table, snapshot_id) do
      [{^snapshot_id, snap}] ->
        true = :ets.insert(@table, {snapshot_id, Map.put(snap, :state, "handed_off")})
        :ok

      _ ->
        :ok
    end
  end

  def mark_handed_off(_), do: :ok

  @spec cleanup(String.t(), String.t()) :: :ok | {:error, term()}
  def cleanup(snapshot_id, owner_request_id)
      when is_binary(snapshot_id) and is_binary(owner_request_id) do
    ensure_started()

    case :ets.take(@table, snapshot_id) do
      [{^snapshot_id, %{owner_request_id: ^owner_request_id, path: path}}] ->
        _ = File.rm(path)
        :ok

      [{^snapshot_id, _}] ->
        {:error, :snapshot_mismatch}

      [] ->
        :ok
    end
  end

  def cleanup(_, _), do: {:error, :file_unavailable}

  @spec cancel_owned(String.t()) :: :ok
  def cancel_owned(owner_request_id) when is_binary(owner_request_id) do
    ensure_started()

    @table
    |> :ets.match({:"$1", :"$2"})
    |> Enum.each(fn [id, snap] ->
      if snap.owner_request_id == owner_request_id do
        _ = :ets.delete(@table, id)
        _ = File.rm(snap.path)
      end
    end)

    :ok
  end

  def cancel_owned(_), do: :ok

  @spec snapshot_dir() :: String.t()
  def snapshot_dir do
    Application.get_env(:handbean_probe, :ios_snapshot_root) || default_snapshot_dir()
  end

  defp default_snapshot_dir do
    case System.get_env("MOB_CACHE_DIR") do
      cache when is_binary(cache) and cache != "" ->
        Path.join(cache, "export_snapshots")

      _ ->
        case System.get_env("MOB_DATA_DIR") do
          data when is_binary(data) and data != "" ->
            Path.join([data, "Caches", "export_snapshots"])

          _ ->
            Path.join(System.tmp_dir!(), "handbean_ios_export_snapshots")
        end
    end
  end

  defp fingerprint_source(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size, mtime: mtime}} ->
        if size > ExportSnapshot.max_bytes() do
          {:error, :too_large}
        else
          {:ok, %{size_bytes: size, mtime: mtime, display_name: Path.basename(path)}}
        end

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :symlink}

      {:ok, %File.Stat{type: type}} ->
        {:error, {:not_regular, type}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp unchanged?(before, %File.Stat{type: :regular, size: size, mtime: mtime}) do
    if before.size_bytes == size and before.mtime == mtime do
      :ok
    else
      {:error, :source_changed}
    end
  end

  defp unchanged?(_, _), do: {:error, :source_changed}

  defp copy_checked(source, size) do
    dir = snapshot_dir()
    File.mkdir_p!(dir)
    id = Ecto.UUID.generate()
    dest = Path.join(dir, id)
    partial = dest <> ".partial"

    case bounded_copy(source, partial, ExportSnapshot.max_bytes()) do
      {:ok, ^size} ->
        :ok = File.rename(partial, dest)
        {:ok, dest}

      {:ok, _} ->
        File.rm(partial)
        {:error, :source_changed}

      {:error, reason} ->
        File.rm(partial)
        {:error, reason}
    end
  end

  defp bounded_copy(source, dest, max_bytes) do
    with {:ok, input} <- File.open(source, [:read, :raw, :binary]),
         {:ok, output} <- File.open(dest, [:write, :raw, :binary]) do
      try do
        copy_loop(input, output, 0, max_bytes)
      after
        File.close(input)
        File.close(output)
      end
    end
  end

  defp copy_loop(input, output, written, max_bytes) do
    case IO.binread(input, 16_384) do
      :eof when written == 0 ->
        {:error, :empty}

      :eof ->
        {:ok, written}

      data when is_binary(data) ->
        next = written + byte_size(data)

        if next > max_bytes do
          {:error, :too_large}
        else
          :ok = IO.binwrite(output, data)
          copy_loop(input, output, next, max_bytes)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp mime_for(name) do
    {:ok, _kind, mime} = Handbean.WorkspaceFiles.kind_from_name(name)
    mime
  end

  defp table!(name) do
    case :ets.whereis(name) do
      :undefined ->
        :ets.new(name, [:named_table, :public, :set, {:read_concurrency, true}])

      tid ->
        tid
    end
  end
end
