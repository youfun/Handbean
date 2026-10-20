defmodule Handbean.Browser.ChromeTest do
  use ExUnit.Case, async: false

  alias Handbean.Browser.{Chrome, ChromeRelay.Server}

  setup %{tmp_dir: tmp_dir} do
    previous = System.get_env("HANDBEAN_GLOBAL_SETTINGS_FILE")
    settings_path = Path.join(tmp_dir, "settings.json")
    System.put_env("HANDBEAN_GLOBAL_SETTINGS_FILE", settings_path)
    Server.stop_all()

    on_exit(fn ->
      Server.stop_all()

      if previous,
        do: System.put_env("HANDBEAN_GLOBAL_SETTINGS_FILE", previous),
        else: System.delete_env("HANDBEAN_GLOBAL_SETTINGS_FILE")
    end)

    :ok
  end

  defp extension_token do
    Chrome.status().pairing_url
    |> URI.parse()
    |> Map.fetch!(:path)
    |> Path.basename()
  end

  defp cdp_token do
    Server.cdp_url()
    |> URI.parse()
    |> Map.fetch!(:path)
    |> Path.basename()
  end

  defp register_extension(pid \\ self()),
    do: Server.register(:extension, pid, extension_token())

  defp register_cdp(pid \\ self()), do: Server.register(:cdp, pid, cdp_token())

  @tag :tmp_dir
  test "enablement creates one persistent pairing URL and disable stops every connection" do
    refute Chrome.enabled?()
    assert :ok = Chrome.set_enabled(true)

    first = Chrome.status()
    assert first.enabled
    assert first.relay_available
    assert first.pairing_url =~ ~r|^ws://127\.0\.0\.1:\d+/extension/[A-Za-z0-9_-]{32,}$|

    assert :ok = Chrome.set_enabled(true)
    assert Chrome.status().pairing_url == first.pairing_url

    assert {:ok, extension_id} = register_extension()
    assert {:ok, _client_id} = register_cdp()
    assert Chrome.status().extension_connected

    assert :ok = Chrome.set_enabled(false)
    refute Chrome.enabled?()
    refute Chrome.status().extension_connected
    assert_receive {:relay_text, stop_message}
    assert {:ok, %{"type" => "stop"}} = Handbean.JSON.decode(stop_message)
    assert_receive {:relay_close, 1000, "Chrome control disabled"}

    Server.unregister(:extension, extension_id)
  end

  @tag :tmp_dir
  test "browser options fail closed until the extension is connected" do
    assert :ok = Chrome.set_enabled(true)

    assert {:error, reason} = Chrome.browser_options()
    assert reason =~ "extension is not connected"

    assert {:ok, _extension_id} = register_extension()
    assert {:ok, opts} = Chrome.browser_options()
    assert opts[:pin_tab]
    assert opts[:cdp_url] =~ ~r{^ws://127\.0\.0\.1:\d+/cdp/}
  end

  @tag :tmp_dir
  test "relay heartbeat keeps an MV3 extension connection active" do
    assert :ok = Chrome.set_enabled(true)
    assert {:ok, _extension_id} = register_extension()

    send(Process.whereis(Server), :heartbeat)

    assert_receive {:relay_text, heartbeat}
    assert {:ok, %{"type" => "ping"}} = Handbean.JSON.decode(heartbeat)
  end

  @tag :tmp_dir
  test "invalid and stale relay capabilities are rejected" do
    assert :ok = Chrome.set_enabled(true)

    invalid_extension =
      :get
      |> Plug.Test.conn("/extension/not-the-pairing-token")
      |> Plug.Conn.put_req_header("origin", "chrome-extension://test-extension")
      |> Handbean.Browser.ChromeRelay.Router.call([])

    assert invalid_extension.status == 403

    current_cdp_path = Server.cdp_url() |> URI.parse() |> Map.fetch!(:path)

    disconnected_cdp =
      :get
      |> Plug.Test.conn(current_cdp_path)
      |> Handbean.Browser.ChromeRelay.Router.call([])

    assert disconnected_cdp.status == 409

    assert {:ok, _extension_id} = register_extension()
    stale_cdp_path = Server.cdp_url() |> URI.parse() |> Map.fetch!(:path)
    assert :ok = Chrome.set_enabled(false)

    stale_cdp =
      :get
      |> Plug.Test.conn(stale_cdp_path)
      |> Handbean.Browser.ChromeRelay.Router.call([])

    assert stale_cdp.status == 403
  end

  @tag :tmp_dir
  test "browser origins cannot use the internal CDP capability" do
    assert :ok = Chrome.set_enabled(true)
    assert {:ok, _extension_id} = register_extension()
    cdp_path = Server.cdp_url() |> URI.parse() |> Map.fetch!(:path)

    conn =
      :get
      |> Plug.Test.conn(cdp_path)
      |> Plug.Conn.put_req_header("origin", "https://evil.example")
      |> Handbean.Browser.ChromeRelay.Router.call([])

    assert conn.status == 403
    assert conn.resp_body == "forbidden"
  end

  @tag :tmp_dir
  test "registration revalidates capabilities after global Stop" do
    assert :ok = Chrome.set_enabled(true)
    extension_credential = extension_token()
    assert {:ok, _extension_id} = register_extension()
    cdp_credential = cdp_token()

    assert :ok = Chrome.set_enabled(false)

    assert {:error, :unauthorized} =
             Server.register(:extension, self(), extension_credential)

    assert {:error, :unauthorized} =
             Server.register(:cdp, self(), cdp_credential)
  end

  @tag :tmp_dir
  test "a disconnected CDP client is retired without dropping the extension" do
    assert :ok = Chrome.set_enabled(true)
    assert {:ok, extension_id} = register_extension()
    assert {:ok, client_id} = register_cdp()

    Server.unregister(:cdp, client_id)

    assert_receive {:relay_text, disconnected_json}

    assert {:ok, %{"type" => "client_disconnected", "clientId" => ^client_id}} =
             Handbean.JSON.decode(disconnected_json)

    late_response = %{
      "type" => "cdp",
      "clientId" => client_id,
      "message" => %{"id" => 9, "result" => %{}}
    }

    assert :ok = Server.route(:extension, extension_id, Handbean.JSON.encode!(late_response))
    assert Server.extension_connected?()
  end

  @tag :tmp_dir
  test "relay routes CDP messages without interpreting their payload" do
    assert :ok = Chrome.set_enabled(true)
    assert {:ok, extension_id} = register_extension()
    assert {:ok, client_id} = register_cdp()

    request = %{"id" => 7, "method" => "Target.getTargets", "params" => %{}}
    assert :ok = Server.route(:cdp, client_id, Handbean.JSON.encode!(request))

    assert_receive {:relay_text, envelope_json}
    assert {:ok, envelope} = Handbean.JSON.decode(envelope_json)
    assert envelope == %{"type" => "cdp", "clientId" => client_id, "message" => request}

    response = %{
      "type" => "cdp",
      "clientId" => client_id,
      "message" => %{"id" => 7, "result" => %{"targetInfos" => []}}
    }

    assert :ok = Server.route(:extension, extension_id, Handbean.JSON.encode!(response))
    assert_receive {:relay_text, response_json}

    assert {:ok, %{"id" => 7, "result" => %{"targetInfos" => []}}} =
             Handbean.JSON.decode(response_json)
  end
end
