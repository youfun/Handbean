defmodule Handbean.Agent.Auth.XaiOAuthTest do
  @moduledoc """
  TDD tests for the pi-compatible xAI OAuth device-code flow.

  Protocol constants and behavior are copied from earendil-works/pi
  `packages/ai/src/auth/oauth/xai.ts` and `xai-oauth.test.ts`.
  """

  use ExUnit.Case, async: false

  alias Handbean.Agent.Auth.XaiOAuth

  @client_id "b1a00492-073a-47ea-816f-4c329264a828"
  @scope "openid profile email offline_access grok-cli:access api:access"
  @device_url "https://auth.x.ai/oauth2/device/code"
  @token_url "https://auth.x.ai/oauth2/token"

  defmodule MockReq do
    def post(url, opts) do
      replies = Process.get(:xai_oauth_replies, [])
      calls = Process.get(:xai_oauth_calls, [])
      Process.put(:xai_oauth_calls, calls ++ [{url, opts}])

      case replies do
        [reply | rest] ->
          Process.put(:xai_oauth_replies, rest)
          reply

        [] ->
          flunk("Unexpected xAI OAuth request to #{url}")
      end
    end
  end

  setup do
    Process.put(:xai_oauth_replies, [])
    Process.put(:xai_oauth_calls, [])
    :ok
  end

  defp queue_replies(replies), do: Process.put(:xai_oauth_replies, replies)
  defp calls, do: Process.get(:xai_oauth_calls, [])

  defp form_from(opts) do
    form = Keyword.fetch!(opts, :form)
    Map.new(form, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp json_ok(body), do: {:ok, %{status: 200, body: body}}
  defp json_err(status, body), do: {:ok, %{status: status, body: body}}

  defp device_body(overrides \\ %{}) do
    Map.merge(
      %{
        "device_code" => "device-code",
        "user_code" => "ABCD-1234",
        "verification_uri" => "https://accounts.x.ai/oauth2/device",
        "expires_in" => 900,
        "interval" => 5
      },
      overrides
    )
  end

  defp token_body(overrides \\ %{}) do
    Map.merge(
      %{
        "access_token" => "access-token",
        "refresh_token" => "refresh-token",
        "expires_in" => 21_600,
        "token_type" => "Bearer"
      },
      overrides
    )
  end

  defp start_opts(extra \\ []) do
    Keyword.merge([req_module: MockReq], extra)
  end

  test "start posts pi-compatible device authorization fields" do
    queue_replies([json_ok(device_body())])

    assert {:ok, device} = XaiOAuth.start(start_opts())

    assert device.device_code == "device-code"
    assert device.user_code == "ABCD-1234"
    assert device.verification_uri == "https://accounts.x.ai/oauth2/device"
    assert device.verification_uri_complete == nil
    assert device.interval_seconds == 5
    assert device.expires_in_seconds == 900

    assert [{@device_url, opts}] = calls()
    headers = Map.new(Keyword.fetch!(opts, :headers))
    assert headers["accept"] == "application/json"
    assert headers["content-type"] == "application/x-www-form-urlencoded"

    form = form_from(opts)
    assert form["client_id"] == @client_id
    assert form["scope"] == @scope
    assert form["referrer"] == "pi"
  end

  test "start prefers verification_uri_complete when present" do
    queue_replies([
      json_ok(
        device_body(%{
          "verification_uri_complete" => "https://accounts.x.ai/oauth2/device?user_code=ABCD-1234"
        })
      )
    ])

    assert {:ok, device} = XaiOAuth.start(start_opts())

    assert device.verification_uri_complete ==
             "https://accounts.x.ai/oauth2/device?user_code=ABCD-1234"

    assert XaiOAuth.browser_verification_uri(device) ==
             "https://accounts.x.ai/oauth2/device?user_code=ABCD-1234"
  end

  test "start rejects a non-https verification_uri_complete" do
    queue_replies([
      json_ok(
        device_body(%{
          "verification_uri_complete" => "http://accounts.x.ai/oauth2/device?user_code=ABCD-1234"
        })
      )
    ])

    assert {:error, message} = XaiOAuth.start(start_opts())
    assert message =~ "Untrusted verification URI"
  end

  test "start rejects non-https verification URIs" do
    for uri <- ["http://accounts.x.ai/oauth2/device", "file:///etc/passwd", "not a url"] do
      Process.put(:xai_oauth_replies, [json_ok(device_body(%{"verification_uri" => uri}))])
      Process.put(:xai_oauth_calls, [])

      assert {:error, message} = XaiOAuth.start(start_opts())
      assert message =~ "Untrusted verification URI"
    end
  end

  test "poll posts the device_code grant once and returns pending" do
    device = %{
      device_code: "device-code",
      user_code: "ABCD-1234",
      verification_uri: "https://accounts.x.ai/oauth2/device/",
      interval_seconds: 5,
      expires_in_seconds: 900
    }

    queue_replies([json_err(400, %{"error" => "authorization_pending"})])

    assert {:pending, ^device} = XaiOAuth.poll_once(device, start_opts())

    assert [{@token_url, opts}] = calls()
    form = form_from(opts)
    assert form["grant_type"] == "urn:ietf:params:oauth:grant-type:device_code"
    assert form["client_id"] == @client_id
    assert form["device_code"] == "device-code"
  end

  test "poll honors slow_down interval replacement" do
    device = %{
      device_code: "device-code",
      user_code: "ABCD-1234",
      verification_uri: "https://accounts.x.ai/oauth2/device/",
      interval_seconds: 5,
      expires_in_seconds: 900
    }

    queue_replies([json_err(400, %{"error" => "slow_down", "interval" => 10})])

    assert {:slow_down, updated} = XaiOAuth.poll_once(device, start_opts())
    assert updated.interval_seconds == 10
  end

  test "poll increases interval by 5 seconds when slow_down omits interval" do
    device = %{
      device_code: "device-code",
      user_code: "ABCD-1234",
      verification_uri: "https://accounts.x.ai/oauth2/device/",
      interval_seconds: 5,
      expires_in_seconds: 900
    }

    queue_replies([json_err(400, %{"error" => "slow_down"})])

    assert {:slow_down, updated} = XaiOAuth.poll_once(device, start_opts())
    assert updated.interval_seconds == 10
  end

  test "poll treats access_denied and authorization_denied as denial" do
    device = %{
      device_code: "device-code",
      user_code: "ABCD-1234",
      verification_uri: "https://accounts.x.ai/oauth2/device/",
      interval_seconds: 1,
      expires_in_seconds: 900
    }

    for error <- ["access_denied", "authorization_denied"] do
      Process.put(:xai_oauth_replies, [json_err(400, %{"error" => error})])
      Process.put(:xai_oauth_calls, [])

      assert {:error, message} = XaiOAuth.poll_once(device, start_opts())
      assert message == "xAI device authorization was denied"
    end
  end

  test "poll treats expired_token as expiry" do
    device = %{
      device_code: "device-code",
      user_code: "ABCD-1234",
      verification_uri: "https://accounts.x.ai/oauth2/device/",
      interval_seconds: 1,
      expires_in_seconds: 900
    }

    queue_replies([json_err(400, %{"error" => "expired_token"})])

    assert {:error, "xAI device code expired"} = XaiOAuth.poll_once(device, start_opts())
  end

  test "poll returns oauth credentials with five-minute expiry skew" do
    now_ms = 1_783_630_800_000

    device = %{
      device_code: "device-code",
      user_code: "ABCD-1234",
      verification_uri: "https://accounts.x.ai/oauth2/device/",
      interval_seconds: 5,
      expires_in_seconds: 900
    }

    queue_replies([json_ok(token_body())])

    assert {:authorized, credential} =
             XaiOAuth.poll_once(device, start_opts(now_ms: now_ms))

    assert credential == %{
             type: "oauth",
             access: "access-token",
             refresh: "refresh-token",
             expires: now_ms + 21_600_000 - 300_000
           }
  end

  test "refresh rotates the refresh token when xAI returns a new one" do
    now_ms = 1_783_630_800_000

    queue_replies([
      json_ok(token_body(%{"access_token" => "new-access", "refresh_token" => "new-refresh"}))
    ])

    assert {:ok, credential} =
             XaiOAuth.refresh("old-refresh", start_opts(now_ms: now_ms))

    assert [{@token_url, opts}] = calls()
    form = form_from(opts)
    assert form["grant_type"] == "refresh_token"
    assert form["client_id"] == @client_id
    assert form["refresh_token"] == "old-refresh"

    assert credential.access == "new-access"
    assert credential.refresh == "new-refresh"
    assert credential.type == "oauth"
  end

  test "refresh preserves the previous refresh token when xAI omits it" do
    now_ms = 1_783_630_800_000

    queue_replies([
      json_ok(%{
        "access_token" => "newer-access",
        "expires_in" => 21_600,
        "token_type" => "Bearer"
      })
    ])

    assert {:ok, credential} =
             XaiOAuth.refresh("keep-refresh", start_opts(now_ms: now_ms))

    assert credential.access == "newer-access"
    assert credential.refresh == "keep-refresh"
  end

  test "refresh assumes a one-hour lifetime when expires_in is missing" do
    now_ms = 1_783_630_800_000

    queue_replies([
      json_ok(%{
        "access_token" => "access-token",
        "refresh_token" => "refresh-token",
        "token_type" => "Bearer"
      })
    ])

    assert {:ok, credential} = XaiOAuth.refresh("old-refresh", start_opts(now_ms: now_ms))
    assert credential.expires == now_ms + 3_600_000 - 300_000
  end

  test "refresh rejects token responses with a missing access_token" do
    queue_replies([json_ok(token_body(%{"access_token" => nil}))])

    assert {:error, message} = XaiOAuth.refresh("old-refresh", start_opts())
    assert message == "Invalid xAI OAuth response field: access_token"
  end

  test "refresh surfaces the upstream error code and description" do
    queue_replies([
      json_err(400, %{"error" => "invalid_grant", "error_description" => "refresh token revoked"})
    ])

    assert {:error, message} = XaiOAuth.refresh("old-refresh", start_opts())

    assert message ==
             "xAI OAuth token refresh failed (HTTP 400): invalid_grant: refresh token revoked"
  end

  test "to_auth exposes the access token as the transport api key" do
    assert XaiOAuth.to_auth(%{type: "oauth", access: "newer-access", refresh: "r", expires: 1}) ==
             %{api_key: "newer-access"}
  end
end
