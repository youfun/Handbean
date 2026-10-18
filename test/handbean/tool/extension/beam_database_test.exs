defmodule Handbean.Tool.Extension.Beam.DatabaseTest do
  use ExUnit.Case, async: false

  alias Handbean.Tool.Extension.Beam.Database

  defmodule ExtraRepo do
    def __adapter__, do: Ecto.Adapters.SQLite3
  end

  setup do
    original_repos = Application.get_env(:handbean, :ecto_repos)

    on_exit(fn ->
      if is_nil(original_repos) do
        Application.delete_env(:handbean, :ecto_repos)
      else
        Application.put_env(:handbean, :ecto_repos, original_repos)
      end
    end)

    :ok
  end

  test "requires an explicit repo when multiple repositories are configured" do
    Application.put_env(:handbean, :ecto_repos, [Handbean.Repo, ExtraRepo])

    assert {:error, reason} = Database.resolve_repo(nil)
    assert reason =~ "Multiple Ecto repositories"
    assert reason =~ "Handbean.Repo"
    assert reason =~ inspect(ExtraRepo)

    assert {:ok, selected} = Database.resolve_repo(inspect(ExtraRepo))
    assert selected.repo == ExtraRepo
    assert selected.dialect == "sqlite"
  end

  test "unknown repo names do not create atoms" do
    missing = "DefinitelyMissing.Repo#{System.unique_integer([:positive])}"
    atom_name = "Elixir." <> missing

    assert_raise ArgumentError, fn -> String.to_existing_atom(atom_name) end
    assert {:error, reason} = Database.resolve_repo(missing)
    assert reason =~ "Unknown Ecto repository"
    assert_raise ArgumentError, fn -> String.to_existing_atom(atom_name) end
  end

  test "maps known Ecto adapters to dialect and parameter metadata" do
    assert Database.dialect(Ecto.Adapters.SQLite3) == {"sqlite", "?"}
    assert Database.dialect(Ecto.Adapters.Postgres) == {"postgresql", "$1, $2, ..."}
    assert Database.dialect(Ecto.Adapters.MyXQL) == {"mysql", "?"}
    assert Database.dialect(Ecto.Adapters.Tds) == {"sql_server", "@1, @2, ..."}
    assert Database.dialect(__MODULE__) == {"unknown", "adapter-specific"}
  end

  test "normalizes database-specific values without crashing JSON encoding" do
    result = %{
      columns: ["payload", "amount"],
      rows: [[<<255, 0, 1>>, Decimal.new("12.340")]]
    }

    assert {[%{"payload" => "0xFF0001", "amount" => "12.340"}], false} =
             Database.result_rows(result)
  end

  test "uses a caller-selected row limit" do
    rows = for value <- 1..60, do: [value]
    assert {visible, true} = Database.result_rows(%{columns: ["value"], rows: rows}, 55)
    assert length(visible) == 55
  end

  test "limits structured results to fifty rows by default" do
    rows = for value <- 1..60, do: [value]
    assert {visible, true} = Database.result_rows(%{columns: ["value"], rows: rows})
    assert length(visible) == 50
  end
end
