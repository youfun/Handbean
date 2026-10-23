defmodule Handbean.WebPush do
  @moduledoc "Browser push subscriptions, scoped to the authenticated browser and access configuration."

  import Ecto.Query

  alias Handbean.Repo
  alias Handbean.Storage.WriteTransaction
  alias Handbean.WebPush.Keys
  alias Handbean.WebPush.Protocol
  alias Handbean.WebPush.Subscription

  @max_subscriptions 32

  @doc "Web Push requires an explicitly configured VAPID contact URI."
  def configured?, do: not is_nil(subject()) and not is_nil(access_epoch())

  def subject do
    value = Application.get_env(:handbean, :web_push, [])[:subject]

    if Protocol.validate_subject(value) == :ok, do: value
  end

  @doc "Only the public part of the persistent VAPID identity is exposed to browsers."
  def public_config do
    if configured?() do
      with {:ok, keys} <- Keys.ensure() do
        {:ok, %{configured: true, public_key: keys.public_key}}
      end
    else
      {:ok, %{configured: false, public_key: nil}}
    end
  end

  @doc "An access change revokes future deliveries to previously enrolled browsers."
  def access_epoch do
    access = Application.get_env(:handbean, :access, [])
    secret = Application.get_env(:handbean, :web_push_access_secret)
    mode = Keyword.get(access, :mode, :local)
    username = Keyword.get(access, :username)
    password = Keyword.get(access, :password)

    identity =
      case mode do
        :local ->
          "local"

        :password when is_binary(username) and is_binary(password) and password != "" ->
          Handbean.JSON.encode!(["password", username, password])

        _ ->
          nil
      end

    if is_binary(identity) and is_binary(secret) and secret != "" do
      :crypto.mac(:hmac, :sha256, secret, "handbean.web_push.access.v1\0" <> identity)
      |> Base.url_encode64(padding: false)
    end
  end

  @doc "Enroll or refresh this browser without taking ownership of another browser's endpoint."
  def subscribe(client_id, subscription, locale)
      when is_binary(client_id) and is_map(subscription) do
    with true <- configured?(),
         {:ok, attrs} <- subscription_attrs(client_id, subscription, locale) do
      fn ->
        prune_revoked()
        endpoint_owner = Repo.get_by(Subscription, [endpoint: attrs.endpoint], log: false)
        existing = Repo.get(Subscription, client_id, log: false)

        cond do
          endpoint_owner && endpoint_owner.client_id != client_id ->
            Repo.rollback(:subscription_conflict)

          is_nil(existing) and Repo.aggregate(Subscription, :count) >= @max_subscriptions ->
            Repo.rollback(:subscription_limit)

          true ->
            record = existing || %Subscription{}

            case record
                 |> Subscription.changeset(attrs)
                 |> Repo.insert_or_update(log: false) do
              {:ok, saved} -> saved
              {:error, _changeset} -> Repo.rollback(:invalid_subscription)
            end
        end
      end
      |> WriteTransaction.run()
    else
      false -> {:error, :not_configured}
      {:error, reason} -> {:error, reason}
    end
  end

  def subscribe(_client_id, _subscription, _locale), do: {:error, :invalid_subscription}

  @doc "Idempotently remove only the calling browser's endpoint."
  def unsubscribe(client_id, endpoint) when is_binary(client_id) and is_binary(endpoint) do
    WriteTransaction.run(fn ->
      from(s in Subscription, where: s.client_id == ^client_id and s.endpoint == ^endpoint)
      |> Repo.delete_all(log: false)
    end)

    :ok
  end

  @doc "Look up a browser-owned subscription under the current access configuration."
  def fetch(client_id, endpoint) when is_binary(client_id) and is_binary(endpoint) do
    epoch = access_epoch()

    if epoch do
      Repo.one(
        from(s in Subscription,
          where:
            s.client_id == ^client_id and s.endpoint == ^endpoint and s.access_epoch == ^epoch
        ),
        log: false
      )
      |> present()
    else
      {:error, :not_found}
    end
  end

  def fetch(_client_id, _endpoint), do: {:error, :not_found}

  @doc "Return eligible subscriptions; inactivity does not expire a browser subscription."
  def subscriptions do
    if configured?() do
      prune_revoked()
      Repo.all(Subscription, log: false)
    else
      []
    end
  end

  @doc "Check again immediately before sending, including after a retry or credential change."
  def current?(%Subscription{} = subscription) do
    with true <- configured?(),
         {:ok, current} <- fetch(subscription.client_id, subscription.endpoint) do
      current.revision == subscription.revision and not expired?(current)
    else
      _ -> false
    end
  end

  @doc "A stale provider response must not delete a replacement or refreshed subscription."
  def expire(%Subscription{} = subscription) do
    WriteTransaction.run(fn ->
      from(s in Subscription,
        where: s.client_id == ^subscription.client_id and s.revision == ^subscription.revision
      )
      |> Repo.delete_all(log: false)
    end)

    :ok
  end

  defp prune_revoked do
    epoch = access_epoch()
    now = DateTime.utc_now()

    if epoch do
      query =
        from(s in Subscription,
          where: s.access_epoch != ^epoch or (not is_nil(s.expires_at) and s.expires_at <= ^now)
        )

      cond do
        Repo.in_transaction?() ->
          Repo.delete_all(query, log: false)

        Repo.exists?(query, log: false) ->
          WriteTransaction.run(fn -> Repo.delete_all(query, log: false) end)

        true ->
          :ok
      end
    end
  end

  defp subscription_attrs(
         client_id,
         %{"endpoint" => endpoint, "keys" => keys} = subscription,
         locale
       )
       when is_binary(endpoint) and is_map(keys) and locale in ["en", "zh_CN"] do
    with {:ok, expires_at} <- expiration(subscription["expirationTime"]) do
      {:ok,
       %{
         client_id: client_id,
         endpoint: endpoint,
         p256dh: keys["p256dh"],
         auth: keys["auth"],
         locale: locale,
         access_epoch: access_epoch(),
         revision: Ecto.UUID.generate(),
         expires_at: expires_at
       }}
    end
  end

  defp subscription_attrs(_client_id, _subscription, _locale),
    do: {:error, :invalid_subscription}

  defp expiration(nil), do: {:ok, nil}

  defp expiration(value) when is_integer(value) do
    case DateTime.from_unix(value, :millisecond) do
      {:ok, expires_at} ->
        if DateTime.compare(expires_at, DateTime.utc_now()) == :gt,
          do: {:ok, expires_at},
          else: {:error, :invalid_subscription}

      _ ->
        {:error, :invalid_subscription}
    end
  end

  defp expiration(_), do: {:error, :invalid_subscription}

  defp expired?(%Subscription{expires_at: nil}), do: false

  defp expired?(%Subscription{expires_at: expires_at}),
    do: DateTime.compare(expires_at, DateTime.utc_now()) != :gt

  defp present(nil), do: {:error, :not_found}
  defp present(subscription), do: {:ok, subscription}
end
