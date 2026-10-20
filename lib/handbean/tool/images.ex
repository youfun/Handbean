defmodule Handbean.Tool.Images do
  @moduledoc """
  Bounded, integrity-checked tool observations. State, events and transcripts
  hold opaque references, never image bodies. Providers expand them at the
  wire boundary. These are untrusted tool output, not user authorization.
  """
  alias Handbean.Attachments.Access

  @max_bytes 5_000_000
  @keys [:ref, :mime_type, :sha256, :size_bytes]
  @mimes ~w(image/png image/jpeg image/gif image/webp)

  def import_result(%Handbean.Agent.Tool.Result{} = result, context) do
    details = result.details || %{}
    sources = List.wrap(details[:image_sources]) |> Enum.take(2)
    blocks = List.wrap(details[:image_blocks]) |> Enum.take(2)

    imported =
      Enum.map(sources, fn source ->
        with :ok <- source_allowed(source, context),
             do: store_file(source.path, source.mime_type, context)
      end) ++
        Enum.map(blocks, fn block ->
          with encoded when is_binary(encoded) and byte_size(encoded) <= 7_000_000 <-
                 block["data"],
               {:ok, bytes} <- Base.decode64(encoded) do
            store(bytes, block["mimeType"], context)
          else
            _ -> {:error, :invalid_tool_image}
          end
        end)

    refs = for {:ok, ref} <- imported, do: ref
    unavailable = Enum.any?(imported, &match?({:error, _}, &1))

    %{
      result
      | images: project(result.images ++ refs),
        content:
          result.content <>
            if(unavailable,
              do: "\n[Tool image unavailable; observe again before acting]",
              else: ""
            ),
        details: Map.drop(details, [:image_sources, :image_blocks, :data, "data"])
    }
  end

  defp source_allowed(%{trusted_root: root, path: path}, _context),
    do: Access.within_root(path, root)

  defp source_allowed(%{path: path}, context) do
    with :ok <- Handbean.Security.PathValidator.reject_resolved(path) do
      if Handbean.Agent.Tool.outside_workspace_allowed?(context, path, :read),
        do: :ok,
        else:
          Handbean.Security.PathValidator.validate_within_workspace(
            path,
            context[:working_directory]
          )
    end
  end

  def store_file(path, mime, context) do
    with :ok <- Access.verify_canonical(path, mime),
         {:ok, bytes} <- Access.read_bounded(path, @max_bytes) do
      store(bytes, mime, context)
    end
  end

  def store(bytes, mime, context)
      when is_binary(bytes) and byte_size(bytes) <= @max_bytes and mime in @mimes do
    conversation = context[:conversation_id] || context[:session_id]

    with true <- valid_conversation?(conversation),
         ext <- Handbean.Uploads.allowed_ext(mime),
         ref <- "#{conversation}/#{Ecto.UUID.generate()}.#{ext}",
         path <- Path.join(root(), ref),
         :ok <- safe_directory(Path.dirname(path)),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- safe_directory(Path.dirname(path)),
         :ok <- File.chmod(Path.dirname(path), 0o700),
         :ok <- File.write(path, bytes, [:exclusive]),
         :ok <- File.chmod(path, 0o600),
         :ok <- Access.verify_canonical(path, mime) do
      {:ok, %{ref: ref, mime_type: mime, sha256: digest(bytes), size_bytes: byte_size(bytes)}}
    else
      false -> {:error, :missing_conversation}
      {:error, reason} -> {:error, reason}
    end
  end

  def store(_, _, _), do: {:error, :image_too_large_or_unsupported}

  def project(images) do
    images
    |> List.wrap()
    |> Enum.take(2)
    |> Enum.flat_map(fn image ->
      if is_map(image) do
        normalized = Map.new(@keys, &{&1, field(image, &1)})
        if valid_ref?(normalized), do: [normalized], else: []
      else
        []
      end
    end)
  end

  def load(image) when is_map(image) do
    with true <- valid_ref?(image),
         path <- Path.join(root(), field(image, :ref)),
         :ok <- Access.within_root(path, root()),
         :ok <- safe_directory(Path.dirname(path)),
         :ok <- Access.verify_canonical(path, field(image, :mime_type)),
         {:ok, bytes} <- Access.read_bounded(path, @max_bytes),
         true <-
           digest(bytes) == field(image, :sha256) and
             byte_size(bytes) == field(image, :size_bytes) do
      {:ok, %{type: "image", mime_type: field(image, :mime_type), data: Base.encode64(bytes)}}
    else
      _ -> {:error, :invalid_or_missing_tool_image}
    end
  end

  def load(_), do: {:error, :invalid_tool_image}

  def content(block) do
    text = [%{type: "text", text: block[:content] || ""}]

    images =
      Enum.map(project(block[:images]), fn image ->
        case load(image) do
          {:ok, loaded} ->
            loaded

          {:error, _} ->
            %{type: "text", text: "[Tool image unavailable; observe again before acting]"}
        end
      end)

    text ++ images
  end

  @doc "Keep only the two most recent tool images on the provider wire, including restored history."
  def bound_history(messages) do
    {bounded, _remaining} =
      Enum.reduce(Enum.reverse(messages), {[], 2}, fn message, {acc, remaining} ->
        if is_list(message.content) do
          {blocks, remaining} =
            Enum.reduce(Enum.reverse(message.content), {[], remaining}, fn block,
                                                                           {blocks, remaining} ->
              case block do
                %{type: "tool_result", images: images} ->
                  keep = Enum.take(images, remaining)
                  dropped? = length(keep) < length(images)
                  block = Map.put(block, :images, keep)

                  block =
                    if dropped?,
                      do:
                        Map.update!(
                          block,
                          :content,
                          &(&1 <> "\n[Older tool image omitted; observe again before acting]")
                        ),
                      else: block

                  {[block | blocks], remaining - length(keep)}

                _ ->
                  {[block | blocks], remaining}
              end
            end)

          {[%{message | content: blocks} | acc], remaining}
        else
          {[message | acc], remaining}
        end
      end)

    bounded
  end

  # Canonicalize the declared trusted data directory itself (/var is a macOS
  # system alias). Reserved descendants are still forbidden from being symlinks.
  defp root,
    do:
      Path.join([
        Handbean.Security.PathValidator.resolve_symlink(Handbean.Host.data_dir()),
        ".handbean",
        "tool-images"
      ])

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp valid_conversation?(id),
    do: is_binary(id) and Regex.match?(~r/\A[a-zA-Z0-9_-]{1,120}\z/, id)

  defp valid_ref?(image) do
    ref = field(image, :ref)
    sha = field(image, :sha256)
    size = field(image, :size_bytes)

    is_binary(ref) and
      Regex.match?(~r/\A[a-zA-Z0-9_-]{1,120}\/[a-f0-9-]{36}\.(png|jpg|gif|webp)\z/, ref) and
      is_binary(sha) and Regex.match?(~r/\A[a-f0-9]{64}\z/, sha) and
      field(image, :mime_type) in @mimes and is_integer(size) and size > 0 and size <= @max_bytes
  end

  defp safe_directory(path) do
    if Handbean.Security.PathValidator.resolve_symlink(path) == Path.expand(path),
      do: :ok,
      else: {:error, :symlink_directory}
  end
end
