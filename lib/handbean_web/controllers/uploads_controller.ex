defmodule HandbeanWeb.UploadsController do
  use HandbeanWeb, :controller

  alias Handbean.Uploads

  @doc """
  Serve a previously uploaded file for a given conversation.

  Route:
    GET /uploads/:conversation_id/:file?ws_id=<workspace_id>
  """
  def show(conn, %{"conversation_id" => conversation_id, "file" => file} = params) do
    ws_id = Map.get(params, "ws_id")

    with {:ok, full_path} <- served_upload_path(ws_id, conversation_id, file),
         {:ok, %File.Stat{type: :regular}} <- File.stat(full_path) do
      content_type = MIME.from_path(full_path)

      conn
      |> put_resp_content_type(content_type)
      |> send_file(200, full_path)
    else
      _ ->
        send_resp(conn, 404, "Not Found")
    end
  end

  defp served_upload_path(ws_id, conversation_id, file)
       when is_binary(ws_id) and ws_id != "" do
    with {:ok, checkout_path} <- conversation_checkout(ws_id, conversation_id) do
      Uploads.validate_served_upload_path(checkout_path, conversation_id, file)
    end
  end

  defp served_upload_path(_ws_id, conversation_id, file) do
    with {:ok, meta} <- Handbean.ConversationStore.get_metadata(conversation_id),
         true <- Handbean.ConversationStore.free?(meta),
         {:ok, full_path} <-
           Handbean.Attachments.Access.resolve_free_upload(conversation_id, file) do
      {:ok, full_path}
    else
      _ -> {:error, :not_found}
    end
  end

  defp conversation_checkout(ws_id, conversation_id) do
    with {:ok, meta} <- Handbean.ConversationStore.get_metadata(conversation_id),
         true <- meta["workspace_id"] == ws_id,
         false <- Handbean.ConversationStore.free?(meta),
         {:ok, checkout_path} <- Handbean.ConversationStore.effective_checkout_path(meta) do
      {:ok, checkout_path}
    else
      _ -> {:error, :not_found}
    end
  end
end
