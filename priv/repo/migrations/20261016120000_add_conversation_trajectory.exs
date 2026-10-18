defmodule Handbean.Repo.Migrations.AddConversationTrajectory do
  use Ecto.Migration

  def change do
    alter table(:conversation_entries) do
      add :turn_number, :integer
    end

    create index(:conversation_entries, [:conversation_id, :run_id, :turn_number])

    create table(:conversation_runs) do
      add :conversation_id,
          references(:conversations, type: :string, on_delete: :delete_all),
          null: false

      add :run_id, :string, null: false
      add :status, :string, null: false
      add :stop_reason, :string
      add :loop_owner, :string
      add :backend, :string
      add :model, :string
      add :error, :text
      add :turn_count, :integer, null: false, default: 0
      add :duration_ms, :integer
      add :capture_version, :integer, null: false, default: 1
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create unique_index(:conversation_runs, [:conversation_id, :run_id])
    create index(:conversation_runs, [:conversation_id, :started_at])
    create index(:conversation_runs, [:conversation_id, :status])

    create table(:conversation_turns) do
      add :conversation_id,
          references(:conversations, type: :string, on_delete: :delete_all),
          null: false

      add :run_id, :string, null: false
      add :turn_number, :integer, null: false
      add :status, :string, null: false
      add :stop_reason, :string
      add :duration_ms, :integer
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create unique_index(:conversation_turns, [:conversation_id, :run_id, :turn_number])
    create index(:conversation_turns, [:conversation_id, :run_id, :started_at])
  end
end
