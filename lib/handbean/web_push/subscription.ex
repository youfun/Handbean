defmodule Handbean.WebPush.Subscription do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias Handbean.WebPush.Endpoint
  alias Handbean.WebPush.Protocol

  @primary_key {:client_id, :string, autogenerate: false}
  schema "web_push_subscriptions" do
    field :endpoint, :string, redact: true
    field :p256dh, :string, redact: true
    field :auth, :string, redact: true
    field :access_epoch, :string, redact: true
    field :locale, :string
    field :revision, :string
    field :expires_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [
      :client_id,
      :endpoint,
      :p256dh,
      :auth,
      :access_epoch,
      :locale,
      :revision,
      :expires_at
    ])
    |> validate_required([
      :client_id,
      :endpoint,
      :p256dh,
      :auth,
      :access_epoch,
      :locale,
      :revision
    ])
    |> validate_length(:client_id, max: 128)
    |> validate_inclusion(:locale, ["en", "zh_CN"])
    |> validate_endpoint()
    |> validate_keys()
    |> unique_constraint(:endpoint)
  end

  defp validate_endpoint(changeset) do
    validate_change(changeset, :endpoint, fn :endpoint, endpoint ->
      case Endpoint.validate(endpoint) do
        :ok -> []
        {:error, _} -> [endpoint: "is not a supported HTTPS push service"]
      end
    end)
  end

  defp validate_keys(changeset) do
    keys = %{"p256dh" => get_field(changeset, :p256dh), "auth" => get_field(changeset, :auth)}

    case Protocol.validate_subscription_keys(keys) do
      :ok -> changeset
      {:error, _} -> add_error(changeset, :p256dh, "has invalid push encryption keys")
    end
  end
end
