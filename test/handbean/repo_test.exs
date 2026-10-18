defmodule Handbean.RepoTest do
  use ExUnit.Case, async: false

  setup do
    previous = Application.get_env(:handbean, :host)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:handbean, :host, previous),
        else: Application.delete_env(:handbean, :host)
    end)

    :ok
  end

  test "uses WAL durability settings with a bounded local contention wait" do
    assert {:ok, config} =
             Handbean.Repo.init(:runtime, database: "/tmp/handbean_dev.db", pool_size: 1)

    assert config[:journal_mode] == :wal
    assert config[:synchronous] == :full
    assert config[:busy_timeout] == 5_000
    assert config[:foreign_keys] == :on
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
