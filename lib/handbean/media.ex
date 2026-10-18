defmodule Handbean.Media do
  @moduledoc """
  Owns durable, user-visible conversation media.

  Media is staged from verified bytes, addressed by an opaque id, and delivered
  through the backend recorded on that object. Public descriptors deliberately
  omit storage details and presentation URLs.
  """

  import Ecto.Query

  alias Handbean.Media.{BackendRegistry, Image}
  alias Handbean.Repo
  alias Handbean.Security.PathValidator
  alias Handbean.Storage.{Conversation, ConversationMedia}

  @spec stage_file(String.t(), keyword()) :: {:ok, ConversationMedia.t()} | {:error, term()}
  def stage_file(path, opts) when is_binary(path) and is_list(opts) do
    source_filename = Path.basename(path)

    opts =
      opts
      |> Keyword.put_new(:filename, source_filename)
      |> Keyword.put(:source_filename, source_filename)

    with {:ok, {source_path, source_stat}} <- authorize_source(path, opts),
         {:ok, bytes} <- read_once(source_path, source_stat) do
      stage(bytes, opts)
    end
  end

  def stage_file(_path, _opts), do: {:error, :invalid_media_source}

  @spec stage(binary(), keyword()) :: {:ok, ConversationMedia.t()} | {:error, term()}
  def stage(bytes, opts) when is_binary(bytes) and is_list(opts) do
    declared_mime = Keyword.get(opts, :mime_type)

    with {:ok, mime_type} <- Image.verify(bytes, declared_mime),
         {:ok, attrs} <- stage_attrs(bytes, mime_type, opts),
         {:ok, backend} <- backend(attrs.backend, opts) do
      stage_verified(bytes, attrs, backend, opts)
    end
  end

  def stage(_bytes, _opts), do: {:error, :invalid_media_object}

  @doc "Return only the cross-channel fields safe for transcript and event payloads."
  @spec project(ConversationMedia.t() | map() | list() | nil) :: map() | [map()] | nil
  def project(media) when is_list(media) do
    Enum.flat_map(media, fn item ->
      case public_descriptor(item) do
        {:ok, descriptor} -> [descriptor]
        :error -> []
      end
    end)
  end

  def project(nil), do: []

  def project(media) do
    case public_descriptor(media) do
      {:ok, descriptor} -> descriptor
      :error -> nil
    end
  end

  @doc "Extract media ids from records or public descriptors, preserving order."
  @spec ids(list()) :: [String.t()]
  def ids(items) do
    items
    |> List.wrap()
    |> Enum.flat_map(fn
      %ConversationMedia{id: id} when is_binary(id) -> [id]
      %{media_id: id} when is_binary(id) -> [id]
      %{"media_id" => id} when is_binary(id) -> [id]
      _other -> []
    end)
  end

  @spec get_ready(String.t(), String.t()) :: {:ok, ConversationMedia.t()} | {:error, :not_found}
  def get_ready(conversation_id, media_id)
      when is_binary(conversation_id) and is_binary(media_id) do
    query =
      from(media in ConversationMedia,
        where:
          media.id == ^media_id and media.conversation_id == ^conversation_id and
            media.status == "ready"
      )

    case Repo.one(query) do
      %ConversationMedia{} = media -> {:ok, media}
      nil -> {:error, :not_found}
    end
  end

  def get_ready(_conversation_id, _media_id), do: {:error, :not_found}

  @spec delivery(ConversationMedia.t(), keyword()) ::
          {:ok, Handbean.Media.Backend.delivery()} | {:error, term()}
  def delivery(media, opts \\ [])

  def delivery(%ConversationMedia{status: "ready"} = media, opts) do
    with {:ok, backend} <- backend(media.backend, opts) do
      backend.delivery(media.storage_key, metadata(media))
    end
  end

  def delivery(%ConversationMedia{}, _opts), do: {:error, :media_not_ready}

  @spec delivery(String.t(), String.t(), keyword()) ::
          {:ok, Handbean.Media.Backend.delivery()} | {:error, term()}
  def delivery(conversation_id, media_id, opts) do
    with {:ok, media} <- get_ready(conversation_id, media_id) do
      delivery(media, opts)
    end
  end

  @doc """
  Move the exact tool-call media set to ready without opening a transaction.

  The caller can compose this operation into the future transcript
  `complete_tool_call` transaction. Repeating the same transition with the same
  producing entry is idempotent.
  """
  @spec mark_ready_in_tx(String.t(), String.t(), String.t(), [String.t()]) ::
          {:ok, [ConversationMedia.t()]} | {:error, term()}
  def mark_ready_in_tx(conversation_id, tool_call_id, producing_entry_id, media_ids)
      when is_binary(conversation_id) and is_binary(tool_call_id) and
             is_binary(producing_entry_id) and is_list(media_ids) do
    with true <- Handbean.ConversationStore.active?(conversation_id),
         :ok <- valid_media_ids(media_ids),
         {:ok, media} <- media_for_transition(conversation_id, tool_call_id, media_ids),
         :ok <- ready_transition_allowed(media, producing_entry_id),
         :ok <- update_staged(media_ids, producing_entry_id) do
      {:ok, ordered_reload(media_ids)}
    else
      false -> {:error, :conversation_pending_delete}
      {:error, reason} -> {:error, reason}
    end
  end

  def mark_ready_in_tx(_conversation_id, _tool_call_id, _producing_entry_id, _media_ids),
    do: {:error, :invalid_ready_transition}

  @spec mark_ready(String.t(), String.t(), String.t(), [String.t()]) ::
          {:ok, [ConversationMedia.t()]} | {:error, term()}
  def mark_ready(conversation_id, tool_call_id, producing_entry_id, media_ids) do
    Repo.transaction(fn ->
      case mark_ready_in_tx(conversation_id, tool_call_id, producing_entry_id, media_ids) do
        {:ok, media} -> media
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec mark_pending_delete(String.t(), [String.t()]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def mark_pending_delete(conversation_id, media_ids)
      when is_binary(conversation_id) and is_list(media_ids) do
    with :ok <- valid_media_ids(media_ids) do
      Repo.transaction(fn ->
        query =
          from(media in ConversationMedia,
            where: media.conversation_id == ^conversation_id and media.id in ^media_ids
          )

        if Repo.aggregate(query, :count, :id) == length(media_ids) do
          {count, _rows} =
            Repo.update_all(query,
              set: [status: "pending_delete", updated_at: DateTime.utc_now()]
            )

          count
        else
          Repo.rollback(:media_set_mismatch)
        end
      end)
    end
  end

  def mark_pending_delete(_conversation_id, _media_ids),
    do: {:error, :invalid_delete_transition}

  @spec gc_candidates(String.t(), DateTime.t(), keyword()) :: [ConversationMedia.t()]
  def gc_candidates(status, before, opts \\ [])
      when status in ["staged", "pending_delete"] and is_struct(before, DateTime) do
    limit = opts |> Keyword.get(:limit, 100) |> min(500) |> max(1)

    query =
      from(media in ConversationMedia,
        where: media.status == ^status and media.updated_at < ^before,
        order_by: [asc: media.updated_at, asc: media.id],
        limit: ^limit
      )

    query =
      if Keyword.get(opts, :active_conversation_only?, false) do
        from(media in query,
          join: conversation in Conversation,
          on: conversation.id == media.conversation_id,
          where: conversation.status == "active"
        )
      else
        query
      end

    Repo.all(query)
  end

  @doc false
  def pending_for_conversations(conversation_ids) when is_list(conversation_ids) do
    Repo.all(
      from media in ConversationMedia,
        where: media.conversation_id in ^conversation_ids and media.status == "pending_delete",
        order_by: [asc: media.conversation_id, asc: media.id]
    )
  end

  @doc false
  def delete_object(media, opts \\ [])

  def delete_object(%ConversationMedia{status: "pending_delete"} = media, opts) do
    with {:ok, backend} <- backend(media.backend, opts) do
      backend.delete(media.storage_key, metadata(media))
    end
  end

  def delete_object(%ConversationMedia{}, _opts), do: {:error, :media_not_pending_delete}

  @spec delete_pending(ConversationMedia.t(), keyword()) :: :ok | {:error, term()}
  def delete_pending(media, opts \\ [])

  def delete_pending(%ConversationMedia{status: "pending_delete"} = media, opts) do
    with :ok <- delete_object(media, opts),
         {:ok, _deleted} <- Repo.delete(media) do
      :ok
    end
  end

  def delete_pending(%ConversationMedia{}, _opts), do: {:error, :media_not_pending_delete}

  defp stage_verified(bytes, attrs, backend, opts) do
    if Handbean.ConversationStore.active?(attrs.conversation_id) do
      case existing_idempotent(attrs) do
        %ConversationMedia{status: status} = media when status in ["staged", "ready"] ->
          {:ok, media}

        %ConversationMedia{status: "pending_delete"} ->
          {:error, :media_pending_delete}

        nil ->
          persist_staged(bytes, attrs, backend, opts)
      end
    else
      {:error, :conversation_pending_delete}
    end
  end

  defp persist_staged(bytes, attrs, backend, opts) do
    object_metadata = metadata(attrs)

    with :ok <- backend.put(attrs.storage_key, bytes, object_metadata) do
      case insert_staged(attrs) do
        {:ok, media} ->
          {:ok, media}

        {:error, reason} ->
          compensate_insert_failure(attrs, backend, object_metadata, reason, opts)
      end
    end
  end

  defp insert_staged(attrs) do
    %ConversationMedia{}
    |> ConversationMedia.create_changeset(Map.from_struct(attrs))
    |> Repo.insert()
  rescue
    error in [Ecto.ConstraintError, Exqlite.Error] -> {:error, error}
  end

  defp compensate_insert_failure(attrs, backend, object_metadata, insert_error, _opts) do
    existing = existing_idempotent(attrs)

    delete_result =
      if match?(
           %ConversationMedia{backend: backend_id, storage_key: storage_key}
           when backend_id == attrs.backend and storage_key == attrs.storage_key,
           existing
         ) do
        :ok
      else
        backend.delete(attrs.storage_key, object_metadata)
      end

    case {existing, delete_result} do
      {%ConversationMedia{status: status} = media, :ok} when status in ["staged", "ready"] ->
        {:ok, media}

      {%ConversationMedia{status: "pending_delete"}, :ok} ->
        {:error, :media_pending_delete}

      {_existing, :ok} ->
        {:error, insert_error}

      {_existing, {:error, reason}} ->
        {:error, {:stage_insert_failed, insert_error, {:compensation_failed, reason}}}
    end
  end

  defp stage_attrs(bytes, mime_type, opts) do
    conversation_id = Keyword.get(opts, :conversation_id)
    tool_call_id = Keyword.get(opts, :producer_tool_call_id)
    filename = Keyword.get(opts, :filename)
    backend_id = Keyword.get(opts, :backend, BackendRegistry.default_id())
    media_id = Keyword.get(opts, :media_id, Ecto.UUID.generate())
    sha256 = Image.sha256(bytes)

    with :ok <- valid_identifier(conversation_id, :conversation_id),
         :ok <- valid_identifier(media_id, :media_id),
         :ok <- valid_tool_call_id(tool_call_id),
         :ok <- valid_filename(filename),
         :ok <- Image.validate_filename(filename, mime_type),
         :ok <- validate_source_filename(Keyword.get(opts, :source_filename), mime_type),
         true <- is_binary(backend_id),
         {:ok, extension} <- Image.extension(mime_type) do
      {:ok,
       %ConversationMedia{
         id: media_id,
         conversation_id: conversation_id,
         producer_tool_call_id: tool_call_id,
         purpose: "published",
         backend: backend_id,
         storage_key: "#{conversation_id}/#{media_id}.#{extension}",
         mime_type: mime_type,
         filename: filename,
         size_bytes: byte_size(bytes),
         sha256: sha256,
         status: "staged"
       }}
    else
      false -> {:error, :unknown_backend}
      {:error, reason} -> {:error, reason}
    end
  end

  defp existing_idempotent(attrs) do
    Repo.one(
      from(media in ConversationMedia,
        where:
          media.conversation_id == ^attrs.conversation_id and
            media.producer_tool_call_id == ^attrs.producer_tool_call_id and
            media.sha256 == ^attrs.sha256
      )
    )
  end

  defp authorize_source(path, opts) do
    working_directory = Keyword.get(opts, :working_directory)

    with {:ok, expanded} <- expand_source(path, working_directory),
         {:ok, canonical} <- PathValidator.canonicalize(expanded),
         :ok <- reject_sensitive_source(expanded),
         :ok <- reject_sensitive_source(canonical),
         roots <- allowed_roots(working_directory, Keyword.get(opts, :trusted_roots, [])),
         true <- Enum.any?(roots, &within_root?(canonical, &1)),
         {:ok, %File.Stat{type: :regular} = stat} <- File.lstat(canonical) do
      {:ok, {canonical, stat}}
    else
      {:error, :missing_working_directory} = error -> error
      {:error, :sensitive_media_source} = error -> error
      {:ok, %File.Stat{type: type}} -> {:error, {:not_regular, type}}
      _other -> {:error, :outside_trusted_root}
    end
  end

  defp expand_source(path, working_directory) do
    case Path.type(path) do
      :absolute ->
        {:ok, Path.expand(path)}

      _ when is_binary(working_directory) and working_directory != "" ->
        {:ok, Path.expand(path, working_directory)}

      _other ->
        {:error, :missing_working_directory}
    end
  end

  defp allowed_roots(working_directory, trusted_roots) do
    [working_directory | List.wrap(trusted_roots)]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  defp within_root?(path, root) do
    PathValidator.validate_within_workspace(path, root) == :ok
  end

  defp read_once(path, expected_stat) do
    case File.open(path, [:read, :raw, :binary]) do
      {:ok, io} ->
        try do
          with {:ok, opened_info} <- :file.read_file_info(io),
               :ok <- same_file(expected_stat, opened_info),
               bytes when is_binary(bytes) <- IO.binread(io, Image.max_bytes() + 1),
               :ok <- valid_read_size(bytes) do
            {:ok, bytes}
          else
            :eof -> {:error, :image_too_large_or_empty}
            {:error, reason} -> {:error, reason}
          end
        after
          File.close(io)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp media_for_transition(conversation_id, tool_call_id, media_ids) do
    media =
      Repo.all(
        from(media in ConversationMedia,
          where:
            media.conversation_id == ^conversation_id and
              media.producer_tool_call_id == ^tool_call_id and media.id in ^media_ids
        )
      )

    if length(media) == length(media_ids),
      do: {:ok, media},
      else: {:error, :media_set_mismatch}
  end

  defp ready_transition_allowed(media, producing_entry_id) do
    if Enum.all?(media, fn
         %ConversationMedia{status: "staged", producing_entry_id: nil} -> true
         %ConversationMedia{status: "ready", producing_entry_id: ^producing_entry_id} -> true
         _media -> false
       end),
       do: :ok,
       else: {:error, :invalid_media_state}
  end

  defp update_staged(media_ids, producing_entry_id) do
    query =
      from(media in ConversationMedia,
        where: media.id in ^media_ids and media.status == "staged"
      )

    Repo.update_all(query,
      set: [
        status: "ready",
        producing_entry_id: producing_entry_id,
        updated_at: DateTime.utc_now()
      ]
    )

    :ok
  end

  defp ordered_reload(media_ids) do
    by_id =
      Repo.all(from(media in ConversationMedia, where: media.id in ^media_ids))
      |> Map.new(&{&1.id, &1})

    Enum.map(media_ids, &Map.fetch!(by_id, &1))
  end

  defp valid_media_ids(media_ids) do
    unique_ids = Enum.uniq(media_ids)

    if media_ids != [] and length(unique_ids) == length(media_ids) and
         Enum.all?(media_ids, &(valid_identifier(&1, :media_id) == :ok)),
       do: :ok,
       else: {:error, :invalid_media_ids}
  end

  defp valid_identifier(value, _field) when is_binary(value) do
    if Regex.match?(~r/\A[a-zA-Z0-9_-]{1,120}\z/, value),
      do: :ok,
      else: {:error, :invalid_identifier}
  end

  defp valid_identifier(_value, _field), do: {:error, :invalid_identifier}

  defp valid_tool_call_id(value) when is_binary(value) do
    if value != "" and byte_size(value) <= 255 and not String.contains?(value, <<0>>),
      do: :ok,
      else: {:error, :invalid_tool_call_id}
  end

  defp valid_tool_call_id(_value), do: {:error, :invalid_tool_call_id}

  defp validate_source_filename(nil, _mime_type), do: :ok

  defp validate_source_filename(filename, mime_type),
    do: Image.validate_filename(filename, mime_type)

  defp valid_filename(value) when is_binary(value) do
    if value == String.trim(value) and value != "" and byte_size(value) <= 255 and
         not String.match?(value, ~r/[\x00-\x1f\x7f]/) and
         not String.contains?(value, ["/", "\\"]) and value not in [".", ".."],
       do: :ok,
       else: {:error, :invalid_filename}
  end

  defp valid_filename(_value), do: {:error, :invalid_filename}

  defp public_descriptor(%ConversationMedia{} = media) do
    public_descriptor(%{
      media_id: media.id,
      conversation_id: media.conversation_id,
      kind: "image",
      mime_type: media.mime_type,
      filename: media.filename,
      size_bytes: media.size_bytes,
      sha256: media.sha256,
      source: "agent"
    })
  end

  defp public_descriptor(media) when is_map(media) do
    descriptor = %{
      media_id: field(media, :media_id),
      conversation_id: field(media, :conversation_id),
      kind: field(media, :kind),
      mime_type: field(media, :mime_type),
      filename: field(media, :filename),
      size_bytes: field(media, :size_bytes),
      sha256: field(media, :sha256),
      source: field(media, :source)
    }

    if valid_public_descriptor?(descriptor), do: {:ok, descriptor}, else: :error
  end

  defp public_descriptor(_media), do: :error

  defp valid_public_descriptor?(descriptor) do
    valid_identifier(descriptor.media_id, :media_id) == :ok and
      valid_identifier(descriptor.conversation_id, :conversation_id) == :ok and
      descriptor.kind == "image" and
      descriptor.mime_type in ~w(image/png image/jpeg image/gif image/webp) and
      valid_filename(descriptor.filename) == :ok and is_integer(descriptor.size_bytes) and
      descriptor.size_bytes > 0 and descriptor.size_bytes <= Image.max_bytes() and
      is_binary(descriptor.sha256) and Regex.match?(~r/\A[a-f0-9]{64}\z/, descriptor.sha256) and
      descriptor.source == "agent"
  end

  defp reject_sensitive_source(path) do
    case PathValidator.reject_resolved(path) do
      :ok -> :ok
      {:error, _reason} -> {:error, :sensitive_media_source}
    end
  end

  defp same_file(
         %File.Stat{
           type: :regular,
           major_device: major_device,
           minor_device: minor_device,
           inode: inode
         },
         {:file_info, _size, :regular, _access, _atime, _mtime, _ctime, _mode, _links,
          major_device, minor_device, inode, _uid, _gid}
       ),
       do: :ok

  defp same_file(_expected_stat, _opened_info), do: {:error, :media_source_changed}

  defp valid_read_size(bytes) do
    if byte_size(bytes) > 0 and byte_size(bytes) <= Image.max_bytes(),
      do: :ok,
      else: {:error, :image_too_large_or_empty}
  end

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp backend(id, opts) do
    BackendRegistry.fetch(id, Keyword.get(opts, :backend_registry, BackendRegistry.all()))
  end

  defp metadata(%ConversationMedia{} = media) do
    Map.take(media, [:mime_type, :size_bytes, :sha256, :filename, :conversation_id])
  end

  defp metadata(attrs) when is_map(attrs), do: Map.take(attrs, [:mime_type, :size_bytes, :sha256])
end
