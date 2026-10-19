defmodule Handbean.FileMovePlans.Files do
  @moduledoc false

  alias Handbean.Security.PathValidator
  alias Handbean.WorkspaceFiles

  @max_bytes 32 * 1024 * 1024

  def prepare(root, input) when is_map(input) do
    with {:ok, source} <- relative(field(input, "source")),
         {:ok, target} <- relative(field(input, "target")),
         {:ok, reason} <- reason(input),
         {:ok, absolute} <- source_path(root, source),
         {:ok, _destination} <- target_path(root, target, false),
         {:ok, fingerprint} <- fingerprint(absolute) do
      {:ok,
       Map.merge(fingerprint, %{
         "id" => Ecto.UUID.generate(),
         "source" => source,
         "target" => target,
         "reason" => reason,
         "status" => "pending",
         "error" => nil
       })}
    end
  end

  def prepare(_, _), do: {:error, :invalid_entry}

  def validate(root, entry) do
    with {:ok, source} <- source_path(root, entry["source"]),
         {:ok, current} <- fingerprint(source),
         true <- matches?(current, entry),
         {:ok, target} <- target_path(root, entry["target"], false) do
      {:ok, source, target}
    else
      false -> {:error, :source_changed}
      error -> error
    end
  end

  def prepare_destination(root, entry) do
    with {:ok, source, _target} <- validate(root, entry),
         {:ok, target} <- target_path(root, entry["target"], true) do
      {:ok, source, target}
    end
  end

  def move(root, entry) do
    with {:ok, source, target} <- prepare_destination(root, entry),
         :ok <- hard_link(source, target) do
      # The exclusive link never replaces a destination. Recheck the source
      # before removing its directory entry; preserve both paths if uncertain.
      with {:ok, linked} <- fingerprint(target),
           {:ok, current} <- fingerprint(source),
           true <- matches?(linked, entry) and matches?(current, entry),
           :ok <- File.rm(source) do
        :ok
      else
        reason -> {:error, {:needs_review, reason}}
      end
    end
  end

  defp hard_link(source, target) do
    case File.ln(source, target) do
      :ok -> :ok
      {:error, :eexist} -> {:error, :target_exists}
      {:error, :enotsup} -> {:error, :hard_link_unsupported}
      {:error, :exdev} -> {:error, :hard_link_unsupported}
      {:error, reason} -> {:error, reason}
    end
  end

  def path_key(path) do
    if match?({:win32, _}, :os.type()), do: String.downcase(path), else: path
  end

  defp relative(path) when is_binary(path) and byte_size(path) in 1..1_024 do
    names = path |> String.replace("\\", "/") |> String.split("/", trim: true)

    if Path.type(path) == :relative and names != [] and
         not String.contains?(path, [<<0>>, ":"]) and
         Enum.all?(names, &(&1 not in [".", ".."] and String.trim(&1) == &1)) do
      {:ok, Path.join(names)}
    else
      {:error, :invalid_path}
    end
  end

  defp relative(_), do: {:error, :invalid_path}

  defp field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end

  defp reason(input) do
    case field(input, "reason") || "" do
      reason when is_binary(reason) and byte_size(reason) <= 1_000 -> {:ok, reason}
      _ -> {:error, :invalid_reason}
    end
  end

  defp source_path(root, relative) do
    with :ok <- PathValidator.reject_resolved(Path.join(root, relative)),
         {:ok, absolute} <- WorkspaceFiles.resolve(root, relative, :file) do
      {:ok, absolute}
    end
  end

  defp target_path(root, relative, create?) do
    with :ok <- PathValidator.reject_resolved(Path.join(root, relative)),
         {:ok, normalized} <- relative(relative),
         {:ok, parent} <- target_parent(root, Enum.drop(Path.split(normalized), -1), create?),
         target = Path.join(parent, Path.basename(normalized)) do
      case File.lstat(target) do
        {:error, :enoent} -> {:ok, target}
        {:ok, _} -> {:error, :target_exists}
        error -> error
      end
    end
  end

  defp target_parent(current, [], _create?), do: {:ok, current}

  defp target_parent(current, [name | rest], create?) do
    next = Path.join(current, name)

    case File.lstat(next) do
      {:ok, %File.Stat{type: :directory}} ->
        target_parent(next, rest, create?)

      {:ok, _} ->
        {:error, :unsafe_target_parent}

      {:error, :enoent} when create? ->
        case File.mkdir(next) do
          :ok -> target_parent(current, [name | rest], create?)
          {:error, :eexist} -> target_parent(current, [name | rest], create?)
          error -> error
        end

      {:error, :enoent} ->
        {:ok, Path.join([next | rest])}

      error ->
        error
    end
  end

  defp fingerprint(path) do
    with {:ok, %File.Stat{type: :regular} = before} <- File.lstat(path, time: :posix),
         true <- before.size <= @max_bytes,
         {:ok, io} <- File.open(path, [:read, :raw, :binary]) do
      digest =
        try do
          read_hash(io, :crypto.hash_init(:sha256), 0)
        after
          File.close(io)
        end

      with {:ok, hash, bytes} <- digest,
           {:ok, after_stat} <- File.lstat(path, time: :posix),
           true <- revision(before) == revision(after_stat) and bytes == before.size do
        {:ok, Map.put(revision(before), "sha256", hash)}
      else
        false -> {:error, :source_changed}
        {:error, _} = error -> error
      end
    else
      false -> {:error, :file_too_large}
      {:ok, _} -> {:error, :not_regular_file}
      {:error, _} = error -> error
    end
  end

  defp read_hash(io, state, bytes) do
    case :file.read(io, 65_536) do
      :eof ->
        {:ok, state |> :crypto.hash_final() |> Base.encode16(case: :lower), bytes}

      {:ok, data} when bytes + byte_size(data) <= @max_bytes ->
        read_hash(io, :crypto.hash_update(state, data), bytes + byte_size(data))

      {:ok, _} ->
        {:error, :file_too_large}

      error ->
        error
    end
  end

  defp revision(stat), do: %{"size" => stat.size, "mtime" => stat.mtime, "inode" => stat.inode}

  defp matches?(fingerprint, entry) do
    Map.take(entry, ["sha256", "size", "mtime", "inode"]) == fingerprint
  end
end
