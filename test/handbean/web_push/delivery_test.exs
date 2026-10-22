defmodule Handbean.WebPush.DeliveryTest do
  use Handbean.DataCase, async: false

  import Plug.Conn

  alias Handbean.JSON
  alias Handbean.WebPush
  alias Handbean.WebPush.Delivery
  alias Handbean.WebPush.Keys
  alias Handbean.WebPush.Protocol
  alias Handbean.WebPush.Subscription

  defmodule RawRequestAdapter do
    @moduledoc false

    def run(request) do
      send(self(), {:raw_request, request})
      {request, Req.Response.new(status: 201)}
    end
  end

  setup do
    previous = Map.new([:web_push, :access], &{&1, Application.fetch_env(:handbean, &1)})

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, original} -> Application.put_env(:handbean, key, original)
          :error -> Application.delete_env(:handbean, key)
        end
      end
    end)

    Application.put_env(:handbean, :web_push,
      subject: "mailto:push@example.com",
      req_options: [plug: {Req.Test, __MODULE__}]
    )

    Application.put_env(:handbean, :access,
      mode: :password,
      username: "push-test",
      password: "test-pass-v1"
    )

    Repo.delete_all(Subscription)
    Repo.delete_all(Keys)
    Req.Test.stub(__MODULE__, fn _conn -> flunk("unexpected Web Push request") end)
    receiver = Protocol.generate_key_pair()
    auth = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    %{receiver: receiver, keys: %{"p256dh" => receiver.public_key, "auth" => auth}}
  end

  test "test notifications use an authenticated encrypted POST with Web Push headers", context do
    subscription = enroll(context, "browser", "en")
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = read_body(conn)
      send(owner, {:request, conn, body})
      send_resp(conn, 201, "")
    end)

    assert :ok == Delivery.test(subscription)
    assert_received {:request, conn, encrypted}
    assert conn.method == "POST"
    assert conn.scheme == :https
    assert conn.host == "fcm.googleapis.com"
    assert conn.request_path == "/fcm/send/browser"
    assert get_req_header(conn, "content-type") == ["application/octet-stream"]
    assert get_req_header(conn, "ttl") == ["3600"]
    assert get_req_header(conn, "urgency") == ["normal"]
    assert [authorization] = get_req_header(conn, "authorization")
    assert_vapid(authorization)

    assert decrypt(encrypted, context) == %{
             "title" => "Handbean",
             "body" => "Background notifications are ready on this device.",
             "url" => "/settings?tab=ui",
             "tag" => "handbean-push-test"
           }

    assert WebPush.current?(subscription)
    refute_received {:request, _, _}
  end

  test "the raw HTTP request carries the aes128gcm content encoding", context do
    subscription = enroll(context, "browser", "en")

    Application.put_env(:handbean, :web_push,
      subject: "mailto:push@example.com",
      req_options: [adapter: RawRequestAdapter]
    )

    assert :ok == Delivery.test(subscription)
    assert_received {:raw_request, request}
    # Req's Plug adapter removes Content-Encoding even for unknown codecs.
    assert Req.Request.get_header(request, "content-encoding") == ["aes128gcm"]
    assert decrypt(IO.iodata_to_binary(request.body), context)["title"] == "Handbean"
  end

  test "task delivery encrypts generic localized content and an encoded conversation URL",
       context do
    english = enroll(context, "english", "en")
    chinese = enroll(context, "chinese", "zh_CN")
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = read_body(conn)
      send(owner, {:encrypted_payload, conn.request_path, body})
      send_resp(conn, 201, "")
    end)

    task = %{
      run_id: "private-run-id",
      workspace_id: "workspace / one",
      conversation_id: "conversation / two",
      title: "Private conversation title",
      prompt: "Private user prompt",
      response: "Private model response"
    }

    assert %{subscriptions: [], retry_after: 0} =
             Delivery.deliver({:ended, task, :completed}, [english, chinese])

    assert_received {:encrypted_payload, "/fcm/send/english", english_body}
    assert_received {:encrypted_payload, "/fcm/send/chinese", chinese_body}
    en = decrypt(english_body, context)
    zh = decrypt(chinese_body, context)

    for payload <- [en, zh] do
      assert Enum.sort(Map.keys(payload)) == ["body", "tag", "title", "url"]
      assert payload["title"] == "Handbean"
      assert payload["url"] == "/w/workspace+%2F+one/c/conversation+%2F+two"

      for secret <- [task.title, task.prompt, task.response, task.run_id] do
        refute String.contains?(JSON.encode!(payload), secret)
      end
    end

    assert en["body"] == "A task has completed."
    assert zh["body"] == translated("A task has completed.", "zh_CN")
    refute zh["body"] == en["body"]
    assert en["tag"] == zh["tag"]
  end

  test "failed tasks deliver a generic error and support conversation URLs without a workspace",
       context do
    subscription = enroll(context, "browser", "en")
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = read_body(conn)
      send(owner, {:encrypted_payload, body})
      send_resp(conn, 202, "")
    end)

    task = %{
      run_id: "run",
      conversation_id: "conversation/name",
      error: "sensitive failure detail"
    }

    assert %{subscriptions: []} = Delivery.deliver({:ended, task, :failed}, [subscription])
    assert_received {:encrypted_payload, encrypted}
    payload = decrypt(encrypted, context)
    assert payload["body"] == "A task stopped with an error."
    assert payload["url"] == "/c/conversation%2Fname"
    refute String.contains?(JSON.encode!(payload), task.error)
  end

  test "404 and 410 responses remove only the expired browser subscription", context do
    untouched = enroll(context, "untouched", "en")

    for status <- [404, 410] do
      subscription = enroll(context, "expired-#{status}", "en")
      Req.Test.stub(__MODULE__, &send_resp(&1, status, "expired"))
      assert {:error, :expired} == Delivery.test(subscription)
      assert {:error, :not_found} = WebPush.fetch(subscription.client_id, subscription.endpoint)
      assert WebPush.current?(untouched)
    end
  end

  test "a stale 410 response does not delete a subscription refreshed while the request was in flight",
       context do
    original = enroll(context, "browser", "en")
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      refreshed = enroll(context, "browser", "zh_CN")
      send(owner, {:refreshed, refreshed})
      send_resp(conn, 410, "expired")
    end)

    assert {:error, :expired} == Delivery.test(original)
    assert_received {:refreshed, refreshed}
    assert refreshed.revision != original.revision
    assert {:ok, ^refreshed} = WebPush.fetch(original.client_id, original.endpoint)
    assert WebPush.current?(refreshed)
  end

  test "transient provider responses retain subscriptions and return a retry delay without inline retries",
       context do
    subscription = enroll(context, "browser", "en")
    owner = self()

    for status <- [408, 425, 429, 500, 503] do
      Req.Test.stub(__MODULE__, fn conn ->
        send(owner, {:request_status, status})
        conn |> put_resp_header("retry-after", "2") |> send_resp(status, "try later")
      end)

      assert {:error, {:transient, 2_000}} == Delivery.test(subscription)
      assert_received {:request_status, ^status}
      refute_received {:request_status, _}
      assert WebPush.current?(subscription)
    end
  end

  test "transport failures are retryable and Retry-After values are bounded", context do
    subscription = enroll(context, "browser", "en")
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(owner, :transport_attempt)
      Req.Test.transport_error(conn, :timeout)
    end)

    assert {:error, {:transient, 1_000}} == Delivery.test(subscription)
    assert_received :transport_attempt
    refute_received :transport_attempt

    for {value, delay} <- [{"invalid", 1_000}, {"-1", 1_000}, {"0", 1_000}, {"999999", 300_000}] do
      Req.Test.stub(__MODULE__, fn conn ->
        conn |> put_resp_header("retry-after", value) |> send_resp(429, "")
      end)

      assert {:error, {:transient, ^delay}} = Delivery.test(subscription)
    end

    assert WebPush.current?(subscription)
  end

  test "permanent errors and redirects are not retried or followed and do not remove enrollment",
       context do
    subscription = enroll(context, "browser", "en")
    owner = self()

    Application.put_env(:handbean, :web_push,
      subject: "mailto:push@example.com",
      req_options: [plug: {Req.Test, __MODULE__}, redirect: true, retry: :safe_transient]
    )

    for status <- [301, 302, 307, 308, 400, 401, 403] do
      Req.Test.stub(__MODULE__, fn conn ->
        send(owner, {:attempt, conn.host, conn.request_path})

        conn
        |> put_resp_header("location", "http://127.0.0.1/private")
        |> send_resp(status, "denied")
      end)

      assert {:error, :delivery_failed} == Delivery.test(subscription)
      assert_received {:attempt, "fcm.googleapis.com", "/fcm/send/browser"}
      refute_received {:attempt, _, _}
      assert WebPush.current?(subscription)
    end
  end

  test "fanout retries only transient destinations and cleans up expired ones", context do
    successful = enroll(context, "success", "en")
    expired = enroll(context, "expired", "en")
    transient = enroll(context, "transient", "en")
    denied = enroll(context, "denied", "en")
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(owner, {:attempt, conn.request_path})

      case conn.request_path do
        "/fcm/send/success" -> send_resp(conn, 201, "")
        "/fcm/send/expired" -> send_resp(conn, 410, "")
        "/fcm/send/transient" -> conn |> put_resp_header("retry-after", "3") |> send_resp(503, "")
        "/fcm/send/denied" -> send_resp(conn, 403, "")
      end
    end)

    assert %{subscriptions: [^transient], retry_after: 3_000} =
             Delivery.deliver(event(), [successful, expired, transient, denied])

    for token <- ["success", "expired", "transient", "denied"] do
      path = "/fcm/send/" <> token
      assert_received {:attempt, ^path}
    end

    refute_received {:attempt, _}
    assert {:error, :not_found} = WebPush.fetch(expired.client_id, expired.endpoint)
    assert WebPush.current?(successful)
    assert WebPush.current?(transient)
    assert WebPush.current?(denied)
  end

  test "removed and refreshed subscriptions are not sent or scheduled for retry", context do
    removed = enroll(context, "removed", "en")
    stale = enroll(context, "refreshed", "en")
    fresh = enroll(context, "refreshed", "zh_CN")
    assert :ok == WebPush.unsubscribe(removed.client_id, removed.endpoint)

    assert {:error, :not_found} == Delivery.test(removed)
    assert {:error, :not_found} == Delivery.test(stale)
    assert %{subscriptions: [], retry_after: 0} = Delivery.deliver(event(), [removed, stale])
    assert WebPush.current?(fresh)
  end

  test "password and access-mode rotation suppress pending delivery", context do
    subscription = enroll(context, "browser", "en")

    for access <- [
          [mode: :password, username: "push-test", password: "test-pass-v2"],
          [mode: :local]
        ] do
      Application.put_env(:handbean, :access, access)
      assert {:error, :not_found} == Delivery.test(subscription)
      assert %{subscriptions: [], retry_after: 0} = Delivery.deliver(event(), [subscription])
    end
  end

  test "a transient retry rechecks access and sends nothing after password rotation", context do
    subscription = enroll(context, "browser", "en")
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(owner, :attempt)
      send_resp(conn, 503, "")
    end)

    assert %{subscriptions: [^subscription] = retry, retry_after: 1_000} =
             Delivery.deliver(event(), [subscription])

    assert_received :attempt

    Application.put_env(:handbean, :access,
      mode: :password,
      username: "push-test",
      password: "rotated"
    )

    assert %{subscriptions: [], retry_after: 0} = Delivery.deliver(event(), retry)
    refute_received :attempt
  end

  test "cancelled task events do not send notifications", context do
    subscription = enroll(context, "browser", "en")
    {:ended, task, _reason} = event()

    assert %{subscriptions: [], retry_after: 0} =
             Delivery.deliver({:ended, task, :cancelled}, [subscription])
  end

  defp enroll(context, client_id, locale) do
    attrs = %{
      "endpoint" => "https://fcm.googleapis.com/fcm/send/#{client_id}",
      "keys" => context.keys
    }

    assert {:ok, subscription} = WebPush.subscribe(client_id, attrs, locale)
    subscription
  end

  defp event do
    {:ended, %{run_id: "run", workspace_id: "workspace", conversation_id: "conversation"},
     :completed}
  end

  defp translated(message, locale) do
    Gettext.with_locale(Handbean.Gettext, locale, fn ->
      Gettext.gettext(Handbean.Gettext, message)
    end)
  end

  defp assert_vapid("vapid t=" <> parameters) do
    [jwt, encoded_public] = String.split(parameters, ", k=")
    [header, claims, signature] = String.split(jwt, ".")
    assert JSON.decode!(decode(header)) == %{"alg" => "ES256", "typ" => "JWT"}
    assert {:ok, %{public_key: ^encoded_public}} = WebPush.public_config()
    assert <<r::256, s::256>> = decode(signature)
    der = :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})
    public = {{:ECPoint, decode(encoded_public)}, {:namedCurve, {1, 2, 840, 10_045, 3, 1, 7}}}
    assert :public_key.verify(header <> "." <> claims, :sha256, der, public)
    claims = JSON.decode!(decode(claims))
    assert claims["aud"] == "https://fcm.googleapis.com"
    assert claims["sub"] == "mailto:push@example.com"
    now = System.system_time(:second)
    assert claims["exp"] > now
    assert claims["exp"] <= now + 86_400
  end

  defp decrypt(encrypted, context) do
    assert <<salt::binary-size(16), record_size::32, 65, sender::binary-size(65), record::binary>> =
             encrypted

    assert byte_size(encrypted) <= 4096
    assert byte_size(record) < record_size
    receiver = decode(context.receiver.public_key)
    shared = :crypto.compute_key(:ecdh, sender, decode(context.receiver.private_key), :prime256v1)
    auth_prk = :crypto.mac(:hmac, :sha256, decode(context.keys["auth"]), shared)

    ikm =
      :crypto.mac(
        :hmac,
        :sha256,
        auth_prk,
        "WebPush: info" <> <<0>> <> receiver <> sender <> <<1>>
      )

    prk = :crypto.mac(:hmac, :sha256, salt, ikm)

    <<cek::binary-size(16), _::binary>> =
      :crypto.mac(:hmac, :sha256, prk, "Content-Encoding: aes128gcm" <> <<0, 1>>)

    <<nonce::binary-size(12), _::binary>> =
      :crypto.mac(:hmac, :sha256, prk, "Content-Encoding: nonce" <> <<0, 1>>)

    ciphertext_size = byte_size(record) - 16
    <<ciphertext::binary-size(^ciphertext_size), tag::binary-size(16)>> = record

    plaintext =
      :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, ciphertext, <<>>, tag, false)

    assert is_binary(plaintext)
    payload_size = byte_size(plaintext) - 1
    assert <<payload::binary-size(^payload_size), 2>> = plaintext
    JSON.decode!(payload)
  end

  defp decode(encoded), do: Base.url_decode64!(encoded, padding: false)
end
