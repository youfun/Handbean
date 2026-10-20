if System.get_env("MIX_TARGET") != "mobile" do
  defmodule Handbean.Browser.ChromeRelay.Router do
    @moduledoc false

    use Plug.Router

    alias Handbean.Browser.Chrome
    alias Handbean.Browser.ChromeRelay.{Server, Socket}

    plug :match
    plug :dispatch

    get "/extension/:token" do
      origin = conn |> Plug.Conn.get_req_header("origin") |> List.first()

      if Chrome.extension_origin_allowed?(origin) and Chrome.authorize_extension(token) do
        upgrade(conn, :extension, token)
      else
        Plug.Conn.send_resp(conn, 403, "forbidden")
      end
    end

    get "/cdp/:token" do
      origin = conn |> Plug.Conn.get_req_header("origin") |> List.first()

      cond do
        not is_nil(origin) or not Server.authorize_cdp(token) ->
          Plug.Conn.send_resp(conn, 403, "forbidden")

        not Server.extension_connected?() ->
          Plug.Conn.send_resp(conn, 409, "Chrome extension not connected")

        true ->
          upgrade(conn, :cdp, token)
      end
    end

    get "/health" do
      Plug.Conn.send_resp(conn, 200, "ok")
    end

    match _ do
      Plug.Conn.send_resp(conn, 404, "not found")
    end

    defp upgrade(conn, role, credential) do
      conn
      |> WebSockAdapter.upgrade(Socket, %{role: role, credential: credential},
        timeout: 120_000,
        max_frame_size: 1_048_576,
        compress: false
      )
      |> Plug.Conn.halt()
    end
  end
end
