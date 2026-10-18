defmodule Handbean.Attachments.Access do
  @moduledoc """
  Trusted path resolution for upload refs and staging files.
  Relative refs must stay inside one conversation upload directory.
  """

  alias Handbean.Attachments
  alias Handbean.Security.PathValidator
  alias Handbean.Uploads

  @spec resolve_upload(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def resolve_upload(workspace_path, conversation_id, relative)
      when is_binary(workspace_path) and is_binary(conversation_id) and is_binary(relative) do
    upload_dir = Uploads.conversation_upload_dir(workspace_path, conversation_id)

    with :ok <- conversation_id_ok(conversation_id),
         :ok <- relative_ok(relative, conversation_id),
         expected <- Path.join([workspace_path, relative]),
         :ok <- PathValidator.validate_within_workspace(expected, workspace_path),
         :ok <- PathValidator.validate_within_workspace(expected, upload_dir),
         {:ok, %File.Stat{type: :regular, size: size}} <- File.lstat(expected),
         :ok <-
           PathValidator.validate_within_workspace(
             PathValidator.resolve_symlink(expected),
             upload_dir
           ),
         :ok <- within_size(size, :any) do
      {:ok, Path.expand(expected)}
    else
      {:ok, %File.Stat{type: type}} -> {:error, {:not_regular, type}}
      {:error, reason} -> {:error, reason}
    end
  end

  def resolve_upload(_, _, _), do: {:error, :malformed_ref}

  @doc "Resolve an upload stored on a free chat, not under a workspace."
  @spec resolve_free_upload(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def resolve_free_upload(conversation_id, relative)
      when is_binary(conversation_id) and is_binary(relative) do
    upload_dir = Uploads.free_upload_dir(conversation_id)
    basename = Path.basename(relative)

    with :ok <- conversation_id_ok(conversation_id),
         true <-
           basename != "" and basename == Path.basename(relative) and basename != "." and
             not String.contains?(relative, ["..", "/"]),
         expected <- Path.join(upload_dir, basename),
         :ok <- PathValidator.validate_within_workspace(expected, upload_dir),
         {:ok, %File.Stat{type: :regular, size: size}} <- File.lstat(expected),
         :ok <-
           PathValidator.validate_within_workspace(
             PathValidator.resolve_symlink(expected),
             upload_dir
           ),
         :ok <- within_size(size, :any) do
      {:ok, Path.expand(expected)}
    else
      false -> {:error, :malformed_ref}
      {:ok, %File.Stat{type: type}} -> {:error, {:not_regular, type}}
      {:error, reason} -> {:error, reason}
    end
  end

  def resolve_free_upload(_, _), do: {:error, :malformed_ref}

  @spec within_root(String.t(), String.t() | [String.t()]) :: :ok | {:error, term()}
  def within_root(path, roots) when is_list(roots) do
    Enum.find_value(roots, {:error, :outside_trusted_root}, fn root ->
      case within_root(path, root) do
        :ok -> :ok
        _ -> nil
      end
    end)
  end

  def within_root(path, root) when is_binary(path) and is_binary(root) do
    expanded = Path.expand(path)
    expanded_root = Path.expand(root)
    resolved = PathValidator.resolve_symlink(expanded)

    with :ok <- PathValidator.validate_within_workspace(expanded, expanded_root),
         :ok <- PathValidator.validate_within_workspace(resolved, expanded_root),
         {:ok, %File.Stat{type: :regular}} <- File.lstat(expanded) do
      :ok
    else
      {:ok, %File.Stat{type: type}} -> {:error, {:not_regular, type}}
      {:error, reason} -> {:error, reason}
    end
  end

  def within_root(_, _), do: {:error, :outside_trusted_root}

  @spec read_bounded(String.t(), pos_integer()) :: {:ok, binary()} | {:error, term()}
  def read_bounded(path, max_bytes) when is_binary(path) and is_integer(max_bytes) do
    with {:ok, %File.Stat{type: :regular}} <- File.lstat(path) do
      stream_capped(path, max_bytes)
    else
      {:ok, %File.Stat{type: type}} -> {:error, {:not_regular, type}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp stream_capped(path, max_bytes) do
    case File.open(path, [:read, :raw]) do
      {:ok, io} ->
        try do
          bin = IO.binread(io, max_bytes + 1)

          cond do
            not is_binary(bin) -> {:error, :unreadable}
            byte_size(bin) == 0 -> {:error, :too_large_or_empty}
            byte_size(bin) > max_bytes -> {:error, :too_large_or_empty}
            true -> {:ok, bin}
          end
        after
          File.close(io)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec verify_canonical(String.t(), String.t()) :: :ok | {:error, term()}
  def verify_canonical(path, canonical_type) when is_binary(path) and is_binary(canonical_type) do
    with {:ok, %File.Stat{type: :regular, size: size}} <- File.lstat(path),
         :ok <- within_size(size, canonical_type),
         {:ok, head} <- read_head(path),
         :ok <- Attachments.Type.match(canonical_type, Path.basename(path), head) do
      :ok
    else
      {:ok, %File.Stat{type: type}} -> {:error, {:not_regular, type}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp conversation_id_ok(id) do
    if id != "" and not String.contains?(id, ["/", "\\", ".."]),
      do: :ok,
      else: {:error, :malformed_conversation}
  end

  defp relative_ok(relative, conversation_id) do
    parts = Path.split(relative)

    cond do
      Path.type(relative) == :absolute ->
        {:error, :malformed_ref}

      String.contains?(relative, ["\\", ".."]) ->
        {:error, :malformed_ref}

      match?([".handbean", "uploads", ^conversation_id, _file], parts) and
        is_binary(List.last(parts)) and List.last(parts) not in ["", ".", ".."] ->
        :ok

      true ->
        {:error, :malformed_ref}
    end
  end

  defp within_size(size, :any) when is_integer(size) and size >= 0 do
    if size <= Attachments.max_batch_bytes(), do: :ok, else: {:error, :too_large_or_empty}
  end

  defp within_size(size, type) do
    max =
      if Attachments.image?(type),
        do: Attachments.max_image_bytes(),
        else: Attachments.max_text_bytes()

    if size > 0 and size <= max, do: :ok, else: {:error, :too_large_or_empty}
  end

  defp read_head(path) do
    case File.open(path, [:read, :raw]) do
      {:ok, io} ->
        bin = IO.binread(io, 4096)
        File.close(io)
        if is_binary(bin), do: {:ok, bin}, else: {:error, :unreadable}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
