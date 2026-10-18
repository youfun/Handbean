defmodule Handbean.Storage.DiagnosticsTest do
  use Handbean.DataCase, async: false

  alias Handbean.Storage.Diagnostics

  test "reports quick, foreign-key, schema, index, and WAL health" do
    assert {:ok, report} = Diagnostics.check()
    assert report.healthy?
    assert report.quick_check == [["ok"]]
    assert report.foreign_key_violations == []
    assert report.missing_tables == []
    assert report.missing_indexes == []
    assert report.journal_mode == "wal"
    assert is_integer(report.schema_version)
  end

  test "startup recovery predicates use their partial indexes" do
    plans = [
      {"role = 'assistant' AND status = 'streaming'",
       "conversation_entries_streaming_assistant_index"},
      {"content_type = 'tool' AND tool_status = 'running'",
       "conversation_entries_running_tool_index"}
    ]

    for {predicate, index} <- plans do
      sql =
        "EXPLAIN QUERY PLAN SELECT DISTINCT conversation_id, run_id " <>
          "FROM conversation_entries WHERE #{predicate}"

      assert {:ok, %{rows: rows}} = Handbean.Repo.query(sql)
      assert Enum.any?(rows, &String.contains?(List.last(&1), index))
    end
  end

  test "creates a verified consistent backup without overwriting a target" do
    root = Path.join(System.tmp_dir!(), "handbean-backup-#{Ecto.UUID.generate()}")
    target = Path.join(root, "snapshot.db")
    on_exit(fn -> File.rm_rf!(root) end)

    result =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Handbean.Repo, fn ->
        Diagnostics.backup(target)
      end)

    assert {:ok, %{verified?: true, schema_version: version}} = result
    assert is_integer(version)
    assert File.regular?(target)
    assert {:error, :already_exists} = Diagnostics.backup(target)
  end
end
