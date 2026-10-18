defmodule Handbean.StorageLockTest do
  use ExUnit.Case, async: false

  alias Handbean.StorageLock

  setup do
    root =
      System.tmp_dir!()
      |> StorageLock.canonical_path()
      |> Path.join("handbean-db-lock-#{Ecto.UUID.generate()}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "holds one lock per resolved database path and releases it on shutdown", %{root: root} do
    database = Path.join(root, "handbean.db")
    lock_path = StorageLock.lock_path(database)
    assert {:ok, pid} = StorageLock.start_link(database: database, name: nil)
    assert {:error, :locked} = :handbean_storage.lock(lock_path)

    GenServer.stop(pid)

    assert {:ok, resource} = :handbean_storage.lock(lock_path)
    assert :ok = :handbean_storage.close(resource)
  end

  test "databases in the same directory have independent ownership", %{root: root} do
    first = Path.join(root, "handbean.db")
    second = Path.join(root, "app.db")
    assert {:ok, first_owner} = StorageLock.start_link(database: first, name: nil)
    assert {:ok, second_owner} = StorageLock.start_link(database: second, name: nil)
    assert StorageLock.lock_path(first) != StorageLock.lock_path(second)
    GenServer.stop(first_owner)
    GenServer.stop(second_owner)
  end

  test "final database symlink chains share ownership with their target", %{root: root} do
    target = Path.join(root, "handbean.db")
    intermediate_alias = Path.join(root, "handbean-intermediate.db")
    alias_path = Path.join(root, "handbean-alias.db")
    File.write!(target, "")
    File.ln_s!(Path.basename(target), intermediate_alias)
    File.ln_s!(Path.basename(intermediate_alias), alias_path)

    assert StorageLock.lock_path(alias_path) == StorageLock.lock_path(target)
    assert StorageLock.lock_path(intermediate_alias) == StorageLock.lock_path(target)
    assert {:ok, owner} = StorageLock.start_link(database: target, name: nil)

    previous_flag = Process.flag(:trap_exit, true)
    assert {:error, :database_locked} = StorageLock.start_link(database: alias_path, name: nil)
    Process.flag(:trap_exit, previous_flag)

    GenServer.stop(owner)
  end

  test "ancestor directory symlinks share ownership with the physical database path", %{
    root: root
  } do
    physical_dir = Path.join(root, "physical")
    alias_dir = Path.join(root, "alias")
    File.mkdir_p!(physical_dir)
    File.ln_s!(Path.basename(physical_dir), alias_dir)

    target = Path.join(physical_dir, "handbean.db")
    aliased = Path.join(alias_dir, "handbean.db")
    File.write!(target, "")

    assert StorageLock.lock_path(aliased) == StorageLock.lock_path(target)
    assert {:ok, owner} = StorageLock.start_link(database: target, name: nil)

    previous_flag = Process.flag(:trap_exit, true)
    assert {:error, :database_locked} = StorageLock.start_link(database: aliased, name: nil)
    Process.flag(:trap_exit, previous_flag)

    GenServer.stop(owner)
  end

  test "canonical path spends one total symlink budget across ancestor and final links", %{
    root: root
  } do
    physical_dir = Path.join(root, "physical")
    File.mkdir_p!(physical_dir)

    ancestor_links = for index <- 0..24, do: Path.join(root, "ancestor-#{index}")

    ancestor_links
    |> Enum.with_index()
    |> Enum.each(fn {link, index} ->
      target = Enum.at(ancestor_links, index + 1) || physical_dir
      File.ln_s!(Path.basename(target), link)
    end)

    final_links = for index <- 0..19, do: Path.join(physical_dir, "database-#{index}")
    database = Path.join(physical_dir, "handbean.db")
    File.write!(database, "")

    final_links
    |> Enum.with_index()
    |> Enum.each(fn {link, index} ->
      target = Enum.at(final_links, index + 1) || database
      File.ln_s!(Path.basename(target), link)
    end)

    aliased = Path.join(hd(ancestor_links), Path.basename(hd(final_links)))

    assert StorageLock.canonical_path(aliased) == Enum.at(final_links, 15)
  end

  test "canonical path stops at the symlink limit when links form a loop", %{root: root} do
    first = Path.join(root, "loop-a")
    second = Path.join(root, "loop-b")
    File.ln_s!(Path.basename(second), first)
    File.ln_s!(Path.basename(first), second)

    assert StorageLock.canonical_path(first) == Path.expand(first)
  end

  test "a second runtime gets a stable startup error", %{root: root} do
    database = Path.join(root, "handbean.db")
    assert {:ok, owner} = StorageLock.start_link(database: database, name: nil)
    previous_flag = Process.flag(:trap_exit, true)
    assert {:error, :database_locked} = StorageLock.start_link(database: database, name: nil)
    Process.flag(:trap_exit, previous_flag)
    GenServer.stop(owner)
  end
end
