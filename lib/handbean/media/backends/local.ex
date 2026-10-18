defmodule Handbean.Media.Backends.Local do
  @moduledoc """
  Immutable local storage beneath the canonical host data directory.

  Logical keys always use `/`. Every reserved descendant is checked with
  `lstat`, so `.handbean/media`, conversation directories, and objects cannot
  be replaced by symbolic links.
  """

  @behaviour Handbean.Media.Backend

  alias Handbean.Attachments.Access
  alias Handbean.Media.Image
  alias Handbean.Security.PathValidator

  @impl true
  def put(storage_key, bytes, metadata) when is_binary(bytes) and is_map(metadata) do
    with {:ok, mime_type} <- Image.verify(bytes, field(metadata, :mime_type)),
         :ok <- verify_metadata(bytes, metadata),
         {:ok, path} <- writable_path(storage_key, mime_type),
         :ok <- File.write(path, bytes, [:binary, :exclusive]),
         :ok <- secure_file(path) do
      :ok
    end
  end

  def put(_storage_key, _bytes, _metadata), do: {:error, :invalid_media_object}

  @impl true
  def delivery(storage_key, metadata) when is_map(metadata) do
    with {:ok, path} <- existing_path(storage_key),
         {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
         {:ok, bytes} <- Access.read_bounded(path, Image.max_bytes()),
         {:ok, _mime_type} <- Image.verify(bytes, field(metadata, :mime_type)),
         :ok <- verify_metadata(bytes, metadata) do
      {:ok, {:send_file, path}}
    else
      {:ok, %File.Stat{type: type}} -> {:error, {:not_regular, type}}
      {:error, reason} -> {:error, reason}
    end
  end

  def delivery(_storage_key, _metadata), do: {:error, :invalid_media_object}

  @impl true
  def delete(storage_key, _metadata) do
    case existing_path(storage_key) do
      {:ok, path} -> delete_regular(path)
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec root() :: String.t()
  def root do
    Handbean.Host.data_dir()
    |> PathValidator.resolve_symlink()
    |> Path.join(".handbean/media")
  end

  defp writable_path(storage_key, mime_type) do
    with {:ok, conversation_id, filename} <- parse_key(storage_key),
         :ok <- extension_matches(filename, mime_type),
         {:ok, handbean_root} <- ensure_descendant(data_root(), ".handbean"),
         {:ok, media_root} <- ensure_descendant(handbean_root, "media"),
         {:ok, conversation_root} <- ensure_descendant(media_root, conversation_id) do
      {:ok, Path.join(conversation_root, filename)}
    end
  end

  defp existing_path(storage_key) do
    with {:ok, conversation_id, filename} <- parse_key(storage_key),
         {:ok, handbean_root} <- existing_directory(data_root(), ".handbean"),
         {:ok, media_root} <- existing_directory(handbean_root, "media"),
         {:ok, conversation_root} <- existing_directory(media_root, conversation_id) do
      {:ok, Path.join(conversation_root, filename)}
    end
  end

  defp ensure_descendant(parent, segment) do
    path = Path.join(parent, segment)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        with :ok <- chmod_supported(path, 0o700), do: {:ok, path}

      {:ok, %File.Stat{type: type}} ->
        {:error, {:unsafe_storage_descendant, type}}

      {:error, :enoent} ->
        case File.mkdir(path) do
          :ok -> ensure_descendant(parent, segment)
          {:error, :eexist} -> ensure_descendant(parent, segment)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp existing_directory(parent, segment) do
    path = Path.join(parent, segment)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> {:ok, path}
      {:ok, %File.Stat{type: type}} -> {:error, {:unsafe_storage_descendant, type}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp secure_file(path) do
    case chmod_supported(path, 0o600) do
      :ok ->
        :ok

      {:error, reason} ->
        _ = File.rm(path)
        {:error, reason}
    end
  end

  defp chmod_supported(path, mode) do
    case File.chmod(path, mode) do
      :ok -> :ok
      {:error, :enotsup} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_regular(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> File.rm(path)
      {:ok, %File.Stat{type: type}} -> {:error, {:not_regular, type}}
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_key(storage_key) when is_binary(storage_key) do
    case String.split(storage_key, "/", trim: false) do
      [conversation_id, filename] ->
        if valid_segment?(conversation_id) and valid_filename?(filename),
          do: {:ok, conversation_id, filename},
          else: {:error, :invalid_storage_key}

      _parts ->
        {:error, :invalid_storage_key}
    end
  end

  defp parse_key(_storage_key), do: {:error, :invalid_storage_key}

  defp valid_segment?(segment),
    do: Regex.match?(~r/\A[a-zA-Z0-9_-]{1,120}\z/, segment)

  defp valid_filename?(filename),
    do: Regex.match?(~r/\A[a-zA-Z0-9_-]{1,120}\.(png|jpg|gif|webp)\z/, filename)

  defp extension_matches(filename, mime_type) do
    with {:ok, extension} <- Image.extension(mime_type),
         true <- Path.extname(filename) == ".#{extension}" do
      :ok
    else
      false -> {:error, :storage_key_mime_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_metadata(bytes, metadata) do
    expected_size = field(metadata, :size_bytes)
    expected_sha = field(metadata, :sha256)

    if expected_size == byte_size(bytes) and expected_sha == Image.sha256(bytes),
      do: :ok,
      else: {:error, :integrity_mismatch}
  end

  defp data_root,
    do: Handbean.Host.data_dir() |> PathValidator.resolve_symlink() |> Path.expand()

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
