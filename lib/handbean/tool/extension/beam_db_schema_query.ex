defmodule Handbean.Tool.Extension.Beam.DbSchema.Query do
  @moduledoc false

  @type operation ::
          :list_tables | :describe_table | :list_indexes | :list_foreign_keys

  @spec build(String.t(), operation(), map()) ::
          {:ok, String.t(), list()} | {:error, String.t()}
  def build("sqlite", :list_tables, _args) do
    {:ok,
     """
     SELECT 'main' AS schema, name, type
     FROM sqlite_master
     WHERE type IN ('table', 'view')
       AND name NOT LIKE 'sqlite_%'
     ORDER BY type, name
     """, []}
  end

  def build("sqlite", :describe_table, %{table: table}) do
    {:ok,
     """
     SELECT cid AS ordinal,
            name,
            type,
            CASE \"notnull\" WHEN 0 THEN 1 ELSE 0 END AS nullable,
            dflt_value AS default_value,
            pk AS primary_key
     FROM pragma_table_info(?)
     ORDER BY cid
     """, [table]}
  end

  def build("sqlite", :list_indexes, %{table: table}) do
    {:ok,
     """
     SELECT seq AS ordinal,
            name,
            \"unique\" AS is_unique,
            origin,
            partial
     FROM pragma_index_list(?)
     ORDER BY seq
     """, [table]}
  end

  def build("sqlite", :list_foreign_keys, %{table: table}) do
    {:ok,
     """
     SELECT id,
            seq AS ordinal,
            \"table\" AS target_table,
            \"from\" AS source_column,
            \"to\" AS target_column,
            on_update,
            on_delete,
            match
     FROM pragma_foreign_key_list(?)
     ORDER BY id, seq
     """, [table]}
  end

  def build("postgresql", :list_tables, args) do
    {:ok,
     """
     SELECT namespace.nspname AS schema,
            class.relname AS name,
            CASE class.relkind
              WHEN 'r' THEN 'table'
              WHEN 'p' THEN 'partitioned_table'
              WHEN 'v' THEN 'view'
              WHEN 'm' THEN 'materialized_view'
              WHEN 'f' THEN 'foreign_table'
            END AS type
     FROM pg_catalog.pg_class AS class
     JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = class.relnamespace
     WHERE class.relkind IN ('r', 'p', 'v', 'm', 'f')
       AND namespace.nspname NOT IN ('pg_catalog', 'information_schema')
       AND namespace.nspname NOT LIKE 'pg_toast%'
       AND ($1::text IS NULL OR namespace.nspname = $1)
     ORDER BY namespace.nspname, class.relname
     """, [Map.get(args, :schema)]}
  end

  def build("postgresql", :describe_table, %{table: table} = args) do
    {:ok,
     """
     SELECT ordinal_position AS ordinal,
            column_name AS name,
            data_type AS type,
            CASE is_nullable WHEN 'YES' THEN true ELSE false END AS nullable,
            column_default AS default_value
     FROM information_schema.columns
     WHERE table_schema = COALESCE($1, 'public')
       AND table_name = $2
     ORDER BY ordinal_position
     """, [Map.get(args, :schema), table]}
  end

  def build("postgresql", :list_indexes, %{table: table} = args) do
    {:ok,
     """
     SELECT schemaname AS schema,
            indexname AS name,
            indexdef AS definition
     FROM pg_catalog.pg_indexes
     WHERE schemaname = COALESCE($1, 'public')
       AND tablename = $2
     ORDER BY indexname
     """, [Map.get(args, :schema), table]}
  end

  def build("postgresql", :list_foreign_keys, %{table: table} = args) do
    {:ok,
     """
     SELECT constraint_record.conname AS name,
            source_attribute.attname AS source_column,
            target_namespace.nspname AS target_schema,
            target_table.relname AS target_table,
            target_attribute.attname AS target_column,
            key_columns.ordinality AS ordinal
     FROM pg_catalog.pg_constraint AS constraint_record
     JOIN pg_catalog.pg_class AS source_table
       ON source_table.oid = constraint_record.conrelid
     JOIN pg_catalog.pg_namespace AS source_namespace
       ON source_namespace.oid = source_table.relnamespace
     JOIN pg_catalog.pg_class AS target_table
       ON target_table.oid = constraint_record.confrelid
     JOIN pg_catalog.pg_namespace AS target_namespace
       ON target_namespace.oid = target_table.relnamespace
     CROSS JOIN LATERAL unnest(constraint_record.conkey, constraint_record.confkey)
       WITH ORDINALITY AS key_columns(source_attnum, target_attnum, ordinality)
     JOIN pg_catalog.pg_attribute AS source_attribute
       ON source_attribute.attrelid = source_table.oid
      AND source_attribute.attnum = key_columns.source_attnum
     JOIN pg_catalog.pg_attribute AS target_attribute
       ON target_attribute.attrelid = target_table.oid
      AND target_attribute.attnum = key_columns.target_attnum
     WHERE constraint_record.contype = 'f'
       AND source_namespace.nspname = COALESCE($1, 'public')
       AND source_table.relname = $2
     ORDER BY constraint_record.conname, key_columns.ordinality
     """, [Map.get(args, :schema), table]}
  end

  def build("mysql", :list_tables, args) do
    {:ok,
     """
     SELECT table_schema AS `schema`,
            table_name AS name,
            LOWER(REPLACE(table_type, ' ', '_')) AS type
     FROM information_schema.tables
     WHERE table_schema = COALESCE(?, DATABASE())
     ORDER BY table_name
     """, [Map.get(args, :schema)]}
  end

  def build("mysql", :describe_table, %{table: table} = args) do
    {:ok,
     """
     SELECT ordinal_position AS ordinal,
            column_name AS name,
            column_type AS type,
            CASE is_nullable WHEN 'YES' THEN TRUE ELSE FALSE END AS nullable,
            column_default AS default_value,
            CASE column_key WHEN 'PRI' THEN TRUE ELSE FALSE END AS primary_key
     FROM information_schema.columns
     WHERE table_schema = COALESCE(?, DATABASE())
       AND table_name = ?
     ORDER BY ordinal_position
     """, [Map.get(args, :schema), table]}
  end

  def build("mysql", :list_indexes, %{table: table} = args) do
    {:ok,
     """
     SELECT index_name AS name,
            CASE non_unique WHEN 0 THEN TRUE ELSE FALSE END AS is_unique,
            seq_in_index AS ordinal,
            column_name
     FROM information_schema.statistics
     WHERE table_schema = COALESCE(?, DATABASE())
       AND table_name = ?
     ORDER BY index_name, seq_in_index
     """, [Map.get(args, :schema), table]}
  end

  def build("mysql", :list_foreign_keys, %{table: table} = args) do
    {:ok,
     """
     SELECT constraint_name AS name,
            column_name AS source_column,
            referenced_table_schema AS target_schema,
            referenced_table_name AS target_table,
            referenced_column_name AS target_column,
            ordinal_position AS ordinal
     FROM information_schema.key_column_usage
     WHERE table_schema = COALESCE(?, DATABASE())
       AND table_name = ?
       AND referenced_table_name IS NOT NULL
     ORDER BY constraint_name, ordinal_position
     """, [Map.get(args, :schema), table]}
  end

  def build(dialect, _operation, _args) do
    {:error, "Schema introspection is not supported for database dialect #{inspect(dialect)}"}
  end
end
