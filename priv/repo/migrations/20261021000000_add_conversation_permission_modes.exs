defmodule Handbean.Repo.Migrations.AddConversationPermissionModes do
  use Ecto.Migration

  def change do
    alter table(:conversations) do
      add :permission_mode, :string, null: false, default: "auto_review"
    end

    alter table(:conversation_runs) do
      add :initial_permission_mode, :string
      add :initial_approval_mode, :string
      add :initial_approvals_reviewer, :string
      add :permission_source, :string
      add :current_permission_mode, :string
      add :permission_changed_at, :utc_datetime_usec
    end

    create table(:conversation_permission_changes) do
      add :conversation_id,
          references(:conversations, type: :string, on_delete: :delete_all),
          null: false

      add :run_id, :string
      add :from_mode, :string, null: false
      add :to_mode, :string, null: false
      add :source, :string, null: false
      timestamps(type: :utc_datetime_usec, inserted_at: :changed_at, updated_at: false)
    end

    create index(:conversation_permission_changes, [:conversation_id, :changed_at])
    create index(:conversation_permission_changes, [:conversation_id, :run_id, :changed_at])
  end
end
