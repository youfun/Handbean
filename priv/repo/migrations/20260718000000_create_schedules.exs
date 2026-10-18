defmodule Handbean.Repo.Migrations.CreateSchedules do
  use Ecto.Migration

  def change do
    create table(:schedules, primary_key: false) do
      add :id, :string, primary_key: true
      add :workspace_id, :string, null: false

      add :conversation_id,
          references(:conversations, type: :string, on_delete: :delete_all),
          null: false

      add :name, :string, null: false
      add :instruction, :text, null: false
      add :rule, :map, null: false
      add :time_zone, :string, null: false
      add :model, :string, null: false
      add :reasoning_level, :string
      add :status, :string, null: false, default: "active"
      add :next_run_at, :utc_datetime
      add :version, :integer, null: false, default: 1
      add :created_by, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:schedules, [:workspace_id])
    create index(:schedules, [:conversation_id])
    create index(:schedules, [:status, :next_run_at])

    create table(:schedule_runs, primary_key: false) do
      add :id, :string, primary_key: true

      add :schedule_id, references(:schedules, type: :string, on_delete: :delete_all), null: false

      add :slot_at, :utc_datetime
      add :kind, :string, null: false
      add :request_id, :string, null: false
      add :status, :string, null: false
      add :reason, :string
      add :run_id, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:schedule_runs, [:schedule_id, :slot_at],
             where: "slot_at IS NOT NULL",
             name: :schedule_runs_slot_unique
           )

    create index(:schedule_runs, [:run_id])
    create index(:schedule_runs, [:schedule_id, :inserted_at])
  end
end
