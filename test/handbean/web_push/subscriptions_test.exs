defmodule Handbean.WebPush.SubscriptionsTest do
  use Handbean.DataCase, async: false

  alias Handbean.JSON
  alias Handbean.WebPush
  alias Handbean.WebPush.Keys
  alias Handbean.WebPush.Protocol
  alias Handbean.WebPush.Subscription

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
    receiver = Protocol.generate_key_pair()
    auth = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    %{keys: %{"p256dh" => receiver.public_key, "auth" => auth}}
  end

  test "VAPID identity is persisted and reused across independent callers" do
    assert {:ok, first} = Keys.ensure()
    assert :ok == Protocol.validate_key_pair(first)
    assert Repo.get!(Keys, "vapid").private_key == first.private_key

    second = Task.async(fn -> Keys.ensure() end) |> Task.await()
    assert {:ok, ^first} = second
    assert {:ok, ^first} = Keys.ensure()
    assert Repo.aggregate(Keys, :count) == 1
  end

  test "public configuration contains only the persistent public VAPID identity" do
    assert {:ok, keys} = Keys.ensure()
    assert {:ok, config} = WebPush.public_config()
    assert config == %{configured: true, public_key: keys.public_key}
    refute String.contains?(JSON.encode!(config), keys.private_key)
    refute String.contains?(inspect(keys), keys.private_key)
    assert {:ok, ^config} = WebPush.public_config()
  end

  test "missing or rejected contact configuration does not create keys or enroll browsers",
       context do
    for subject <- [nil, "http://example.com/contact", "https://LOCALHOST/contact"] do
      Application.put_env(:handbean, :web_push, subject: subject)
      refute WebPush.configured?()
      assert {:ok, %{configured: false, public_key: nil}} = WebPush.public_config()
      assert {:error, :not_configured} = WebPush.subscribe("browser", subscription(context), "en")
    end

    assert Repo.aggregate(Keys, :count) == 0
    assert Repo.aggregate(Subscription, :count) == 0
  end

  test "enrollment persists ownership, locale, expiry and browser encryption keys", context do
    expires_ms = System.system_time(:millisecond) + 3_600_000
    browser = subscription(context) |> Map.put("expirationTime", expires_ms)
    assert {:ok, saved} = WebPush.subscribe("browser", browser, "zh_CN")
    assert {:ok, fetched} = WebPush.fetch("browser", browser["endpoint"])
    assert fetched == saved
    assert fetched.p256dh == context.keys["p256dh"]
    assert fetched.auth == context.keys["auth"]
    assert fetched.locale == "zh_CN"
    assert DateTime.to_unix(fetched.expires_at, :millisecond) == expires_ms
    assert fetched.access_epoch == WebPush.access_epoch()
    assert WebPush.current?(fetched)
    assert [^fetched] = WebPush.subscriptions()
  end

  test "an endpoint cannot be claimed by another browser", context do
    browser = subscription(context)
    assert {:ok, original} = WebPush.subscribe("owner", browser, "en")
    assert {:error, :subscription_conflict} = WebPush.subscribe("other", browser, "zh_CN")
    assert {:ok, ^original} = WebPush.fetch("owner", browser["endpoint"])
    assert {:error, :not_found} = WebPush.fetch("other", browser["endpoint"])
    assert Repo.aggregate(Subscription, :count) == 1
  end

  test "unsubscribe is idempotent and cannot remove another browser's subscription", context do
    first = subscription(context, "first")
    second = subscription(context, "second")
    assert {:ok, owner} = WebPush.subscribe("owner", first, "en")
    assert {:ok, other} = WebPush.subscribe("other", second, "en")

    assert :ok == WebPush.unsubscribe("other", first["endpoint"])
    assert :ok == WebPush.unsubscribe("owner", second["endpoint"])
    assert {:ok, ^owner} = WebPush.fetch("owner", first["endpoint"])
    assert {:ok, ^other} = WebPush.fetch("other", second["endpoint"])

    assert :ok == WebPush.unsubscribe("owner", first["endpoint"])
    assert :ok == WebPush.unsubscribe("owner", first["endpoint"])
    assert {:error, :not_found} = WebPush.fetch("owner", first["endpoint"])
    assert {:ok, ^other} = WebPush.fetch("other", second["endpoint"])
  end

  test "the 32-browser cap allows a current browser to refresh but rejects new enrollment",
       context do
    for index <- 1..32 do
      assert {:ok, _saved} =
               WebPush.subscribe(
                 "browser-#{index}",
                 subscription(context, "limit-#{index}"),
                 "en"
               )
    end

    assert {:error, :subscription_limit} =
             WebPush.subscribe("browser-33", subscription(context, "limit-33"), "en")

    assert {:ok, refreshed} =
             WebPush.subscribe("browser-1", subscription(context, "replacement"), "zh_CN")

    assert refreshed.locale == "zh_CN"
    assert Repo.aggregate(Subscription, :count) == 32

    assert {:error, :not_found} =
             WebPush.fetch("browser-1", subscription(context, "limit-1")["endpoint"])
  end

  test "invalid endpoints and subscription keys never produce persisted subscriptions", context do
    browser = subscription(context)

    invalid = [
      %{},
      Map.put(browser, "endpoint", "https://localhost/push"),
      Map.put(browser, "endpoint", "http://fcm.googleapis.com/push"),
      Map.put(browser, "endpoint", "https://fcm.googleapis.com.evil.example/push"),
      Map.put(browser, "keys", %{}),
      put_in(browser, ["keys", "auth"], "bad"),
      put_in(browser, ["keys", "p256dh"], Base.url_encode64(<<4, 0::512>>, padding: false))
    ]

    for attrs <- invalid do
      assert {:error, :invalid_subscription} = WebPush.subscribe("browser", attrs, "en")
    end

    assert {:error, :invalid_subscription} = WebPush.subscribe("browser", browser, "unsupported")
    assert {:error, :invalid_subscription} = WebPush.subscribe("", browser, "en")

    assert {:error, :invalid_subscription} =
             WebPush.subscribe(String.duplicate("x", 129), browser, "en")

    assert Repo.aggregate(Subscription, :count) == 0
  end

  test "expiration must be a future millisecond timestamp or null", context do
    for expiration <- [-1, 0, System.system_time(:millisecond) - 1_000, "tomorrow", 1.5, 10 ** 30] do
      attrs = Map.put(subscription(context), "expirationTime", expiration)
      assert {:error, :invalid_subscription} = WebPush.subscribe("browser", attrs, "en")
    end

    attrs = Map.put(subscription(context), "expirationTime", nil)
    assert {:ok, %{expires_at: nil}} = WebPush.subscribe("browser", attrs, "en")
  end

  test "password rotation suppresses and prunes prior subscriptions but permits re-enrollment",
       context do
    attrs = subscription(context)
    assert {:ok, old} = WebPush.subscribe("browser", attrs, "en")

    Application.put_env(:handbean, :access,
      mode: :password,
      username: "push-test",
      password: "test-pass-v2"
    )

    refute WebPush.current?(old)
    assert {:error, :not_found} = WebPush.fetch("browser", attrs["endpoint"])
    assert WebPush.subscriptions() == []
    assert {:ok, fresh} = WebPush.subscribe("browser", attrs, "en")
    assert fresh.access_epoch != old.access_epoch
    assert WebPush.current?(fresh)
  end

  test "access-mode changes and disabled access suppress previous enrollment", context do
    assert {:ok, old} = WebPush.subscribe("browser", subscription(context), "en")
    Application.put_env(:handbean, :access, mode: :local)
    refute WebPush.current?(old)
    assert WebPush.subscriptions() == []

    assert {:ok, local} = WebPush.subscribe("browser", subscription(context), "en")
    Application.put_env(:handbean, :access, mode: :password, username: "push-test", password: "")
    refute WebPush.configured?()
    refute WebPush.current?(local)
    assert WebPush.subscriptions() == []
  end

  test "stale expiry cannot delete a refreshed or replaced subscription", context do
    attrs = subscription(context)
    assert {:ok, first} = WebPush.subscribe("browser", attrs, "en")
    assert {:ok, refreshed} = WebPush.subscribe("browser", attrs, "zh_CN")
    assert refreshed.revision != first.revision
    refute WebPush.current?(first)
    assert :ok == WebPush.expire(first)
    assert {:ok, ^refreshed} = WebPush.fetch("browser", attrs["endpoint"])

    replacement = subscription(context, "new-endpoint")
    assert {:ok, replaced} = WebPush.subscribe("browser", replacement, "en")
    assert :ok == WebPush.expire(refreshed)
    assert {:ok, ^replaced} = WebPush.fetch("browser", replacement["endpoint"])
    assert :ok == WebPush.expire(replaced)
    assert {:error, :not_found} = WebPush.fetch("browser", replacement["endpoint"])
  end

  test "expired persisted subscriptions are suppressed and pruned without expiring active ones",
       context do
    assert {:ok, expired} = WebPush.subscribe("expired", subscription(context, "expired"), "en")
    assert {:ok, active} = WebPush.subscribe("active", subscription(context, "active"), "en")

    expired
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -60, :second))
    |> Repo.update!()

    refute WebPush.current?(expired)
    assert [^active] = WebPush.subscriptions()
    assert {:error, :not_found} = WebPush.fetch(expired.client_id, expired.endpoint)
  end

  defp subscription(context, token \\ "subscription") do
    %{"endpoint" => "https://fcm.googleapis.com/fcm/send/#{token}", "keys" => context.keys}
  end
end
