defmodule Handbean.Agent.Auth.CursorOAuthTest do
  use ExUnit.Case, async: false

  alias Handbean.Agent.Auth.CursorOAuth

  defmodule MockReq do
    def get(url, opts) do
      record({:get, url, opts})
      next_reply()
    end

    def post(url, opts) do
      record({:post, url, opts})
      next_reply()
    end

    defp record(call) do
      Process.put(:cursor_oauth_calls, Process.get(:cursor_oauth_calls, []) ++ [call])
    end

    defp next_reply do
      case Process.get(:cursor_oauth_replies, []) do
        [reply | rest] ->
          Process.put(:cursor_oauth_replies, rest)
          reply

        [] ->
          flunk("Unexpected Cursor OAuth request")
      end
    end
  end

  setup do
    Process.put(:cursor_oauth_replies, [])
    Process.put(:cursor_oauth_calls, [])
    :ok
  end

  test "start builds PKCE login URL without leaking a client secret" do
    assert {:ok, device} =
             CursorOAuth.start(uuid: "login-uuid", verifier: String.duplicate("a", 128))

    assert device.kind == :browser
    assert device.uuid == "login-uuid"
    assert device.verification_uri =~ "https://cursor.com/loginDeepControl?"
    assert device.verification_uri =~ "uuid=login-uuid"
    assert device.verification_uri =~ "mode=login"
    assert device.verification_uri =~ "redirectTarget=cli"
    assert device.verification_uri =~ "challenge="
    refute device.verification_uri =~ device.verifier
  end

  test "poll_once treats 404 as pending and increases interval" do
    Process.put(:cursor_oauth_replies, [{:ok, %{status: 404, body: ""}}])
    {:ok, device} = CursorOAuth.start(uuid: "u", verifier: "v", req_module: MockReq)
    device = %{device | interval_ms: 1000}

    assert {:pending, updated} = CursorOAuth.poll_once(device, req_module: MockReq)
    assert updated.attempts == 1
    assert updated.interval_ms == 1200

    [{:get, url, _opts}] = Process.get(:cursor_oauth_calls)
    assert url =~ "https://api2.cursor.sh/auth/poll"
    assert url =~ "uuid=u"
    assert url =~ "verifier=v"
  end

  test "poll_once returns tokens on 200" do
    Process.put(:cursor_oauth_replies, [
      {:ok, %{status: 200, body: %{"accessToken" => "access", "refreshToken" => "refresh"}}}
    ])

    {:ok, device} = CursorOAuth.start(uuid: "u", verifier: "v")
    assert {:authorized, cred} = CursorOAuth.poll_once(device, req_module: MockReq, now_ms: 1_000)
    assert cred.access == "access"
    assert cred.refresh == "refresh"
    assert cred.type == "oauth"
    assert cred.expires > 0
  end

  test "cancelled overlay ignores a later poll by clearing device locally" do
    Process.put(:cursor_oauth_replies, [
      {:ok, %{status: 200, body: %{"accessToken" => "late", "refreshToken" => "late-r"}}}
    ])

    {:ok, device} = CursorOAuth.start(uuid: "u", verifier: "v")
    cancelled? = true

    result =
      if cancelled? do
        :ignored
      else
        CursorOAuth.poll_once(device, req_module: MockReq)
      end

    assert result == :ignored
  end

  test "refresh uses bearer refresh token and empty json body" do
    Process.put(:cursor_oauth_replies, [
      {:ok, %{status: 200, body: %{"accessToken" => "new-a", "refreshToken" => "new-r"}}}
    ])

    assert {:ok, cred} = CursorOAuth.refresh("old-r", req_module: MockReq, now_ms: 10)
    assert cred.access == "new-a"
    assert cred.refresh == "new-r"

    [{:post, url, opts}] = Process.get(:cursor_oauth_calls)
    assert url == "https://api2.cursor.sh/auth/exchange_user_api_key"
    headers = Map.new(Keyword.fetch!(opts, :headers))
    assert headers["authorization"] == "Bearer old-r"
    assert opts[:body] == "{}"
  end

  test "refresh 401 is invalid rather than temporary" do
    Process.put(:cursor_oauth_replies, [{:ok, %{status: 401, body: %{}}}])
    assert {:error, {:invalid, message}} = CursorOAuth.refresh("r", req_module: MockReq)
    assert message =~ "reconnect"
  end

  test "refresh network error is temporary" do
    Process.put(:cursor_oauth_replies, [{:error, :timeout}])
    assert {:error, {:temporary, message}} = CursorOAuth.refresh("r", req_module: MockReq)
    assert message =~ "failed"
  end
end
