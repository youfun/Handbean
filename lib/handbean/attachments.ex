defmodule Handbean.Attachments do
  @moduledoc """
  Shared attachment limits and persistable descriptors.

  Android import classifies once. Elixir only verifies a claimed canonical
  type against the local file.
  """

  alias Handbean.Attachments.{Access, Imported, Type}

  @max_count 4
  @max_image_bytes 5_000_000
  @max_text_bytes 20 * 1024 * 1024
  @max_batch_bytes 25 * 1024 * 1024

  def max_count, do: @max_count
  def max_image_bytes, do: @max_image_bytes
  def max_text_bytes, do: @max_text_bytes
  def max_batch_bytes, do: @max_batch_bytes
  def image_types, do: Type.image_types()
  def text_types, do: Type.text_types()

  def image?(type) when is_binary(type), do: type in Type.image_types()
  def text?(type) when is_binary(type), do: type in Type.text_types()

  @spec inbound_ack(String.t(), String.t()) :: :acknowledged | :unknown
  def inbound_ack(conversation_id, inbound_id)
      when is_binary(conversation_id) and is_binary(inbound_id) do
    case Handbean.ConversationTranscriptStore.list(conversation_id) do
      {:ok, entries} ->
        if Enum.any?(entries, &(&1["inbound_id"] == inbound_id or &1["id"] == inbound_id)) do
          :acknowledged
        else
          :unknown
        end

      {:error, _} ->
        :unknown
    end
  end

  @spec validate_batch([map() | Imported.t()], keyword()) :: :ok | {:error, term()}
  def validate_batch(items, opts \\ []) when is_list(items) do
    sizes = Enum.map(items, &actual_size(&1, opts))

    cond do
      length(items) > @max_count ->
        {:error, :too_many_attachments}

      Enum.any?(sizes, &match?({:error, _}, &1)) ->
        {:error, :unreadable_attachment}

      Enum.any?(Enum.zip(items, sizes), fn {item, {:ok, size}} ->
        image_item?(item) and size > @max_image_bytes
      end) ->
        {:error, :image_too_large}

      Enum.any?(Enum.zip(items, sizes), fn {item, {:ok, size}} ->
        text_item?(item) and size > @max_text_bytes
      end) ->
        {:error, :text_too_large}

      Enum.reduce(sizes, 0, fn {:ok, size}, acc -> acc + size end) > @max_batch_bytes ->
        {:error, :batch_too_large}

      true ->
        :ok
    end
  end

  @spec persistable(map() | Imported.t()) :: map()
  def persistable(%Imported{} = imported) do
    persistable(%{
      id: imported.attachment_id,
      kind: if(image?(imported.canonical_type), do: "image", else: "text"),
      mime_type: imported.canonical_type,
      filename: imported.display_name,
      size_bytes: imported.size_bytes,
      relative_path: imported.relative_path,
      source: imported.source
    })
  end

  def persistable(map) when is_map(map) do
    %{
      "id" => Handbean.Utils.SafeMap.get_any(map, :id, "id"),
      "kind" => to_string(Handbean.Utils.SafeMap.get_any(map, :kind, "kind") || kind_from(map)),
      "mime_type" => Handbean.Utils.SafeMap.get_any(map, :mime_type, "mime_type"),
      "filename" =>
        Handbean.Utils.SafeMap.get_any(map, :filename, "filename") ||
          Handbean.Utils.SafeMap.get_any(map, :display_name, "display_name"),
      "size_bytes" => Handbean.Utils.SafeMap.get_any(map, :size_bytes, "size_bytes"),
      "relative_path" => Handbean.Utils.SafeMap.get_any(map, :relative_path, "relative_path"),
      "source" => source_string(map),
      "url" => Handbean.Utils.SafeMap.get_any(map, :url, "url")
    }
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp kind_from(map) do
    if image?(to_string(Handbean.Utils.SafeMap.get_any(map, :mime_type, "mime_type"))),
      do: "image",
      else: "text"
  end

  defp source_string(map) do
    case Handbean.Utils.SafeMap.get_any(map, :source, "source") do
      nil -> nil
      value -> to_string(value)
    end
  end

  defp actual_size(%Imported{controlled_path: path, size_bytes: claimed}, _opts) do
    file_size(path, claimed)
  end

  defp actual_size(map, opts) when is_map(map) do
    path =
      Handbean.Utils.SafeMap.get_any(map, :controlled_path, "controlled_path") ||
        Handbean.Utils.SafeMap.get_any(map, :storage_path, "storage_path") ||
        resolve_declared(map, opts)

    file_size(path, Handbean.Utils.SafeMap.get_any(map, [:size_bytes, "size_bytes"]))
  end

  defp resolve_declared(map, opts) do
    workspace = Keyword.get(opts, :workspace_path)
    conversation_id = Keyword.get(opts, :conversation_id)
    relative = Handbean.Utils.SafeMap.get_any(map, [:relative_path, "relative_path"])

    case {workspace, conversation_id, relative, Keyword.get(opts, :chat_scope)} do
      {ws, cid, rel, _} when is_binary(ws) and is_binary(cid) and is_binary(rel) ->
        case Access.resolve_upload(ws, cid, rel) do
          {:ok, path} -> path
          _ -> nil
        end

      {_, cid, rel, :free} when is_binary(cid) and is_binary(rel) ->
        case Access.resolve_free_upload(cid, rel) do
          {:ok, path} -> path
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp file_size(path, _claimed) when is_binary(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} -> {:ok, size}
      _ -> {:error, :unreadable_attachment}
    end
  end

  defp file_size(_, _), do: {:error, :unreadable_attachment}

  defp image_item?(%Imported{canonical_type: type}), do: image?(type)

  defp image_item?(map),
    do: image?(to_string(declared_type(map)))

  defp text_item?(%Imported{canonical_type: type}), do: text?(type)

  defp text_item?(map),
    do: text?(to_string(declared_type(map)))

  defp declared_type(map) do
    Handbean.Utils.SafeMap.get_any(map, [:mime_type, "mime_type"]) || map[:canonical_type]
  end
end
