defmodule HandbeanWeb.Access do
  @moduledoc """
  Fail-closed access boundary for the single-user web endpoint.

  `:local` mode is intended only for a loopback-bound endpoint. `:password`
  mode requires HTTP Basic credentials and records successful authentication
  in the signed session so LiveView reconnects remain authenticated.
  """

  import Plug.Conn

  @behaviour Plug
  @session_key "handbean_authenticated"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case mode() do
      :local -> authorize_local(conn)
      :password -> authenticate(conn)
      mode -> unavailable(conn, "invalid access mode #{inspect(mode)}")
    end
  end

  @doc false
  def authenticated_session?(session) do
    stamp = credential_stamp()
    is_binary(stamp) and session[@session_key] == stamp
  end

  @doc false
  def local_connect_info?(connect_info) do
    peer = get_in(connect_info, [:peer_data, :address])
    uri = connect_info[:uri]

    loopback_address?(peer) and match?(%URI{}, uri) and local_host?(uri.host)
  end

  @doc false
  def loopback_peer?(%Plug.Conn{remote_ip: address}), do: loopback_address?(address)

  @doc false
  def valid_authorization?(headers) do
    with value when is_binary(value) <- authorization_header(headers),
         "Basic " <> encoded <- value,
         {:ok, decoded} <- Base.decode64(encoded),
         [username, password] <- String.split(decoded, ":", parts: 2),
         true <- valid_credentials?(username, password) do
      true
    else
      _ -> false
    end
  end

  @doc false
  def mode, do: Application.get_env(:handbean, :access, []) |> Keyword.get(:mode, :local)

  defp authenticate(conn) do
    conn = fetch_session(conn)

    cond do
      authenticated_session?(get_session(conn)) ->
        conn

      valid_authorization?(conn.req_headers) ->
        put_session(conn, @session_key, credential_stamp())

      true ->
        unauthorized(conn)
    end
  end

  defp authorize_local(conn) do
    if loopback_address?(conn.remote_ip) and local_host?(conn.host) and same_origin?(conn) do
      conn
    else
      conn |> send_resp(403, "Local access only.\n") |> halt()
    end
  end

  defp same_origin?(conn) do
    case get_req_header(conn, "origin") do
      [] ->
        true

      [origin] ->
        case URI.parse(origin) do
          %URI{scheme: scheme, host: host, port: port} when scheme in ["http", "https"] ->
            String.downcase(host || "") == String.downcase(conn.host) and
              (is_nil(port) or port == conn.port)

          _ ->
            false
        end

      _ ->
        false
    end
  end

  defp local_host?(host) when is_binary(host),
    do: String.downcase(host) in ["localhost", "127.0.0.1", "::1"]

  defp local_host?(_host), do: false

  defp loopback_address?({127, _, _, _}), do: true
  defp loopback_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback_address?(_address), do: false

  defp authorization_header(headers) do
    Enum.find_value(headers, fn
      {name, value} when name in ["authorization", "Authorization"] -> value
      _ -> nil
    end)
  end

  defp valid_credentials?(username, password) do
    config = Application.get_env(:handbean, :access, [])
    expected_username = Keyword.get(config, :username)
    expected_password = Keyword.get(config, :password)

    is_binary(expected_username) and is_binary(expected_password) and expected_password != "" and
      secure_equal?(username, expected_username) and secure_equal?(password, expected_password)
  end

  defp credential_stamp do
    config = Application.get_env(:handbean, :access, [])
    username = Keyword.get(config, :username)
    password = Keyword.get(config, :password)
    secret = HandbeanWeb.Endpoint.config(:secret_key_base) || ""

    if is_binary(username) and is_binary(password) and password != "" do
      :crypto.mac(:hmac, :sha256, secret, username <> <<0>> <> password)
      |> Base.url_encode64(padding: false)
    end
  end

  defp secure_equal?(left, right) when byte_size(left) == byte_size(right),
    do: Plug.Crypto.secure_compare(left, right)

  defp secure_equal?(_left, _right), do: false

  defp unauthorized(conn) do
    conn
    |> put_resp_header("www-authenticate", ~s(Basic realm="Handbean", charset="UTF-8"))
    |> send_resp(401, "Authentication required. Configure HANDBEAN_ACCESS_* credentials.\n")
    |> halt()
  end

  defp unavailable(conn, reason) do
    conn
    |> send_resp(503, "Handbean access configuration error: #{reason}\n")
    |> halt()
  end
end
