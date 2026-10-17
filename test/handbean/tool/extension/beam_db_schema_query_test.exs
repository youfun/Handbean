defmodule Handbean.Tool.Extension.Beam.DbSchema.QueryTest do
  use ExUnit.Case, async: true

  alias Handbean.Tool.Extension.Beam.DbSchema.Query

  test "PostgreSQL plans use catalog queries and bound schema/table parameters" do
    assert {:ok, list_sql, ["audit"]} =
             Query.build("postgresql", :list_tables, %{schema: "audit"})

    assert list_sql =~ "pg_catalog.pg_class"
    assert list_sql =~ "$1::text"
    refute list_sql =~ "'audit'"

    hostile_table = ~s(users' OR true --)

    assert {:ok, describe_sql, ["public", ^hostile_table]} =
             Query.build("postgresql", :describe_table, %{
               schema: "public",
               table: hostile_table
             })

    assert describe_sql =~ "table_name = $2"
    refute describe_sql =~ hostile_table
  end

  test "PostgreSQL foreign keys pair composite columns by ordinality" do
    assert {:ok, sql, ["audit", "events"]} =
             Query.build("postgresql", :list_foreign_keys, %{
               schema: "audit",
               table: "events"
             })

    assert sql =~ "pg_catalog.pg_constraint"
    assert sql =~ "unnest(constraint_record.conkey, constraint_record.confkey)"
    assert sql =~ "WITH ORDINALITY"
    refute sql =~ "information_schema.constraint_column_usage"
  end

  test "MySQL plans use information_schema with bound parameters" do
    assert {:ok, sql, [nil, "users"]} =
             Query.build("mysql", :list_indexes, %{schema: nil, table: "users"})

    assert sql =~ "information_schema.statistics"
    assert sql =~ "table_schema = COALESCE(?, DATABASE())"
    assert sql =~ "table_name = ?"
  end

  test "SQLite table-specific plans bind the table name" do
    hostile_table = ~s|users"); DROP TABLE users; --|

    assert {:ok, sql, [^hostile_table]} =
             Query.build("sqlite", :describe_table, %{table: hostile_table})

    assert sql =~ "pragma_table_info(?)"
    refute sql =~ hostile_table
  end

  test "unknown adapters fail closed for schema introspection" do
    assert {:error, reason} = Query.build("unknown", :list_tables, %{})
    assert reason =~ "not supported"
  end
end
