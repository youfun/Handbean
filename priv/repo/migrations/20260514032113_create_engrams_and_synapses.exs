defmodule Handbean.Repo.Migrations.CreateEngramsAndSynapses do
  use Ecto.Migration

  def change do
    create table(:engrams) do
      add :content, :text, null: false
      add :kind, :string, null: false
      add :short_term, :boolean, default: true, null: false
      add :expires_at, :utc_datetime
      add :reinforced_count, :integer, default: 0, null: false
      add :last_reinforced_at, :utc_datetime
      add :metadata, :json, default: %{}

      timestamps()
    end

    create index(:engrams, [:kind])
    create index(:engrams, [:expires_at])
    create index(:engrams, [:short_term])

    create table(:synapses) do
      add :source_id, references(:engrams, on_delete: :delete_all), null: false
      add :target_id, references(:engrams, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :strength, :float, default: 1.0, null: false
      add :metadata, :json, default: %{}

      timestamps()
    end

    create index(:synapses, [:source_id])
    create index(:synapses, [:target_id])
    create unique_index(:synapses, [:source_id, :target_id, :kind])
  end
end
