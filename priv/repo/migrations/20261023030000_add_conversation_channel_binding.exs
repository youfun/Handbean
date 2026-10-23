defmodule Handbean.Repo.Migrations.AddConversationChannelBinding do
  use Ecto.Migration

  def change do
    alter table(:conversations) do
      add :channel_binding, :map
    end
  end
end
