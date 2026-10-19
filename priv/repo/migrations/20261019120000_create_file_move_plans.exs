defmodule Handbean.Repo.Migrations.CreateFileMovePlans do
  use Ecto.Migration

  def change do
    create table(:file_move_plans, primary_key: false) do
      add :id, :string, primary_key: true

      add :conversation_id, references(:conversations, type: :string, on_delete: :delete_all),
        null: false

      add :workspace_id, :string, null: false
      add :checkout_path, :text, null: false
      add :title, :string, null: false
      add :status, :string, null: false, default: "draft"
      add :entries, {:array, :map}, null: false
      add :selected_ids, {:array, :string}, null: false
      add :version, :integer, null: false, default: 1
      add :expires_at, :utc_datetime, null: false
      timestamps(type: :utc_datetime)
    end

    create index(:file_move_plans, [:conversation_id])
  end
end
