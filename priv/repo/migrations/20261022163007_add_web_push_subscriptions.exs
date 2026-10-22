defmodule Handbean.Repo.Migrations.AddWebPushSubscriptions do
  use Ecto.Migration

  def change do
    create table(:web_push_keys, primary_key: false) do
      add :id, :string, primary_key: true
      add :public_key, :string, null: false
      add :private_key, :string, null: false
    end

    create table(:web_push_subscriptions, primary_key: false) do
      add :client_id, :string, primary_key: true
      add :endpoint, :text, null: false
      add :p256dh, :string, null: false
      add :auth, :string, null: false
      add :access_epoch, :string, null: false
      add :locale, :string, null: false
      add :revision, :string, null: false
      add :expires_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:web_push_subscriptions, [:endpoint])
  end
end
