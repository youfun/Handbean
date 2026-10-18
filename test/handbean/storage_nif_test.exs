defmodule Handbean.StorageNifTest do
  use ExUnit.Case, async: true

  defp paths(context) do
    root = Path.join(System.tmp_dir!(), "handbean-storage-#{context.test}")
    File.rm_rf!(root)
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {Path.join(root, "owner.lock"), Path.join(root, "journal")}
  end

  test "lock is exclusive, close releases it, and a closed resource cannot write", context do
    {lock_path, journal_path} = paths(context)
    assert {:ok, lock} = :handbean_storage.lock(lock_path)
    assert {:error, :locked} = :handbean_storage.lock(lock_path)
    assert :ok = :handbean_storage.close(lock)
    assert {:error, :closed} = :handbean_storage.append_sync(lock, journal_path, 0, "no")
    assert {:ok, replacement} = :handbean_storage.lock(lock_path)
    assert :ok = :handbean_storage.close(replacement)
  end

  test "resource destruction after owner death releases the OS lock", context do
    {lock_path, _journal_path} = paths(context)
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        {:ok, lock} = :handbean_storage.lock(lock_path)
        send(parent, :locked)

        receive do
          :stop -> :handbean_storage.close(lock)
        end
      end)

    assert_receive :locked
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    assert {:ok, lock} = :handbean_storage.lock(lock_path)
    assert :ok = :handbean_storage.close(lock)
  end

  test "lock is exclusive across BEAM instances and process exit releases it", context do
    {lock_path, _journal_path} = paths(context)
    ebin = Application.app_dir(:handbean, "ebin")

    script =
      "{:ok, lock} = :handbean_storage.lock(#{inspect(lock_path)}); " <>
        "Process.put(:lock, lock); IO.puts(\"locked\"); IO.gets(\"\")"

    port =
      Port.open({:spawn_executable, System.find_executable("elixir")}, [
        :binary,
        :exit_status,
        :use_stdio,
        args: ["--erl", "+S 1", "-pa", ebin, "-e", script]
      ])

    assert_receive {^port, {:data, "locked\n"}}, 5_000
    assert {:error, :locked} = :handbean_storage.lock(lock_path)
    Port.command(port, "exit\n")
    assert_receive {^port, {:exit_status, 0}}, 5_000
    assert {:ok, lock} = :handbean_storage.lock(lock_path)
    assert :ok = :handbean_storage.close(lock)
  end

  test "path aliases for the same inode contend", context do
    {lock_path, _journal_path} = paths(context)
    alias_path = lock_path <> ".alias"
    File.rm(alias_path)
    File.touch!(lock_path)
    File.ln!(lock_path, alias_path)

    assert {:ok, lock} = :handbean_storage.lock(lock_path)
    assert {:error, :locked} = :handbean_storage.lock(alias_path)
    assert :ok = :handbean_storage.close(lock)
  end

  test "locked synchronous mutations truncate, replace, and remove", context do
    {lock_path, journal_path} = paths(context)
    {:ok, lock} = :handbean_storage.lock(lock_path)

    File.write!(journal_path, "old-tail")
    assert :ok = :handbean_storage.append_sync(lock, journal_path, 3, "NEW")
    assert File.read!(journal_path) == "oldNEW"

    assert :ok = :handbean_storage.replace_sync(lock, journal_path, "replacement")
    assert File.read!(journal_path) == "replacement"
    assert [] = Path.wildcard(journal_path <> ".tmp.*")

    assert :ok = :handbean_storage.remove_sync(lock, journal_path)
    refute File.exists?(journal_path)
    assert {:error, :enoent} = :handbean_storage.remove_sync(lock, journal_path)
  end

  test "invalid paths are rejected without truncating existing data", context do
    {lock_path, journal_path} = paths(context)
    {:ok, lock} = :handbean_storage.lock(lock_path)
    File.write!(journal_path, "intact")

    assert_raise ArgumentError, fn ->
      :handbean_storage.append_sync(lock, journal_path <> <<0>>, 0, "bad")
    end

    assert File.read!(journal_path) == "intact"

    assert_raise ArgumentError, fn ->
      :handbean_storage.append_sync(lock, journal_path, 0x7FFF_FFFF_FFFF_FFFF, "x")
    end

    assert File.read!(journal_path) == "intact"
  end
end
