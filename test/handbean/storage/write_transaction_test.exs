defmodule Handbean.Storage.WriteTransactionTest do
  use ExUnit.Case, async: false

  alias Handbean.Agent.OperationReceipt
  alias Handbean.ConversationTranscriptStore.ConversationStore, as: Transcript
  alias Handbean.Repo
  alias Handbean.Storage.WriteTransaction

  setup do
    directory =
      Path.join(System.tmp_dir!(), "write-transaction-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    database = Path.join(directory, "test.db")

    schema =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Repo.query!(
          "SELECT sql FROM sqlite_master WHERE type IN ('table', 'index') AND sql IS NOT NULL AND tbl_name IN ('conversations', 'conversation_entries', 'operation_receipts', 'conversation_editor_states') ORDER BY type DESC"
        ).rows
      end)

    {:ok, repo} =
      Repo.start_link(
        name: nil,
        database: database,
        pool: DBConnection.ConnectionPool,
        pool_size: 1,
        busy_timeout: 20
      )

    Process.unlink(repo)
    previous = Repo.put_dynamic_repo(repo)
    Enum.each(schema, fn [sql] -> Repo.query!(sql) end)
    {:ok, writer} = Exqlite.Sqlite3.open(database)

    on_exit(fn ->
      Repo.put_dynamic_repo(previous)
      Exqlite.Sqlite3.close(writer)
      if Process.alive?(repo), do: GenServer.stop(repo)
      File.rm_rf!(directory)
    end)

    %{writer: writer}
  end

  test "WAL deferred read cannot upgrade after another writer commits", %{writer: writer} do
    Repo.query!("CREATE TABLE contention_probe (value INTEGER)")
    Repo.query!("INSERT INTO contention_probe VALUES (0)")

    assert_raise Exqlite.Error, fn ->
      Repo.transaction(fn ->
        Repo.query!("SELECT * FROM contention_probe")
        assert :ok = Exqlite.Sqlite3.execute(writer, "UPDATE contention_probe SET value = 1")
        Repo.query!("UPDATE contention_probe SET value = 2")
      end)
    end

    assert %{rows: [[1]]} = Repo.query!("SELECT * FROM contention_probe")
  end

  test "consume retries a failed writer acquisition and allocates each sequence once", %{
    writer: writer
  } do
    {:ok, conversation} = Handbean.ConversationStore.create_free()
    id = conversation["id"]
    assert {:ok, _} = Transcript.append(id, %{"id" => "a", "content" => "first"}, [])
    assert {:ok, _} = Transcript.append(id, %{"id" => "b", "content" => "second"}, [])
    release_after_busy(writer)

    assert :ok = Transcript.consume(id, ["a", "b"], %{"status" => "consumed"}, [])
    assert_received :busy_observed
    assert {:ok, entries} = Transcript.list(id, [])

    assert Enum.map(entries, &{&1["sequence"], &1["revision"], &1["status"]}) ==
             [{3, 2, "consumed"}, {4, 2, "consumed"}]

    assert {:ok, %{"sequence" => 5}} = Transcript.append(id, %{"id" => "c"}, [])
  end

  test "receipt reservation recovers after an actual busy failure without duplicate acceptance",
       %{writer: writer} do
    scope = {:message, "isolated"}
    release_after_busy(writer)
    assert :ok = OperationReceipt.reserve(scope, "request", "fingerprint")
    assert_received :busy_observed

    assert {:unknown, :delivery_unknown} =
             OperationReceipt.reserve(scope, "request", "fingerprint")

    assert %{rows: [[1]]} = Repo.query!("SELECT count(*) FROM operation_receipts")
  end

  test "exhausted contention returns the database error and writes nothing", %{writer: writer} do
    {:ok, conversation} = Handbean.ConversationStore.create_free()
    id = conversation["id"]
    assert :ok = Exqlite.Sqlite3.execute(writer, "BEGIN IMMEDIATE")
    assert {:error, %Exqlite.Error{}} = Transcript.append(id, %{"id" => "blocked"}, [])
    assert {:error, %Exqlite.Error{}} = OperationReceipt.reserve({:message, id}, "blocked", "fp")
    assert :ok = Exqlite.Sqlite3.execute(writer, "COMMIT")
    assert {:ok, []} = Transcript.list(id, [])
    assert :error = OperationReceipt.lookup({:message, id}, "blocked")
    assert {:ok, %{"sequence" => 1}} = Transcript.append(id, %{"id" => "success"}, [])
  end

  test "busy rollback, exception and nested rollback replay the complete transaction" do
    Repo.query!("CREATE TABLE contention_probe (value INTEGER)")
    test_process = self()

    for failure <- [:rollback, :raise, :nested] do
      Repo.query!("DELETE FROM contention_probe")

      assert {:ok, :done} =
               WriteTransaction.run(fn ->
                 Repo.query!("INSERT INTO contention_probe VALUES (1)")

                 receive do
                   :retry -> :done
                 after
                   0 ->
                     send(test_process, :retry)
                     error = %Exqlite.Error{message: "Database busy"}

                     case failure do
                       :rollback -> Repo.rollback(error)
                       :raise -> raise error
                       :nested -> WriteTransaction.run(fn -> Repo.rollback(error) end)
                     end
                 end
               end)

      assert %{rows: [[1]]} = Repo.query!("SELECT count(*) FROM contention_probe")
    end
  end

  test "entry and receipt are rolled back together before a busy completion is retried" do
    {:ok, conversation} = Handbean.ConversationStore.create_free()
    id = conversation["id"]
    scope = {:message, id}
    assert :ok = OperationReceipt.reserve(scope, "atomic", "fp")
    owner = self()

    Application.put_env(:handbean, :operation_receipt_write_fault, fn ->
      receive do
        :completion_retry -> :ok
      after
        0 ->
          send(owner, :completion_retry)
          {:error, %Exqlite.Error{message: "Database busy"}}
      end
    end)

    on_exit(fn -> Application.delete_env(:handbean, :operation_receipt_write_fault) end)

    assert {:ok, %{"sequence" => 1}} =
             Transcript.append_with_receipt(
               id,
               %{"id" => "inbound"},
               "atomic",
               %{"accepted" => true},
               []
             )

    assert {:ok, [%{"id" => "inbound", "sequence" => 1}]} = Transcript.list(id, [])

    assert {:ok, %{"status" => "completed", "receipt" => %{"accepted" => true}}} =
             OperationReceipt.lookup(scope, "atomic")

    assert {:ok, %{"sequence" => 2}} = Transcript.append(id, %{"id" => "next"}, [])
  end

  test "driver busy variants share classification and preserve bounded retry" do
    owner = self()

    for message <- [
          "Database busy",
          "Database is busy",
          "database is locked",
          "DATABASE IS LOCKED",
          "SQLITE_BUSY",
          "SQLITE_BUSY_SNAPSHOT",
          "SQLITE_LOCKED"
        ],
        failure <- [:raise, :nested_rollback] do
      error = %Exqlite.Error{message: message}

      assert {:error, ^error} =
               WriteTransaction.run(fn ->
                 send(owner, :attempted)

                 case failure do
                   :raise -> raise error
                   :nested_rollback -> WriteTransaction.run(fn -> Repo.rollback(error) end)
                 end
               end)

      assert_received :attempted
      assert_received :attempted
      assert_received :attempted
      refute_received :attempted
    end
  end

  test "busy words in application errors or SQL statements do not permit retry" do
    owner = self()
    error = %Exqlite.Error{message: "syntax error", statement: "SELECT 'SQLITE_BUSY'"}

    assert_raise Exqlite.Error, fn ->
      WriteTransaction.run(fn ->
        send(owner, :attempted)
        raise error
      end)
    end

    assert_received :attempted
    refute_received :attempted

    assert_raise RuntimeError, "Database busy", fn ->
      WriteTransaction.run(fn ->
        send(owner, :attempted)
        raise "Database busy"
      end)
    end

    assert_received :attempted
    refute_received :attempted

    for reason <- [
          %RuntimeError{message: "SQLITE_LOCKED"},
          %Exqlite.Error{message: nil, statement: "SELECT 'SQLITE_BUSY'"}
        ] do
      assert {:error, ^reason} =
               WriteTransaction.run(fn ->
                 send(owner, :attempted)
                 Repo.rollback(reason)
               end)

      assert_received :attempted
      refute_received :attempted
    end
  end

  test "non-busy exceptions and domain rollbacks are never retried" do
    owner = self()

    assert_raise Exqlite.Error, "broken database", fn ->
      WriteTransaction.run(fn ->
        send(owner, :called)
        raise Exqlite.Error, message: "broken database"
      end)
    end

    assert_received :called
    refute_received :called

    assert {:error, :domain_failure} =
             WriteTransaction.run(fn ->
               send(owner, :called)
               Repo.rollback(:domain_failure)
             end)

    assert_received :called
    refute_received :called
  end

  test "persistent writer contention has three attempts and never enters the callback", %{
    writer: writer
  } do
    assert :ok = Exqlite.Sqlite3.execute(writer, "BEGIN IMMEDIATE")
    handler = "count-busy-#{System.unique_integer([:positive])}"
    :ok = :telemetry.attach(handler, [:handbean, :repo, :query], &__MODULE__.count_busy/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)
    owner = self()
    assert {:error, %Exqlite.Error{}} = WriteTransaction.run(fn -> send(owner, :called) end)
    assert_received :busy_attempt
    assert_received :busy_attempt
    assert_received :busy_attempt
    refute_received :busy_attempt
    refute_received :called
    assert :ok = Exqlite.Sqlite3.execute(writer, "COMMIT")
  end

  test "nested transactions propagate busy without locally replaying the callback" do
    test_process = self()

    assert_raise Exqlite.Error, fn ->
      Repo.transaction(fn ->
        WriteTransaction.run(fn ->
          send(test_process, :called)
          raise Exqlite.Error, message: "Database busy"
        end)
      end)
    end

    assert_received :called
    refute_received :called
  end

  defp release_after_busy(writer) do
    assert :ok = Exqlite.Sqlite3.execute(writer, "BEGIN IMMEDIATE")
    handler = "busy-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(handler, [:handbean, :repo, :query], &__MODULE__.release_writer/4, %{
        owner: self(),
        writer: writer,
        handler: handler
      })

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  def release_writer(
        _event,
        _measurements,
        %{
          result:
            {:error, %Exqlite.Error{message: message, statement: "BEGIN IMMEDIATE TRANSACTION"}}
        },
        config
      )
      when message in ["database is locked", "Database busy", "Database is busy"] do
    if self() == config.owner do
      :telemetry.detach(config.handler)
      :ok = Exqlite.Sqlite3.execute(config.writer, "COMMIT")
      send(config.owner, :busy_observed)
    end
  end

  def release_writer(_event, _measurements, _metadata, _config), do: :ok

  def count_busy(
        _event,
        _measurements,
        %{
          result:
            {:error, %Exqlite.Error{message: message, statement: "BEGIN IMMEDIATE TRANSACTION"}}
        },
        owner
      )
      when message in ["database is locked", "Database busy", "Database is busy"] do
    if self() == owner, do: send(owner, :busy_attempt)
  end

  def count_busy(_event, _measurements, _metadata, _owner), do: :ok
end
