defmodule Handbean.Repo.Migrations.CreateUISettings do
  use Ecto.Migration

  def change do
    create table(:ui_settings, primary_key: false) do
      add :key, :string, primary_key: true
      add :value, :string, null: false
    end
  end
end
