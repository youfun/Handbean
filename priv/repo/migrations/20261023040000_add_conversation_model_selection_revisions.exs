defmodule Handbean.Repo.Migrations.AddConversationModelSelectionRevisions do
  use Ecto.Migration

  def change do
    alter table(:conversations) do
      add :model_selection_revision, :integer, null: false, default: 0
    end
  end
end
