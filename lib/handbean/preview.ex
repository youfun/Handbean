defmodule Handbean.Preview do
  @moduledoc """
  Conversation-owned preview records.

  Display is a projection: hiding overlay does not close the record or
  stop a listener. Pages never choose the upstream target.
  """

  alias Handbean.Preview.{Listener, Store}

  @type preview :: %{
          id: String.t(),
          conversation_id: String.t(),
          workspace_id: String.t() | nil,
          kind: :files | :port,
          title: String.t(),
          root: String.t() | nil,
          port: pos_integer() | nil,
          status: :open | :closed,
          created_at: integer()
        }

  @spec register_files(String.t(), String.t(), keyword()) :: {:ok, preview()} | {:error, term()}
  def register_files(conversation_id, root, opts \\ [])
      when is_binary(conversation_id) and is_binary(root) do
    with {:ok, root} <- Store.normalize_root(root, opts) do
      Store.register(%{
        conversation_id: conversation_id,
        workspace_id: Keyword.get(opts, :workspace_id),
        kind: :files,
        title: Keyword.get(opts, :title) || Path.basename(root),
        root: root,
        port: nil
      })
    end
  end

  @spec register_port(String.t(), pos_integer(), keyword()) :: {:ok, preview()} | {:error, term()}
  def register_port(conversation_id, port, opts \\ [])
      when is_binary(conversation_id) and is_integer(port) do
    with :ok <- Store.validate_loopback_port(port) do
      Store.register(%{
        conversation_id: conversation_id,
        workspace_id: Keyword.get(opts, :workspace_id),
        kind: :port,
        title: Keyword.get(opts, :title) || "port #{port}",
        root: nil,
        port: port
      })
    end
  end

  @spec get(String.t()) :: {:ok, preview()} | {:error, :not_found | :closed}
  def get(id) when is_binary(id), do: Store.get(id)

  @spec fetch_open(String.t()) :: {:ok, preview()} | {:error, :not_found | :closed}
  def fetch_open(id) when is_binary(id), do: Store.fetch_open(id)

  @spec list(String.t()) :: [preview()]
  def list(conversation_id) when is_binary(conversation_id), do: Store.list(conversation_id)

  @spec close(String.t()) :: {:ok, preview()} | {:error, :not_found}
  def close(id) when is_binary(id) do
    case Store.close(id) do
      {:ok, record} ->
        if Process.whereis(Listener), do: Listener.stop(id)
        {:ok, record}

      other ->
        other
    end
  end

  @spec shell_path(String.t()) :: String.t()
  def shell_path(id) when is_binary(id), do: "/preview/#{id}"

  @spec files_path(String.t(), String.t()) :: String.t()
  def files_path(id, rel \\ "index.html") when is_binary(id) do
    "/preview/#{id}/files/#{String.trim_leading(rel, "/")}"
  end

  @spec port_path(String.t(), String.t()) :: String.t()
  def port_path(id, rel \\ "") when is_binary(id) do
    rest = String.trim_leading(rel, "/")
    if rest == "", do: "/preview/#{id}/port/", else: "/preview/#{id}/port/#{rest}"
  end

  @spec shell_url(String.t(), String.t() | nil) :: String.t()
  def shell_url(id, base \\ nil) when is_binary(id) do
    Path.join(base_url(base), shell_path(id))
  end

  @spec content_src(preview()) :: String.t()
  def content_src(%{id: id, kind: :files}), do: files_path(id, "index.html")
  def content_src(%{id: id, kind: :port}), do: port_path(id, "")

  @spec return_href(String.t()) :: String.t()
  def return_href(conversation_id) when is_binary(conversation_id) do
    "handbean://c/#{conversation_id}"
  end

  defp base_url(nil), do: Handbean.EndpointAdapter.url()
  defp base_url(base) when is_binary(base), do: String.trim_trailing(base, "/")
end
