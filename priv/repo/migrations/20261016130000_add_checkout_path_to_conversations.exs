defmodule Handbean.Repo.Migrations.AddCheckoutPathToConversations do
  use Ecto.Migration

  def change do
    alter table(:conversations) do
      add :checkout_path, :string
    end
  end
end
