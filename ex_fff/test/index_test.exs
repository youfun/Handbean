defmodule ExFff.IndexTest do
  use ExUnit.Case, async: false

  alias ExFff.Index

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "ex_fff_idx_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    File.mkdir_p!(Path.join(tmp_dir, "lib"))
    File.mkdir_p!(Path.join(tmp_dir, "test"))

    File.write!(Path.join(tmp_dir, "lib/app.ex"), "module")
    File.write!(Path.join(tmp_dir, "lib/app_test.exs"), "module test")
    File.write!(Path.join(tmp_dir, "test/app_test.exs"), "module test")
    File.write!(Path.join(tmp_dir, "mix.exs"), "mix")
    File.write!(Path.join(tmp_dir, "config.exs"), "config")

    name = Module.concat(ExFff.Index, String.to_atom("Idx_#{System.unique_integer([:positive])}"))
    {:ok, pid} = Index.start_link(root_path: tmp_dir, name: name, max_files: 100)
    assert :ok = Index.await_index(name)

    on_exit(fn ->
      if Process.alive?(pid) do
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end

      File.rm_rf(tmp_dir)
    end)

    {:ok, pid: pid, name: name, tmp_dir: tmp_dir}
  end

  describe "start_link/1" do
    test "starts successfully with a valid root_path", %{pid: pid} do
      assert Process.alive?(pid)
    end

    test "rejects non-existent root_path" do
      name =
        Module.concat(ExFff.Index, String.to_atom("Nope_#{System.unique_integer([:positive])}"))

      Process.flag(:trap_exit, true)

      assert {:error, "root_path is not a directory: /nonexistent/path/xyz"} =
               Index.start_link(root_path: "/nonexistent/path/xyz", name: name)
    end
  end

  describe "search/3" do
    test "returns results with paths and scores", %{name: name} do
      {:ok, result} = Index.search(name, "app")
      paths = Enum.map(result.paths, & &1.path)
      assert "lib/app.ex" in paths
      assert result.status == :ready
      assert Enum.all?(result.paths, &is_float(&1.score))
    end

    test "empty query returns files", %{name: name} do
      {:ok, result} = Index.search(name, "*.ex")
      paths = Enum.map(result.paths, & &1.path)
      assert "lib/app.ex" in paths
    end

    test "returns currently indexed paths without waiting for the scan", %{pid: pid, name: name} do
      generation = :sys.get_state(pid).generation
      path = "lib/partial_result.ex"

      trigrams =
        path
        |> String.downcase()
        |> ExFff.Matcher.tokenize()
        |> Enum.map(&{&1, path})

      :sys.replace_state(pid, &%{&1 | status: :indexing, indexed_count: 0})

      send(
        pid,
        {:index_batch, generation, [{path, %{mtime: {{2026, 1, 1}, {0, 0, 0}}, size: 1}}],
         trigrams}
      )

      started_at = System.monotonic_time(:millisecond)
      assert {:ok, result} = Index.search(name, "partial")
      elapsed = System.monotonic_time(:millisecond) - started_at

      assert elapsed < 100
      assert result.status == :indexing
      assert result.indexed_count >= 1
      assert Enum.any?(result.paths, &(&1.path == path))
    end

    test "a bounded await returns partial results when the scan outlasts it", %{
      pid: pid,
      name: name
    } do
      :sys.replace_state(pid, &%{&1 | status: :indexing})

      assert {:ok, result} = Index.search(name, "app", await: 50, timeout: 1_000)
      assert result.status == :indexing
      assert Enum.any?(result.paths, &(&1.path == "lib/app.ex"))
      assert :sys.get_state(pid).pending_searches == []
    end
  end

  describe "touch/2" do
    test "touch updates frecency and affects ranking", %{name: name} do
      # Touch app.ex many times
      for _ <- 1..30, do: Index.touch(name, "lib/app.ex")

      {:ok, result} = Index.search(name, "app", limit: 3)
      paths = Enum.map(result.paths, & &1.path)

      assert "lib/app.ex" in paths
      # Should be ranked first due to high frecency
      assert hd(paths) == "lib/app.ex"
    end

    test "touch on non-existent path does not crash", %{name: name} do
      assert :ok = Index.touch(name, "nonexistent/path.ex")
      {:ok, result} = Index.search(name, "app")
      assert "lib/app.ex" in Enum.map(result.paths, & &1.path)
    end

    test "legacy unbounded frecency files still boost within a tier", %{tmp_dir: tmp_dir} do
      frecency_dir = Path.join(tmp_dir, "legacy-frecency")
      File.mkdir_p!(frecency_dir)

      digest =
        :crypto.hash(:sha256, Path.expand(tmp_dir)) |> Base.url_encode64(padding: false)

      File.write!(
        Path.join(frecency_dir, digest <> ".term"),
        :erlang.term_to_binary([{985.0, "lib/app.ex"}])
      )

      name =
        Module.concat(
          ExFff.Index,
          String.to_atom("Legacy_#{System.unique_integer([:positive])}")
        )

      {:ok, pid} =
        Index.start_link(root_path: tmp_dir, name: name, frecency_dir: frecency_dir)

      assert :ok = Index.await_index(name)
      assert {:ok, result} = Index.search(name, "app", limit: 3)
      assert hd(result.paths).path == "lib/app.ex"
      GenServer.stop(pid)
    end

    test "frecency survives an index restart", %{tmp_dir: tmp_dir} do
      frecency_dir = Path.join(tmp_dir, "frecency")

      first =
        Module.concat(
          ExFff.Index,
          String.to_atom("PersistA_#{System.unique_integer([:positive])}")
        )

      second =
        Module.concat(
          ExFff.Index,
          String.to_atom("PersistB_#{System.unique_integer([:positive])}")
        )

      {:ok, first_pid} =
        Index.start_link(root_path: tmp_dir, name: first, frecency_dir: frecency_dir)

      assert :ok = Index.await_index(first)
      Index.touch(first, "lib/app.ex")
      Process.sleep(250)
      GenServer.stop(first_pid)

      {:ok, second_pid} =
        Index.start_link(root_path: tmp_dir, name: second, frecency_dir: frecency_dir)

      assert :ok = Index.await_index(second)
      assert {:ok, result} = Index.search(second, "app", limit: 3)
      assert hd(result.paths).path == "lib/app.ex"
      GenServer.stop(second_pid)
    end
  end

  describe "inventory and incremental updates" do
    test "lists stable cursor pages", %{name: name} do
      assert {:ok, first} = Index.files(name, limit: 2)
      assert length(first.paths) == 2
      assert is_binary(first.cursor)

      assert {:ok, second} = Index.files(name, limit: 20, cursor: first.cursor)
      assert MapSet.disjoint?(MapSet.new(first.paths), MapSet.new(second.paths))
      assert first.paths ++ second.paths == Enum.sort(first.paths ++ second.paths)
    end

    test "adds and removes a changed file without rebuilding", %{name: name, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "lib/incremental.ex")
      File.write!(path, "incremental")
      Index.update_paths(name, [path])

      assert_eventually(fn ->
        {:ok, files} = Index.files(name, limit: 100)
        "lib/incremental.ex" in files.paths
      end)

      File.rm!(path)
      Index.update_paths(name, [path])

      assert_eventually(fn ->
        {:ok, files} = Index.files(name, limit: 100)
        "lib/incremental.ex" not in files.paths
      end)
    end

    test "keeps a newly changed file searchable when the inventory is full", %{tmp_dir: tmp_dir} do
      name =
        Module.concat(
          ExFff.Index,
          String.to_atom("Full_#{System.unique_integer([:positive])}")
        )

      {:ok, pid} = Index.start_link(root_path: tmp_dir, name: name, max_files: 2)
      assert :ok = Index.await_index(name)
      assert {:ok, %{indexed_count: 2}} = Index.files(name, limit: 10)

      path = Path.join(tmp_dir, "newly_changed.ex")
      File.write!(path, "changed at capacity")
      assert :ok = Index.update_paths(name, [path])

      assert_eventually(fn ->
        {:ok, files} = Index.files(name, limit: 10)
        files.indexed_count == 2 and "newly_changed.ex" in files.paths
      end)

      GenServer.stop(pid)
    end

    test "update_paths never waits on index work", %{pid: pid, name: name, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "lib/nonblocking.ex")
      File.write!(path, "nonblocking")
      :sys.suspend(pid)

      try do
        assert :ok = Index.update_paths(name, [path])
      after
        :sys.resume(pid)
      end

      assert_eventually(fn ->
        {:ok, files} = Index.files(name, path: "lib", limit: 100)
        "lib/nonblocking.ex" in files.paths
      end)
    end

    test "Git status boosts and annotates matching files", %{name: name} do
      Index.set_git_status(name, [{"lib/app_test.exs", :modified}])

      assert_eventually(fn ->
        {:ok, result} = Index.search(name, "app", limit: 3)
        hd(result.paths).path == "lib/app_test.exs" and hd(result.paths).git_status == :modified
      end)
    end

    test "incremental updates use the same anchored ignore rules as the full scan", %{
      name: name,
      tmp_dir: tmp_dir
    } do
      path = Path.join([tmp_dir, "lib", "foo_tmp", "kept.ex"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "first")
      Index.refresh(name)
      assert :ok = Index.await_index(name)

      File.write!(path, "second")
      assert :ok = Index.update_paths(name, [path])

      assert_eventually(fn ->
        {:ok, files} = Index.files(name, path: "lib/foo_tmp", limit: 20)
        "lib/foo_tmp/kept.ex" in files.paths
      end)
    end
  end

  describe "refresh/1" do
    test "refresh re-indexes files", %{name: name, tmp_dir: tmp_dir} do
      # Add a new file after initial index
      File.write!(Path.join(tmp_dir, "lib/new_file.ex"), "new")

      Index.refresh(name)
      assert :ok = Index.await_index(name)

      {:ok, result} = Index.search(name, "new")
      paths = Enum.map(result.paths, & &1.path)
      assert "lib/new_file.ex" in paths
    end
  end

  describe "scan limit" do
    test "max_files is a global cap, including a single large directory" do
      dir = Path.join(System.tmp_dir!(), "cap_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "wide"))

      for i <- 1..5 do
        File.write!(Path.join(dir, "wide/#{i}.ex"), "x")
      end

      File.mkdir_p!(Path.join(dir, "later"))
      File.write!(Path.join(dir, "later/extra.ex"), "x")

      config = ExFff.Config.new(root_path: dir, max_files: 3)
      paths = ExFff.Scanner.scan(dir, config)

      assert length(paths) == 3
      refute "later/extra.ex" in paths
      File.rm_rf(dir)
    end
  end

  describe "directory pruning" do
    test "prunes build, _build, deps, node_modules, and .gradle directories" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "ex_fff_prune_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(tmp_dir, "lib"))
      File.mkdir_p!(Path.join(tmp_dir, "build/outputs"))
      File.mkdir_p!(Path.join(tmp_dir, "_build/prod/lib"))
      File.mkdir_p!(Path.join(tmp_dir, "deps/phoenix"))
      File.mkdir_p!(Path.join(tmp_dir, "node_modules/react"))
      File.mkdir_p!(Path.join(tmp_dir, ".gradle/caches"))
      File.mkdir_p!(Path.join(tmp_dir, "mobile/android/app/build/intermediates"))

      File.write!(Path.join(tmp_dir, "lib/main.ex"), "main")
      File.write!(Path.join(tmp_dir, "build/outputs/app.apk"), "apk")
      File.write!(Path.join(tmp_dir, "_build/prod/lib/foo.beam"), "beam")
      File.write!(Path.join(tmp_dir, "deps/phoenix/phoenix.ex"), "phoenix")
      File.write!(Path.join(tmp_dir, "node_modules/react/index.js"), "react")
      File.write!(Path.join(tmp_dir, ".gradle/caches/cache.bin"), "bin")

      File.write!(
        Path.join(tmp_dir, "mobile/android/app/build/intermediates/classes.dex"),
        "dex"
      )

      name =
        Module.concat(ExFff.Index, String.to_atom("Prune_#{System.unique_integer([:positive])}"))

      {:ok, pid} = Index.start_link(root_path: tmp_dir, name: name)
      Index.await_index(pid)

      {:ok, counts} = GenServer.call(pid, :get_counts)
      # Only lib/main.ex should be indexed
      assert counts.files == 1

      {:ok, result} = Index.search(pid, "main")
      assert hd(result.paths).path == "lib/main.ex"

      {:ok, result_apk} = Index.search(pid, "app.apk")
      assert result_apk.paths == []

      {:ok, result_dex} = Index.search(pid, "classes.dex")
      assert result_dex.paths == []

      GenServer.stop(pid)
      File.rm_rf(tmp_dir)
    end

    test "prunes generated dot directories but keeps project configuration" do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "ex_fff_dot_prune_test_#{System.unique_integer([:positive])}"
        )

      ignored = ~w(
        .amp .build .cache .pytest_cache .mypy_cache .ruff_cache .tox .venv
        .next .nuxt .svelte-kit .parcel-cache .turbo .dart_tool
      )

      Enum.each(ignored, fn directory ->
        path = Path.join([tmp_dir, directory, "generated.txt"])
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, "generated")
      end)

      File.mkdir_p!(Path.join(tmp_dir, ".agents"))
      File.mkdir_p!(Path.join(tmp_dir, ".github"))
      File.write!(Path.join(tmp_dir, ".agents/setup"), "project agent setup")
      File.write!(Path.join(tmp_dir, ".github/workflow.yml"), "project workflow")

      config = ExFff.Config.new(root_path: tmp_dir)
      paths = ExFff.Scanner.scan(tmp_dir, config)

      assert ".agents/setup" in paths
      assert ".github/workflow.yml" in paths

      Enum.each(ignored, fn directory ->
        refute Path.join(directory, "generated.txt") in paths
      end)

      File.rm_rf(tmp_dir)
    end

    test "respects nested gitignore rules including double-star patterns" do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "ex_fff_gitignore_test_#{System.unique_integer([:positive])}"
        )

      ignored_dir = Path.join([tmp_dir, "desktop", "Resources", "generated"])
      File.mkdir_p!(ignored_dir)
      File.write!(Path.join([tmp_dir, "desktop", ".gitignore"]), "Resources/generated/**\n")
      File.write!(Path.join(ignored_dir, "bundle.js"), "ignored")
      File.write!(Path.join([tmp_dir, "desktop", "kept.js"]), "kept")

      config = ExFff.Config.new(root_path: tmp_dir)
      paths = ExFff.Scanner.scan(tmp_dir, config)

      assert "desktop/kept.js" in paths
      refute "desktop/Resources/generated/bundle.js" in paths
      File.rm_rf(tmp_dir)
    end
  end

  describe "workspace switching and multi-workspace" do
    test "get_root and set_root update workspace and re-index" do
      dir1 = Path.join(System.tmp_dir!(), "ws_1_#{System.unique_integer([:positive])}")
      dir2 = Path.join(System.tmp_dir!(), "ws_2_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir1)
      File.mkdir_p!(dir2)
      File.write!(Path.join(dir1, "project1_file.ex"), "p1")
      File.write!(Path.join(dir2, "project2_file.ex"), "p2")

      name =
        Module.concat(ExFff.Index, String.to_atom("Ws_#{System.unique_integer([:positive])}"))

      {:ok, pid} = Index.start_link(root_path: dir1, name: name)
      Index.await_index(pid)

      assert {:ok, ^dir1} = Index.get_root(pid)
      {:ok, res1} = Index.search(pid, "project1")
      assert length(res1.paths) == 1

      :ok = Index.set_root(pid, dir2)
      Index.await_index(pid)

      assert {:ok, ^dir2} = Index.get_root(pid)
      {:ok, res2} = Index.search(pid, "project2")
      assert length(res2.paths) == 1
      {:ok, res_old} = Index.search(pid, "project1")
      refute "project1_file.ex" in Enum.map(res_old.paths, & &1.path)

      GenServer.stop(pid)
      File.rm_rf(dir1)
      File.rm_rf(dir2)
    end

    test "ensure_started maintains separate indexes per workspace root" do
      dir_a = Path.join(System.tmp_dir!(), "multi_a_#{System.unique_integer([:positive])}")
      dir_b = Path.join(System.tmp_dir!(), "multi_b_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir_a)
      File.mkdir_p!(dir_b)
      File.write!(Path.join(dir_a, "alpha.ex"), "alpha")
      File.write!(Path.join(dir_b, "beta.ex"), "beta")

      {:ok, pid_a} = Index.ensure_started(dir_a)
      {:ok, pid_b} = Index.ensure_started(dir_b)

      assert pid_a != pid_b
      Index.await_index(pid_a)
      Index.await_index(pid_b)

      {:ok, res_a} = Index.search(pid_a, "alpha")
      assert length(res_a.paths) == 1
      assert hd(res_a.paths).path == "alpha.ex"

      {:ok, res_b} = Index.search(pid_b, "beta")
      assert length(res_b.paths) == 1
      assert hd(res_b.paths).path == "beta.ex"

      # Re-requesting dir_a returns the same pid_a
      assert {:ok, ^pid_a} = Index.ensure_started(dir_a)

      assert [{^pid_a, _}] = Registry.lookup(ExFff.Registry, Path.expand(dir_a))
      assert [{^pid_b, _}] = Registry.lookup(ExFff.Registry, Path.expand(dir_b))
      assert [_ | _] = DynamicSupervisor.which_children(ExFff.IndexSupervisor)

      GenServer.stop(pid_a)
      GenServer.stop(pid_b)
      File.rm_rf(dir_a)
      File.rm_rf(dir_b)
    end

    test "an idle index exits normally so the workspace can be reclaimed" do
      dir = Path.join(System.tmp_dir!(), "idle_idx_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "idle.ex"), "idle")

      name =
        Module.concat(ExFff.Index, String.to_atom("Idle_#{System.unique_integer([:positive])}"))

      {:ok, pid} = Index.start_link(root_path: dir, name: name, idle_timeout_ms: 50)
      Process.unlink(pid)
      assert :ok = Index.await_index(pid)
      ref = Process.monitor(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
      File.rm_rf(dir)
    end

    test "set_root replies to a search that was waiting on the old index" do
      dir1 = Path.join(System.tmp_dir!(), "cancel_1_#{System.unique_integer([:positive])}")
      dir2 = Path.join(System.tmp_dir!(), "cancel_2_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir1)
      File.mkdir_p!(dir2)
      File.write!(Path.join(dir1, "old_file.ex"), "old")
      File.write!(Path.join(dir2, "new_file.ex"), "new")

      name =
        Module.concat(ExFff.Index, String.to_atom("Cancel_#{System.unique_integer([:positive])}"))

      {:ok, pid} = Index.start_link(root_path: dir1, name: name)
      assert :ok = Index.await_index(pid)

      :sys.replace_state(pid, fn state -> %{state | status: :indexing} end)
      task = Task.async(fn -> Index.search(pid, "old", await: true, timeout: 2_000) end)
      Process.sleep(20)
      assert :ok = Index.set_root(pid, dir2)

      assert {:error, "index root changed"} = Task.await(task)
      assert :ok = Index.await_index(pid)
      {:ok, result} = Index.search(pid, "new")
      assert hd(result.paths).path == "new_file.ex"

      GenServer.stop(pid)
      File.rm_rf(dir1)
      File.rm_rf(dir2)
    end

    test "a failed scan stops the transient index and replies to waiters" do
      dir = Path.join(System.tmp_dir!(), "fail_idx_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "visible.ex"), "visible")

      name =
        Module.concat(ExFff.Index, String.to_atom("Fail_#{System.unique_integer([:positive])}"))

      {:ok, pid} = Index.start_link(root_path: dir, name: name)
      Process.unlink(pid)
      assert :ok = Index.await_index(pid)

      ref = Process.monitor(pid)
      task = Task.async(fn -> Index.await_index(pid, 2_000) end)
      :sys.replace_state(pid, fn state -> %{state | status: :indexing} end)
      Process.sleep(20)
      generation = :sys.get_state(pid).generation
      send(pid, {:index_failed, generation, :disk_failed})

      assert {:error, message} = Task.await(task)
      assert message =~ "Indexing failed"
      assert_receive {:DOWN, ^ref, :process, ^pid, {:indexing_failed, :disk_failed}}
      File.rm_rf(dir)
    end
  end

  defp assert_eventually(fun, attempts \\ 50)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")
end
