defmodule HandbeanWeb.WorkspaceMediaController do
  use HandbeanWeb, :controller

  alias Handbean.Attachments.Access
  alias Handbean.Attachments.Type
  alias Handbean.Security.PathValidator
  alias Handbean.WorkspaceFiles
  alias Handbean.WorkspaceStore

  @max_bytes 25 * 1024 * 1024

  @doc """
  Serve a bounded workspace image through the browser access boundary.

  GET /workspace-files/:workspace_id/*path (each path segment URI-encoded)
  """
  def show(conn, params) do
    conn =
      conn
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("cache-control", "private, no-store")

    with %{"workspace_id" => workspace_id, "path" => segments} when is_list(segments) <- params,
         relative_path = Enum.join(segments, "/"),
         {:ok, workspace} <- WorkspaceStore.get(workspace_id),
         {:ok, root} <- media_root(params, workspace),
         {:ok, path} <- WorkspaceFiles.resolve(root, relative_path, :file),
         :ok <- PathValidator.validate_within_workspace(path, root),
         :ok <- PathValidator.reject_resolved(path),
         :ok <- PathValidator.validate_readable(path),
         {:ok, :image, mime} <- WorkspaceFiles.kind_from_name(path),
         {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_bytes <-
           File.lstat(path),
         {:ok, bytes} <- Access.read_bounded(path, @max_bytes),
         :ok <- Type.match(mime, Path.basename(path), bytes) do
      conn
      |> put_resp_content_type(mime)
      |> send_resp(200, bytes)
    else
      _ -> send_resp(conn, 404, "Not Found")
    end
  end

  defp media_root(%{"conversation_id" => conversation_id}, workspace)
       when is_binary(conversation_id) and conversation_id != "" do
    with {:ok, meta} <- Handbean.ConversationStore.get_metadata(conversation_id),
         true <- meta["workspace_id"] == workspace["id"],
         {:ok, checkout_path} <- Handbean.ConversationStore.effective_checkout_path(meta) do
      {:ok, checkout_path}
    else
      _ -> {:error, :not_found}
    end
  end

  defp media_root(_params, _workspace), do: {:error, :conversation_required}
end
