defmodule Handbean.Storage.Diagnostics do
  @moduledoc "Explicit SQLite health diagnostics and verified online backup."

  alias Exqlite.Sqlite3
  alias Handbean.Repo

  @required_tables ~w(conversations conversation_entries conversation_editor_states conversation_run_usage operation_receipts session_snapshots)
  @required_indexes ~w(conversation_entries_conversation_id_entry_id_index conversation_entries_conversation_id_sequence_index conversation_entries_streaming_assistant_index conversation_entries_running_tool_index operation_receipts_scope_kind_scope_id_request_id_index)

  @spec check() :: {:ok, map()} | {:error, term()}
  def check do
    with {:ok, quick} <- rows("PRAGMA quick_check"),
         {:ok, foreign_keys} <- rows("PRAGMA foreign_key_check"),
         {:ok, tables} <- object_names("table"),
         {:ok, indexes} <- object_names("index"),
         {:ok, journal_mode} <- scalar("PRAGMA journal_mode"),
         {:ok, schema_version} <- schema_version() do
      missing_tables = @required_tables -- tables
      missing_indexes = @required_indexes -- indexes

      report = %{
        healthy?:
          quick == [["ok"]] and foreign_keys == [] and missing_tables == [] and
            missing_indexes == [],
        quick_check: quick,
        foreign_key_violations: foreign_keys,
        missing_tables: missing_tables,
        missing_indexes: missing_indexes,
        journal_mode: journal_mode,
        wal_checkpoint: checkpoint_status(),
        schema_version: schema_version
      }

      if report.healthy?, do: {:ok, report}, else: {:error, {:unhealthy, report}}
    end
  end

  @spec backup(String.t()) :: {:ok, map()} | {:error, term()}
  def backup(target) when is_binary(target) and target != "" do
    target = Path.expand(target)
    source = Repo.database_path()

    cond do
      target == source ->
        {:error, :source_is_target}

      File.exists?(target) ->
        {:error, :already_exists}

      true ->
        temporary = target <> ".tmp-#{Ecto.UUID.generate()}"

        with :ok <- File.mkdir_p(Path.dirname(target)),
             {:ok, _} <- Repo.query("VACUUM INTO ?", [temporary]),
             {:ok, verification} <- verify_backup(temporary),
             :ok <- File.rename(temporary, target) do
          {:ok, %{verified?: true, schema_version: verification.schema_version}}
        else
          {:error, reason} ->
            File.rm(temporary)
            {:error, reason}
        end
    end
  end

  defp verify_backup(path) do
    with {:ok, connection} <- Sqlite3.open(path, mode: :readonly) do
      try do
        with {:ok, [["ok"]]} <- raw_rows(connection, "PRAGMA quick_check"),
             {:ok, []} <- raw_rows(connection, "PRAGMA foreign_key_check"),
             {:ok, [[version]]} <-
               raw_rows(connection, "SELECT COALESCE(MAX(version), 0) FROM schema_migrations") do
          {:ok, %{schema_version: version}}
        else
          {:ok, rows} -> {:error, {:backup_check_failed, rows}}
          {:error, reason} -> {:error, reason}
        end
      after
        Sqlite3.close(connection)
      end
    end
  end

  defp rows(sql) do
    case Repo.query(sql) do
      {:ok, %{rows: rows}} -> {:ok, rows}
      {:error, reason} -> {:error, reason}
    end
  end

  defp scalar(sql) do
    case rows(sql) do
      {:ok, [[value]]} -> {:ok, value}
      {:ok, other} -> {:error, {:unexpected_result, other}}
      error -> error
    end
  end

  defp object_names(type) do
    case Repo.query("SELECT name FROM sqlite_master WHERE type = ?", [type]) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, &hd/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp schema_version do
    scalar("SELECT COALESCE(MAX(version), 0) FROM schema_migrations")
  end

  defp checkpoint_status do
    case rows("PRAGMA wal_checkpoint(PASSIVE)") do
      {:ok, rows} ->
        %{status: "ok", pages: rows}

      {:error, reason} ->
        %{status: "error", category: Handbean.Storage.ErrorClassifier.classify(reason)}
    end
  end

  defp raw_rows(connection, sql) do
    with {:ok, statement} <- Sqlite3.prepare(connection, sql) do
      collect_rows(connection, statement, [])
    end
  end

  defp collect_rows(connection, statement, rows) do
    case Sqlite3.step(connection, statement) do
      {:row, row} -> collect_rows(connection, statement, [row | rows])
      :done -> {:ok, Enum.reverse(rows)}
      :busy -> {:error, :busy}
      {:error, reason} -> {:error, reason}
    end
  end
end
