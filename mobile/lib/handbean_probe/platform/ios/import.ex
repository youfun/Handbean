defmodule HandbeanProbe.Platform.IOS.Import do
  @moduledoc """
  Copy photo-picker receipts into the controlled import root.

  Picker temp paths are not attachments. Composer only accepts files that
  land under `Platform.import_roots/0` with an image magic type.
  """

  alias Handbean.Attachments
  alias Handbean.Attachments.Type
  alias Handbean.Security.PathValidator
  alias HandbeanProbe.Bridge.Inbound
  alias HandbeanProbe.Platform

  @spec import_images([term()]) :: {:ok, [map()], [term()]} | {:error, term()}
  def import_images(items) when is_list(items) do
    case staging_root() do
      {:error, reason} ->
        {:error, reason}

      root ->
        dest = Path.join(root, "draft")
        File.mkdir_p!(dest)

        picked = Enum.map(items, &Inbound.picked_file/1)
        extras = max(length(picked) - Attachments.max_count(), 0)

        {attachments, errors} =
          picked
          |> Enum.take(Attachments.max_count())
          |> Enum.reduce({[], []}, fn item, {atts, errs} ->
            case import_one(item, dest, root) do
              {:ok, att} -> {atts ++ [att], errs}
              {:error, reason} -> {atts, errs ++ [to_string(reason)]}
            end
          end)

        extra_errors =
          if extras > 0, do: List.duplicate("too_many_attachments", extras), else: []

        {:ok, attachments, errors ++ extra_errors}
    end
  end

  def import_images(_), do: {:error, :invalid_platform_result}

  defp import_one(%Inbound.PickedFile{error: error}, _dest, _root)
       when is_binary(error) and error != "" do
    {:error, error}
  end

  defp import_one(%Inbound.PickedFile{path: path, name: name}, dest, root)
       when is_binary(path) and path != "" do
    abs = Path.expand(path)
    display = display_name(name, abs)

    with {:ok, %File.Stat{type: :regular, size: size}} <- File.lstat(abs),
         :ok <- size_ok(size),
         {:ok, head} <- read_head(abs),
         {:ok, canonical} <- Type.classify(head, display),
         true <- Attachments.image?(canonical),
         {:ok, copied, copied_size} <-
           bounded_copy(abs, dest, root, Attachments.max_image_bytes()) do
      id = Path.basename(copied)

      {:ok,
       %{
         "attachment_id" => id,
         "id" => id,
         "source" => "photo",
         "display_name" => display,
         "filename" => display,
         "canonical_type" => canonical,
         "mime_type" => canonical,
         "kind" => "image",
         "size_bytes" => copied_size,
         "controlled_path" => copied,
         "staging_root" => root,
         "state" => "staged"
       }}
    else
      false -> {:error, :unsupported_type}
      {:ok, %File.Stat{type: :symlink}} -> {:error, :symlink}
      {:ok, %File.Stat{type: type}} -> {:error, {:not_regular, type}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp import_one(_, _, _), do: {:error, :missing_source}

  defp staging_root do
    case Platform.import_roots() do
      [root | _] when is_binary(root) and root != "" -> root
      _ -> {:error, :staging_unavailable}
    end
  end

  defp display_name(name, _path) when is_binary(name) and name != "", do: Path.basename(name)
  defp display_name(_, path), do: Path.basename(path)

  defp size_ok(size) when is_integer(size) and size > 0 do
    if size <= Attachments.max_image_bytes(), do: :ok, else: {:error, :too_large}
  end

  defp size_ok(size) when is_integer(size) and size <= 0, do: {:error, :empty}
  defp size_ok(_), do: {:error, :too_large}

  defp read_head(path) do
    case File.open(path, [:read, :raw, :binary]) do
      {:ok, io} ->
        data = IO.binread(io, 4096)
        File.close(io)

        case data do
          bin when is_binary(bin) and bin != "" -> {:ok, bin}
          :eof -> {:error, :empty}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp bounded_copy(source, dest_dir, root, max_bytes) do
    id = Ecto.UUID.generate()
    dest = Path.join(dest_dir, id)
    partial = dest <> ".partial"

    with :ok <- PathValidator.validate_within_workspace(dest, root),
         {:ok, copied} <- copy_capped(source, partial, max_bytes),
         :ok <- PathValidator.validate_within_workspace(dest, root),
         :ok <- File.rename(partial, dest) do
      {:ok, dest, copied}
    else
      other ->
        File.rm(partial)
        File.rm(dest)
        other
    end
  end

  defp copy_capped(source, dest, max_bytes) do
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
end
