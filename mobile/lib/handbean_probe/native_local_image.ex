defmodule HandbeanProbe.NativeLocalImage do
  @moduledoc """
  Mob `:image` nodes for draft and sent attachments. JSON carries a local path
  only — never bytes or remote URLs.
  """

  use Gettext, backend: HandbeanProbe.Gettext

  alias Handbean.Attachments
  alias Handbean.Attachments.Access
  alias HandbeanProbe.Bridge.Payload

  @thumb_edge 40
  @card_edge 168
  @thumb_decode 96
  @card_decode 240

  def thumb_edge, do: @thumb_edge
  def card_edge, do: @card_edge

  # Every attachment is read through the canonical `Payload.attachment/1`
  # shape (draft, persisted transcript or `Imported` struct).
  def image_attachment?(att) do
    att = Payload.attachment(att)
    kind = to_string(att["kind"] || "")
    type = mime(att)
    kind == "image" or Attachments.image?(type)
  end

  def draft_src(att) do
    path = Payload.attachment(att)["controlled_path"]
    if local_file_src?(path), do: path, else: nil
  end

  def upload_src(workspace_path, conversation_id, att) do
    relative = Payload.attachment(att)["relative_path"]

    resolved =
      if Handbean.ConversationStore.free?(conversation_id) do
        Access.resolve_free_upload(conversation_id, Path.basename(relative || ""))
      else
        Access.resolve_upload(workspace_path, conversation_id, relative)
      end

    case resolved do
      {:ok, path} -> path
      _ -> nil
    end
  end

  @doc """
  Resolve every sent image once, when transcript entries enter chat state.
  Stores the checked local path under `"local_src"` so render never touches
  the filesystem; unresolvable images get `nil` and render the fallback.
  """
  def resolve_entries(entries, workspace_path, conversation_id) when is_list(entries) do
    Enum.map(entries, fn
      %{"attachments" => [_ | _] = atts} = entry ->
        Map.put(
          entry,
          "attachments",
          Enum.map(atts, &resolve_attachment(&1, workspace_path, conversation_id))
        )

      entry ->
        entry
    end)
  end

  def resolve_entries(entries, _workspace_path, _conversation_id), do: entries

  @doc "`resolve_entries/3` for a chat state map (`workspace_path`, `conversation`, `entries`)."
  def resolve_sent(%{entries: entries} = chat) do
    conversation_id =
      case Map.get(chat, :conversation) do
        %{"id" => id} -> id
        _ -> nil
      end

    %{chat | entries: resolve_entries(entries, Map.get(chat, :workspace_path), conversation_id)}
  end

  def resolve_sent(chat), do: chat

  @doc "Precomputed local path of a sent image, or `nil`."
  def sent_src(att), do: Payload.attachment(att)["local_src"]

  defp resolve_attachment(att, workspace_path, conversation_id) when is_map(att) do
    if image_attachment?(att),
      do: Map.put(att, "local_src", upload_src(workspace_path, conversation_id, att)),
      else: att
  end

  defp resolve_attachment(att, _workspace_path, _conversation_id), do: att

  def local_file_src?(path) when is_binary(path) do
    trimmed = String.trim(path)
    lower = String.downcase(trimmed)

    trimmed != "" and Path.type(trimmed) == :absolute and
      not String.contains?(trimmed, "://") and
      not String.starts_with?(lower, "http")
  end

  def local_file_src?(_), do: false

  def att_id(att), do: Payload.attachment(att)["id"]
  def att_name(att), do: Payload.attachment(att)["filename"] || gettext("Attachment")
  def mime(att), do: to_string(Payload.attachment(att)["mime_type"] || "")

  def image_node(src, name, props \\ []) do
    HandbeanProbe.NativeUI.node(
      :image,
      Keyword.merge(
        [
          src: src || "",
          local_only: true,
          content_description: gettext("Image %{name}", name: name),
          fallback: gettext("Image cannot be displayed"),
          corner_radius: 8
        ],
        props
      )
    )
  end

  def thumb(src, name, props) do
    image_node(
      src,
      name,
      Keyword.merge(
        [
          width: @thumb_edge,
          height: @thumb_edge,
          max_decode_edge: @thumb_decode,
          content_mode: "fill"
        ],
        props
      )
    )
  end

  def card_image(src, name, props \\ []) do
    image_node(
      src,
      name,
      Keyword.merge(
        [
          width: @card_edge,
          height: @card_edge,
          max_decode_edge: @card_decode,
          content_mode: "fit"
        ],
        props
      )
    )
  end
end
