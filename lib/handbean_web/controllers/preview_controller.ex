defmodule HandbeanWeb.PreviewController do
  @moduledoc """
  Trusted PreviewShell plus sandboxed files/port content.

  Ordinary controller page, not LiveView. Return chrome lives here, never
  in generated HTML.
  """

  use HandbeanWeb, :controller

  alias Handbean.Preview
  alias Handbean.Preview.{Files, Proxy}

  plug :put_layout, false

  def show(conn, %{"id" => id}) do
    case Preview.fetch_open(id) do
      {:ok, record} ->
        conn
        |> put_root_layout(false)
        |> put_resp_header("content-security-policy", "frame-ancestors 'none'")
        |> render(:show,
          record: record,
          iframe_src: Preview.content_src(record),
          return_href: Preview.return_href(record.conversation_id)
        )

      {:error, :closed} ->
        conn
        |> put_status(410)
        |> put_root_layout(false)
        |> render(:closed, id: id)

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> put_root_layout(false)
        |> render(:closed, id: id)
    end
  end

  def files(conn, %{"id" => id} = params) do
    rel = rel_path(params)

    with {:ok, record} <- Preview.fetch_open(id),
         :files <- record.kind,
         {:ok, path} <- Files.resolve(record.root, rel) do
      conn
      |> put_resp_header("content-security-policy", Files.csp())
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_content_type(Files.content_type(path))
      |> send_file(200, path)
    else
      :port -> send_resp(conn, 404, "preview is a port, not files")
      {:error, :closed} -> send_resp(conn, 410, "preview closed")
      {:error, :not_found} -> send_resp(conn, 404, "not found")
      {:error, _} -> send_resp(conn, 404, "not found")
    end
  end

  def port(conn, %{"id" => id} = params) do
    rel = rel_path(params)

    with {:ok, record} <- Preview.fetch_open(id),
         :port <- record.kind,
         :ok <- reject_upgrade(conn),
         {:ok, upstream} <-
           Proxy.request(method_atom(conn.method), record.port, rel,
             query: conn.query_string,
             headers: conn.req_headers,
             body: conn.assigns[:raw_body]
           ),
         {:ok, upstream} <- rewrite_redirect(upstream, id, record.port) do
      cond do
        upstream.incompatible? ->
          send_resp(
            conn,
            501,
            "this preview needs a root origin or WS/HMR; PreviewShell will not unwrap to a top-level agent port"
          )

        true ->
          conn
          |> put_resp_header("content-security-policy", Files.csp())
          |> merge_upstream_headers(upstream.headers)
          |> send_resp(upstream.status, upstream.body || "")
      end
    else
      :files ->
        send_resp(conn, 404, "preview is files, not a port")

      {:error, :closed} ->
        send_resp(conn, 410, "preview closed")

      {:error, :not_found} ->
        send_resp(conn, 404, "not found")

      {:error, :websocket_unsupported} ->
        send_resp(conn, 501, "WebSocket/HMR is not supported through PreviewShell")

      {:error, :unsupported_redirect} ->
        send_resp(
          conn,
          502,
          "upstream redirected outside the registered loopback port; not unwrapping to a top-level agent port"
        )

      {:error, reason} ->
        send_resp(conn, 502, "preview proxy failed: #{inspect(reason)}")
    end
  end

  defp reject_upgrade(conn) do
    case get_req_header(conn, "upgrade") do
      [value | _] ->
        if String.downcase(value) == "websocket" do
          {:error, :websocket_unsupported}
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  defp rel_path(%{"path" => path}) when is_list(path), do: Path.join(path)
  defp rel_path(%{"path" => path}) when is_binary(path), do: path
  defp rel_path(_), do: ""

  defp method_atom("GET"), do: :get
  defp method_atom("POST"), do: :post
  defp method_atom("PUT"), do: :put
  defp method_atom("PATCH"), do: :patch
  defp method_atom("DELETE"), do: :delete
  defp method_atom("HEAD"), do: :head
  defp method_atom("OPTIONS"), do: :options
  defp method_atom(_), do: :get

  defp merge_upstream_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, acc ->
      name = String.downcase(to_string(name))

      if name in ["content-security-policy", "set-cookie", "set-cookie2"] do
        acc
      else
        put_resp_header(acc, name, to_string(value))
      end
    end)
  end

  defp rewrite_redirect(%{headers: headers} = upstream, preview_id, port) do
    locations =
      for {key, value} <- headers,
          String.downcase(to_string(key)) == "location",
          do: to_string(value)

    case locations do
      [] ->
        {:ok, upstream}

      [location] ->
        with {:ok, rewritten} <- Proxy.rewrite_location(location, preview_id, port) do
          headers =
            [{"location", rewritten} | reject_headers(headers, "location")]

          {:ok, %{upstream | headers: headers}}
        end

      _ ->
        {:error, :unsupported_redirect}
    end
  end

  defp reject_headers(headers, rejected_name) do
    Enum.reject(headers, fn {name, _value} ->
      String.downcase(to_string(name)) == rejected_name
    end)
  end
end
