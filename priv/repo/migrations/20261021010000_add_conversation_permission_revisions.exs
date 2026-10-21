defmodule Handbean.Repo.Migrations.AddConversationPermissionRevisions do
  use Ecto.Migration

  def change do
    alter table(:conversations) do
      add :permission_revision, :integer, null: false, default: 0
    end

    alter table(:conversation_runs) do
      add :initial_permission_revision, :integer
      add :current_permission_revision, :integer
    end

    alter table(:conversation_permission_changes) do
      add :revision, :integer, null: false, default: 0
    end

    create index(:conversation_permission_changes, [:conversation_id, :revision])

    execute(
      "UPDATE conversations SET permission_mode = 'prompt' WHERE scope = 'free'",
      "UPDATE conversations SET permission_mode = 'auto_review' WHERE scope = 'free'"
    )
  end
end
