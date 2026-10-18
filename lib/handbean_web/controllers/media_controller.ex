defmodule HandbeanWeb.MediaController do
  use HandbeanWeb, :controller

  alias Handbean.Media

  def show(conn, %{"conversation_id" => conversation_id, "media_id" => media_id}) do
    with {:ok, media} <- Media.get_ready(conversation_id, media_id),
         {:ok, delivery} <- Media.delivery(media) do
      deliver(conn, media, delivery)
    else
      _reason -> not_found(conn)
    end
  end

  def show(conn, _params), do: not_found(conn)

  defp deliver(conn, media, {:send_file, path}) when is_binary(path) do
    etag = ~s("#{media.sha256}")

    conn =
      conn
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("cache-control", "private, max-age=31536000, immutable")
      |> put_resp_header("etag", etag)
      |> put_resp_header("content-disposition", content_disposition(media.filename))
      |> put_resp_content_type(media.mime_type)

    if etag in get_req_header(conn, "if-none-match") do
      send_resp(conn, 304, "")
    else
      send_file(conn, 200, path)
    end
  end

  defp deliver(conn, _media, {:redirect, url}) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        conn
        |> put_resp_header("cache-control", "private, no-store")
        |> put_resp_header("x-content-type-options", "nosniff")
        |> redirect(external: url)

      _invalid ->
        not_found(conn)
    end
  end

  defp deliver(conn, _media, _delivery), do: not_found(conn)

  defp content_disposition(filename) do
    name = to_string(filename || "image")

    fallback =
      name
      |> String.replace(~r/[\x00-\x1f\x7f"\\]/u, "_")
      |> String.to_charlist()
      |> Enum.map(fn char -> if char in 0x20..0x7E, do: char, else: ?_ end)
      |> to_string()
      |> case do
        "" -> "image"
        value -> value
      end

    encoded = URI.encode(name, &URI.char_unreserved?/1)
    ~s(inline; filename="#{fallback}"; filename*=UTF-8''#{encoded})
  end

  defp not_found(conn), do: send_resp(conn, 404, "Not Found")
end
