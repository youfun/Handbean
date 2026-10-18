defmodule Handbean.Workspace.HexHttpTest do
  use ExUnit.Case, async: false

  alias Handbean.Workspace.HexHttp

  test "rejects non-GET methods, bodies, and non-Hex hosts" do
    assert {:error, {:unsupported_hex_request, :post}} =
             HexHttp.request(:post, "https://repo.hex.pm/packages", %{}, "")

    assert {:error, {:unsupported_hex_request, :body}} =
             HexHttp.request(:get, "https://repo.hex.pm/packages", %{}, "payload")

    assert {:error, {:unsupported_hex_request, :scheme}} =
             HexHttp.request(:get, "http://repo.hex.pm/packages", %{}, "")

    assert {:error, {:unsupported_hex_host, "example.com"}} =
             HexHttp.request(:get, "https://example.com/packages", %{}, "")
  end

  test "config points Hex.HTTP at this adapter" do
    assert %{http_adapter: {Hex.HTTP, %{}}} = HexHttp.config()
  end

  test "offline mode rejects requests before invoking the HTTP client" do
    previous = System.get_env("HEX_OFFLINE")
    test = self()

    adapter_config = %{
      req_options: [
        plug: fn conn ->
          send(test, :network_requested)
          Plug.Conn.send_resp(conn, 200, "unexpected")
        end
      ]
    }

    System.put_env("HEX_OFFLINE", "1")

    on_exit(fn ->
      if previous,
        do: System.put_env("HEX_OFFLINE", previous),
        else: System.delete_env("HEX_OFFLINE")
    end)

    assert {:error, :offline} =
             HexHttp.request(
               :get,
               "https://repo.hex.pm/packages/jason",
               %{},
               "",
               adapter_config
             )

    refute_receive :network_requested
  end
end
