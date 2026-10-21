defmodule Handbean.RepoTest do
  use Handbean.DataCase, async: false

  setup do
    previous = Application.get_env(:handbean, :host)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:handbean, :host, previous),
        else: Application.delete_env(:handbean, :host)
    end)

    :ok
  end

  test "uses WAL with NORMAL sync and a bounded local contention wait" do
    assert {:ok, config} =
             Handbean.Repo.init(:runtime, database: "/tmp/handbean_dev.db", pool_size: 1)

    assert config[:journal_mode] == :wal
    # NORMAL: commits survive process crashes; only a power loss can lose the
    # newest frames, bounded by the turn/run boundary WAL checkpoints.
    assert config[:synchronous] == :normal
    assert config[:busy_timeout] == 5_000
    assert config[:foreign_keys] == :on
  end

  test "respects an explicit synchronous override from config" do
    assert {:ok, config} =
             Handbean.Repo.init(:runtime,
               database: "/tmp/handbean_dev.db",
               pool_size: 1,
               synchronous: :full
             )

    assert config[:synchronous] == :full
  end

  test "applies NORMAL sync on live connections so stream flushes do not fsync every batch" do
    # SQLite synchronous pragma: 0=OFF, 1=NORMAL, 2=FULL, 3=EXTRA.
    assert {:ok, %{rows: [[1]]}} = Handbean.Repo.query("PRAGMA synchronous")
  end

  test "checkpoint_wal runs a best-effort FULL checkpoint outside a transaction" do
    # wal_checkpoint cannot run inside the sandbox transaction, so use a real
    # unboxed connection like the diagnostics backup test does.
    assert :ok =
             Ecto.Adapters.SQL.Sandbox.unboxed_run(Handbean.Repo, fn ->
               Handbean.Repo.checkpoint_wal()
             end)

    assert :ok =
             Ecto.Adapters.SQL.Sandbox.unboxed_run(Handbean.Repo, fn ->
               Handbean.Repo.checkpoint_wal()
             end)
  end

  test "keeps an explicit database when the host also sets data_dir" do
    Handbean.Host.put!(%{data_dir: "/tmp/handbean-dev-data"})

    assert {:ok, config} =
             Handbean.Repo.init(:runtime, database: "/tmp/handbean_dev.db", pool_size: 1)

    assert config[:database] == "/tmp/handbean_dev.db"
  end

  test "places handbean.db beside data_dir when the host omits the database" do
    Handbean.Host.put!(%{data_dir: "/tmp/handbean-packaged"})

    assert {:ok, config} = Handbean.Repo.init(:runtime, pool_size: 1)
    assert config[:database] == "/tmp/handbean-packaged/handbean.db"
  end

  test "leaves the configured database alone when no host data_dir is set" do
    Application.delete_env(:handbean, :host)

    assert {:ok, config} =
             Handbean.Repo.init(:runtime, database: "handbean_test.db", pool_size: 1)

    assert config[:database] == "handbean_test.db"
  end
end
