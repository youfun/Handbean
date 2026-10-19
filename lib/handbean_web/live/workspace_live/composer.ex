defmodule HandbeanWeb.WorkspaceLive.Composer do
  @moduledoc false

  use Gettext, backend: Handbean.Gettext

  import Phoenix.Component, only: [assign: 3]

  import Phoenix.LiveView,
    only: [cancel_upload: 3, consume_uploaded_entries: 3, push_event: 3, stream: 4]

  alias HandbeanWeb.WorkspaceLive.Skills

  def upload_error(:too_large), do: "File too large (max 5MB)"
  def upload_error(:not_accepted), do: "Unsupported file type (images only)"
  def upload_error(:too_many_files), do: "Too many files (max 4)"
  def upload_error(other), do: to_string(other)

  def remove_attachment(socket, id) do
    attachments =
      Enum.reject(
        socket.assigns.pending_attachments,
        &(Handbean.Utils.SafeMap.get_any(&1, :id, "id") == id)
      )

    assign(socket, :pending_attachments, attachments)
  end

  def switch_conversation(socket, next_id) do
    current_id = socket.assigns[:current_conversation_id]

    if current_id == next_id do
      socket
    else
      socket
      |> stash_current()
      |> invalidate_speech()
      |> load_draft(next_id)
    end
  end

  def forget(socket, conversation_id) when is_binary(conversation_id) do
    assign(socket, :composer_drafts, Map.delete(drafts(socket), conversation_id))
  end

  def forget(socket, _), do: socket

  defp stash_current(socket) do
    id = socket.assigns[:current_conversation_id]
    draft = current_draft(socket)

    drafts =
      if is_binary(id) and draft != empty_draft() do
        Map.put(drafts(socket), id, draft)
      else
        Map.delete(drafts(socket), id)
      end

    assign(socket, :composer_drafts, drafts)
  end

  defp load_draft(socket, conversation_id) do
    draft = Map.get(drafts(socket), conversation_id, empty_draft())

    socket
    |> assign(:pending_attachments, draft.attachments)
    |> assign(:input_value, draft.input)
    |> assign(:composer_error, nil)
    |> assign(
      :skill_suggestions,
      Skills.suggestions(draft.input, socket.assigns[:available_skills] || [])
    )
    |> cancel_image_uploads()
  end

  defp current_draft(socket) do
    %{
      input: socket.assigns[:input_value] || "",
      attachments: socket.assigns[:pending_attachments] || []
    }
  end

  defp empty_draft, do: %{input: "", attachments: []}

  defp drafts(socket), do: socket.assigns[:composer_drafts] || %{}

  def materialize_uploads(socket) do
    workspace_root = socket.assigns[:workspace_root]

    cond do
      not has_upload_entries?(socket) ->
        socket

      socket.assigns[:chat_scope] != :free and not is_binary(workspace_root) ->
        socket
        |> assign(:composer_error, gettext("This conversation checkout is unavailable."))
        |> cancel_image_uploads()

      true ->
        {socket, _attachments} = consume_images(socket, workspace_root)
        socket
    end
  end

  def clear_composer(socket) do
    socket
    |> assign(:pending_attachments, [])
    |> assign(:input_value, "")
    |> assign(:composer_error, nil)
    |> assign(:skill_suggestions, [])
    |> invalidate_speech()
    |> cancel_image_uploads()
  end

  def prefill_text(socket, text) when is_binary(text) and text != "" do
    current = socket.assigns[:input_value] || ""

    value =
      if String.trim(current) == "",
        do: text,
        else: String.trim_trailing(current) <> "\n" <> text

    socket
    |> assign(:input_value, value)
    |> assign(
      :skill_suggestions,
      Skills.suggestions(value, socket.assigns[:available_skills] || [])
    )
    |> push_event("composer:set-input", %{value: value})
  end

  def prefill_text(socket, _text), do: socket

  def invalidate_speech(socket) do
    socket
    |> assign(:speech_request, nil)
    |> assign(
      :speech_state,
      if(socket.assigns[:speech_available?], do: :ready, else: :unavailable)
    )
    |> assign(:speech_revision, (socket.assigns[:speech_revision] || 0) + 1)
    |> cancel_speech_uploads()
    |> push_event("speech-cancel", %{})
  end

  defp cancel_image_uploads(socket), do: cancel_uploads(socket, :images)
  defp cancel_speech_uploads(socket), do: cancel_uploads(socket, :speech_audio)

  defp cancel_uploads(socket, name) do
    uploads = socket.assigns[:uploads] || %{}

    case uploads[name] do
      %{entries: entries} when is_list(entries) ->
        Enum.reduce(entries, socket, &cancel_upload_entry(&2, name, &1))

      _ ->
        socket
    end
  end

  defp cancel_upload_entry(socket, name, entry) do
    if upload_channel_alive?(socket, name, entry) do
      cancel_upload(socket, name, entry.ref)
    else
      socket
    end
  end

  defp upload_channel_alive?(socket, name, entry) do
    case socket.assigns.uploads[name].entry_refs_to_pids[entry.ref] do
      pid when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  end

  def has_upload_entries?(socket) do
    case socket.assigns.uploads[:images] do
      %{entries: entries} when is_list(entries) -> entries != []
      _ -> false
    end
  end

  def prepare(socket, message, workspace_path) do
    {socket, attachments} = consume_images(socket, workspace_path)

    case Handbean.Attachments.MessageBuilder.build(
           message,
           attachments,
           build_opts(socket, workspace_path)
         ) do
      {:ok, content, persistable} ->
        persistable = merge_upload_urls(attachments, persistable)
        content = Skills.expand(content, socket.assigns.available_skills)
        {:ok, assign(socket, :pending_attachments, persistable), content, persistable}

      {:error, reason} ->
        {:error, assign(socket, :composer_error, outbound_error(reason))}
    end
  end

  def restore_draft(socket, %{content: content, attachments: attachments}) do
    socket |> restore_text(content) |> restore_attachments(attachments)
  end

  def restore_draft(socket, item) when is_map(item) do
    socket |> restore_text(item[:content]) |> restore_attachments(item[:attachments])
  end

  def restore_draft(socket, _), do: socket

  def assign_pending(socket, pending) do
    timeline =
      Handbean.Agent.PendingMessages.pin_pending(socket.assigns.timeline || [], pending || %{})

    socket
    |> assign(:pending_messages, pending)
    |> assign(:timeline, timeline)
    |> stream(:timeline, timeline, reset: true)
  end

  def drop_transcript_entry(conversation_id, id)
      when is_binary(conversation_id) and is_binary(id) do
    Handbean.ConversationTranscriptStore.delete(conversation_id, id)
  end

  def put_message_id(%Handbean.Agent.Message{} = message, id), do: %{message | id: id}
  def put_message_id(content, _id), do: content

  def outbound_error(:empty), do: nil
  def outbound_error(:images_not_supported), do: "Current model cannot accept images."
  def outbound_error(:too_many_attachments), do: "At most 4 attachments per message."
  def outbound_error(:image_too_large), do: "An image exceeds 5,000,000 bytes."
  def outbound_error(:text_too_large), do: "A text attachment exceeds 20 MiB."
  def outbound_error(:batch_too_large), do: "Attachments exceed the 25 MiB batch limit."
  def outbound_error(reason), do: "Attachment failed: #{inspect(reason)}"

  def resend_error(:queue_full), do: gettext("Could not resend because the queue is full.")

  def resend_error(:sealed),
    do: gettext("Could not resend because the run is no longer accepting input.")

  def resend_error(reason), do: outbound_error(reason)

  def attachment_url(attachment) when is_map(attachment) do
    conversation_id =
      Handbean.Utils.SafeMap.get_any(attachment, "conversation_id", :conversation_id)

    media_id = Handbean.Utils.SafeMap.get_any(attachment, "media_id", :media_id)

    if is_binary(conversation_id) and conversation_id != "" and is_binary(media_id) and
         media_id != "" do
      "/media/#{encode_path_segment(conversation_id)}/#{encode_path_segment(media_id)}/content"
    else
      legacy_attachment_url(attachment)
    end
  end

  def attachment_url(_), do: "#"

  defp legacy_attachment_url(%{url: url}) when is_binary(url) and url != "", do: url
  defp legacy_attachment_url(%{"url" => url}) when is_binary(url) and url != "", do: url

  defp legacy_attachment_url(%{data: data, mime_type: type}) when is_binary(data),
    do: "data:#{type || "image/png"};base64,#{data}"

  defp legacy_attachment_url(%{"data" => data, "mime_type" => type}) when is_binary(data),
    do: "data:#{type || "image/png"};base64,#{data}"

  defp legacy_attachment_url(_), do: "#"

  defp encode_path_segment(segment), do: URI.encode(segment, &URI.char_unreserved?/1)

  def attachment_filename(%{filename: filename}) when is_binary(filename), do: filename
  def attachment_filename(%{"filename" => filename}) when is_binary(filename), do: filename
  def attachment_filename(_), do: "image"

  def image_attachment?(att) when is_map(att) do
    to_string(Handbean.Utils.SafeMap.get_any(att, "kind", :kind) || "") != "text"
  end

  def image_attachment?(_), do: false

  def build_opts(socket, workspace_path) do
    if socket.assigns[:chat_scope] == :free do
      [chat_scope: :free, conversation_id: socket.assigns.current_conversation_id]
    else
      [workspace_path: workspace_path, conversation_id: socket.assigns.current_conversation_id]
    end
  end

  @doc """
  Copy a local JPEG into the conversation upload directory.

  Returns the same attachment map shape as a composer image upload.
  """
  def import_image_file(socket, source_path) when is_binary(source_path) do
    conversation_id = socket.assigns.current_conversation_id
    free? = socket.assigns[:chat_scope] == :free
    workspace_path = socket.assigns[:workspace_root]
    workspace_id = socket.assigns[:current_workspace_id]

    with true <- is_binary(conversation_id) and conversation_id != "",
         {:ok, %File.Stat{type: :regular, size: size}} <- File.lstat(source_path),
         :ok <- image_size(size),
         {:ok, head} <- read_head(source_path),
         :ok <- Handbean.Attachments.Type.match("image/jpeg", "browser-annotation.jpg", head) do
      id = Ecto.UUID.generate()
      directory = upload_directory!(free?, workspace_path, conversation_id)
      filename = "#{id}.jpg"
      dest = Path.join(directory, filename)
      File.cp!(source_path, dest)

      {:ok,
       %{
         id: id,
         kind: "image",
         mime_type: "image/jpeg",
         size_bytes: size,
         filename: "browser-annotation.jpg",
         storage_path: dest,
         relative_path: upload_relative(free?, dest, workspace_path),
         url: upload_url(free?, conversation_id, filename, workspace_id)
       }}
    else
      false -> {:error, :invalid_image}
      {:error, reason} -> {:error, reason}
    end
  end

  defp image_size(size) when is_integer(size) and size > 0 and size <= 5_000_000, do: :ok
  defp image_size(_), do: {:error, :image_too_large}

  defp read_head(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        try do
          {:ok, IO.binread(io, 32)}
        after
          File.close(io)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp consume_images(socket, workspace_path) do
    conversation_id = socket.assigns.current_conversation_id
    free? = socket.assigns[:chat_scope] == :free
    workspace_id = socket.assigns.current_workspace_id

    new =
      consume_uploaded_entries(socket, :images, fn meta, entry ->
        if extension(entry) == "bin" do
          {:postpone, nil}
        else
          id = Ecto.UUID.generate()
          directory = upload_directory!(free?, workspace_path, conversation_id)
          filename = "#{id}.#{extension(entry)}"
          path = Path.join(directory, filename)
          File.cp!(meta.path, path)

          {:ok,
           %{
             id: id,
             kind: "image",
             mime_type: entry.client_type,
             size_bytes: entry.client_size,
             filename: entry.client_name,
             storage_path: path,
             relative_path: upload_relative(free?, path, workspace_path),
             url: upload_url(free?, conversation_id, filename, workspace_id)
           }}
        end
      end)
      |> Enum.reject(&is_nil/1)

    attachments = Enum.take(socket.assigns.pending_attachments ++ new, 4)
    {assign(socket, :pending_attachments, attachments), attachments}
  rescue
    error in File.Error ->
      socket = assign(socket, :composer_error, Exception.message(error))
      {socket, socket.assigns.pending_attachments}
  end

  defp upload_directory!(true, _workspace_path, conversation_id),
    do: Handbean.Uploads.ensure_free_upload_dir!(conversation_id)

  defp upload_directory!(false, workspace_path, conversation_id),
    do: Handbean.Uploads.ensure_conversation_dir!(workspace_path, conversation_id)

  defp upload_relative(true, path, _workspace_path), do: Path.basename(path)
  defp upload_relative(false, path, workspace_path), do: Path.relative_to(path, workspace_path)

  defp upload_url(true, conversation_id, filename, _workspace_id),
    do: "/uploads/#{conversation_id}/#{filename}"

  defp upload_url(false, conversation_id, filename, workspace_id),
    do: "/uploads/#{conversation_id}/#{filename}?ws_id=#{workspace_id}"

  defp extension(entry) do
    case String.downcase(entry.client_type || "") do
      "image/png" -> "png"
      "image/jpeg" -> "jpg"
      "image/gif" -> "gif"
      "image/webp" -> "webp"
      _ -> "bin"
    end
  end

  defp merge_upload_urls(original, persistable) do
    by_id = Map.new(original, &{Handbean.Utils.SafeMap.get_any(&1, :id, "id"), &1})

    Enum.map(persistable, fn attachment ->
      case by_id[attachment["id"]] do
        %{url: url} -> Map.put(attachment, "url", url)
        %{"url" => url} -> Map.put(attachment, "url", url)
        _ -> attachment
      end
    end)
  end

  defp restore_text(socket, content) when is_binary(content) and content != "" do
    current = socket.assigns.input_value || ""

    value =
      if String.trim(current) == "",
        do: content,
        else: String.trim_trailing(current) <> "\n" <> content

    assign(socket, :input_value, value)
  end

  defp restore_text(socket, _), do: socket

  defp restore_attachments(socket, attachments) when is_list(attachments) and attachments != [],
    do: assign(socket, :pending_attachments, socket.assigns.pending_attachments ++ attachments)

  defp restore_attachments(socket, _), do: socket
end
