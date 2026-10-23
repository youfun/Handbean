defmodule Handbean.Repo.Migrations.AddCodeBaselineToConversationRuns do
  use Ecto.Migration

  def change do
    alter table(:conversation_runs) do
      add :code_baseline, :map
    end
  end
end
