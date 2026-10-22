defmodule Handbean.WebPush.EndpointTest do
  use ExUnit.Case, async: true

  alias Handbean.WebPush.Endpoint

  doctest Endpoint

  test "allows only HTTPS push providers, with no port or explicit port 443" do
    for host <- [
          "fcm.googleapis.com",
          "updates.push.services.mozilla.com",
          "updates.autopush.updates.push.services.mozilla.com",
          "web.push.apple.com",
          "wns2-par02p.notify.windows.com",
          "FCM.GOOGLEAPIS.COM"
        ],
        port <- ["", ":443"] do
      assert :ok == Endpoint.validate("https://#{host}#{port}/push/token?subscription=abc%2Fdef")
    end
  end

  test "rejects private, arbitrary, and lookalike destinations" do
    for host <- [
          "localhost",
          "localhost.localdomain",
          "127.0.0.1",
          "127.1",
          "2130706433",
          "0x7f000001",
          "[::1]",
          "[::ffff:127.0.0.1]",
          "10.0.0.1",
          "169.254.169.254",
          "example.com",
          "fcm.googleapis.com.evil.example",
          "evilfcm.googleapis.com",
          "sub.fcm.googleapis.com",
          "sub.web.push.apple.com",
          "evilupdates.push.services.mozilla.com",
          "updates.push.services.mozilla.com.evil.example",
          "evilnotify.windows.com",
          "notify.windows.com",
          "wns.notify.windows.com.evil.example",
          "fcm.googleapis.com.",
          ".updates.push.services.mozilla.com",
          "bad..updates.push.services.mozilla.com",
          "-bad.notify.windows.com",
          "bad_.notify.windows.com",
          "#{String.duplicate("a", 64)}.notify.windows.com",
          "ｆｃｍ.googleapis.com"
        ] do
      assert {:error, :invalid_endpoint} == Endpoint.validate("https://#{host}/push"), host
    end
  end

  test "rejects credentials, fragments, non-default ports, and ambiguous URLs" do
    for url <- [
          "http://fcm.googleapis.com/push",
          "//fcm.googleapis.com/push",
          "https:fcm.googleapis.com/push",
          "https:///fcm.googleapis.com/push",
          "https://fcm.googleapis.com:80/push",
          "https://fcm.googleapis.com:8443/push",
          "https://fcm.googleapis.com:0443/push",
          "https://fcm.googleapis.com:/push",
          "https://fcm.googleapis.com:+443/push",
          "https://user:password" <> "@fcm.googleapis.com/push",
          "https://@fcm.googleapis.com/push",
          "https://fcm.googleapis.com@localhost/push",
          "https://localhost" <> "@fcm.googleapis.com/push",
          "https://fcm.googleapis.com/push#fragment",
          "https://fcm.googleapis.com/push#",
          "https://fcm.googleapis.com\\@localhost/push",
          "https://fcm.googleapis.com\\localhost/push",
          "https://fcm%2egoogleapis.com/push",
          "https://fcm.googleapis.com%00.evil.example/push",
          "https://fcm.googleapis.com/push%xx",
          "https://fcm.googleapis.com/push%",
          "https://fcm.googleapis.com/push token",
          "https://fcm.googleapis.com/\r\nHost: localhost",
          "\thttps://fcm.googleapis.com/push",
          "https://fcm.googleapis.com/\0",
          "https://fcm.googleapis.com/" <> <<255>>,
          "https://fcm.googleapis.com/" <> String.duplicate("a", 4096)
        ] do
      assert {:error, :invalid_endpoint} == Endpoint.validate(url), inspect(url)
    end
  end

  test "rejects non-URL input without raising" do
    for value <- [nil, false, 443, %{}, [], "", <<255>>] do
      assert {:error, :invalid_endpoint} == Endpoint.validate(value)
    end
  end
end
