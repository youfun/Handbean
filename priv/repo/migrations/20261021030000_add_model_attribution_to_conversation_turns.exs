defmodule Handbean.Repo.Migrations.AddModelAttributionToConversationTurns do
  use Ecto.Migration

  def change do
    alter table(:conversation_turns) do
      add :provider, :string
      add :model, :string
      add :reasoning_level, :string
      add :config_revision, :integer, null: false, default: 0
    end
  end
end
