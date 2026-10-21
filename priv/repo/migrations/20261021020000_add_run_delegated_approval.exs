defmodule Handbean.Repo.Migrations.AddRunDelegatedApproval do
  use Ecto.Migration

  def change do
    alter table(:conversation_runs) do
      add :delegated_approval, :string
    end
  end
end
