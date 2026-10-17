defmodule Handbean.Uploads do
  @moduledoc """
  Workspace-local uploads storage (no S3/object storage).

  Stores uploads under:

      <workspace_path>/.handbean/uploads/<conversation_id>/<uuid>.<ext>
  """

  alias Handbean.Attachments
  alias Handbean.Attachments.{Access, Imported}
  alias Handbean.Security.PathValidator

  @allowed_mime_types ~w(image/png image/jpeg image/gif image/webp text/plain text/markdown application/json text/csv text/x-source)

  @spec allowed_mime_type?(String.t()) :: boolean()
  def allowed_mime_type?(mime_type) when is_binary(mime_type) do
    mime_type in @allowed_mime_types
  end

  @spec allowed_ext(String.t()) :: String.t() | nil
  def allowed_ext("image/png"), do: "png"
  def allowed_ext("image/jpeg"), do: "jpg"
  def allowed_ext("image/gif"), do: "gif"
  def allowed_ext("image/webp"), do: "webp"
  def allowed_ext("text/plain"), do: "txt"
  def allowed_ext("text/markdown"), do: "md"
  def allowed_ext("application/json"), do: "json"
  def allowed_ext("text/csv"), do: "csv"
  def allowed_ext("text/x-source"), do: "txt"
  def allowed_ext(_), do: nil

  @spec promote_imported(String.t(), String.t(), Imported.t()) ::
          {:ok, map()} | {:error, term()}
  def promote_imported(workspace_path, conversation_id, %Imported{} = imported, opts \\ []) do
    promote_path(
      workspace_path,
      conversation_id,
      imported.controlled_path,
      %{
        id: imported.attachment_id,
        mime_type: imported.canonical_type,
        filename: imported.display_name,
        source: imported.source
      },
      opts
    )
  end

  @spec promote_path(String.t(), String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def promote_path(workspace_path, conversation_id, source_path, meta, opts \\ [])
      when is_binary(workspace_path) and is_binary(conversation_id) and is_binary(source_path) do
    mime = Handbean.Utils.SafeMap.get_any(meta, :mime_type, "mime_type")

    ext =
      allowed_ext(mime) ||
        safe_ext(Handbean.Utils.SafeMap.get_any(meta, :filename, "filename"))

    id = Handbean.Utils.SafeMap.get_any(meta, :id, "id") || Ecto.UUID.generate()
    roots = List.wrap(Keyword.get(opts, :staging_roots, []))

    with true <- is_binary(ext),
         :ok <- Access.within_root(source_path, roots),
         :ok <- Access.verify_canonical(source_path, mime),
         dest_dir <- ensure_conversation_dir!(workspace_path, conversation_id),
         dest <- Path.join(dest_dir, "#{id}.#{ext}"),
         :ok <- copy_regular(source_path, dest),
         {:ok, %File.Stat{size: size, type: :regular}} <- File.lstat(dest),
         relative <- Path.join([".handbean", "uploads", conversation_id, "#{id}.#{ext}"]),
         {:ok, ^dest} <- Access.resolve_upload(workspace_path, conversation_id, relative) do
      {:ok,
       %{
         id: id,
         kind: if(Attachments.image?(mime), do: "image", else: "text"),
         mime_type: mime,
         filename:
           Handbean.Utils.SafeMap.get_any(meta, :filename, "filename") ||
             Path.basename(dest),
         size_bytes: size,
         storage_path: dest,
         relative_path: relative,
         source: Handbean.Utils.SafeMap.get_any(meta, :source, "source")
       }}
    else
      false -> {:error, :unsupported_type}
      {:error, reason} -> {:error, reason}
      {:ok, _other} -> {:error, :promote_path_mismatch}
    end
  end

  defp copy_regular(source, dest) do
    case File.lstat(source) do
      {:ok, %File.Stat{type: :regular}} ->
        case File.cp(source, dest) do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:ok, %File.Stat{type: type}} ->
        {:error, {:not_regular, type}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp safe_ext(nil), do: nil

  defp safe_ext(name) do
    ext = name |> Path.extname() |> String.downcase() |> String.trim_leading(".")
    if ext != "" and String.match?(ext, ~r/^[a-z0-9]{1,8}$/), do: ext
  end

  @spec conversation_upload_dir(String.t(), String.t()) :: String.t()
  def conversation_upload_dir(workspace_path, conversation_id)
      when is_binary(workspace_path) and is_binary(conversation_id) do
    Path.join([workspace_path, ".handbean", "uploads", conversation_id])
  end

  @doc """
  Upload directory for a workspace-independent chat.

  Upload artifacts have their own filesystem owner and are not stored beside
  canonical conversation records.
  """
  @spec free_upload_dir(String.t()) :: String.t()
  def free_upload_dir(conversation_id) when is_binary(conversation_id) do
    data_dir = Handbean.Host.get(:data_dir) || Handbean.Home.expand("~/.handbean")
    Path.join([data_dir, "artifacts", "uploads", conversation_id])
  end

  @spec ensure_free_upload_dir!(String.t()) :: String.t()
  def ensure_free_upload_dir!(conversation_id) do
    dir = free_upload_dir(conversation_id)
    File.mkdir_p!(dir)
    dir
  end

  @spec ensure_conversation_dir!(String.t(), String.t()) :: String.t()
  def ensure_conversation_dir!(workspace_path, conversation_id) do
    dir = conversation_upload_dir(workspace_path, conversation_id)
    File.mkdir_p!(dir)
    dir
  end

  @spec validate_served_upload_path(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def validate_served_upload_path(workspace_path, conversation_id, file)
      when is_binary(workspace_path) and is_binary(conversation_id) and is_binary(file) do
    base_dir = conversation_upload_dir(workspace_path, conversation_id)
    full_path = Path.expand(Path.join(base_dir, file))

    with :ok <- PathValidator.validate_within_workspace(full_path, base_dir),
         :ok <- PathValidator.validate_readable(full_path) do
      {:ok, full_path}
    else
      {:error, reason} -> {:error, reason}
    end
  end
end
