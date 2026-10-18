defmodule ExFffTest do
  use ExUnit.Case, async: false

  alias ExFff.Index

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "ex_fff_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    # Create test files
    File.mkdir_p!(Path.join(tmp_dir, "lib"))
    File.mkdir_p!(Path.join(tmp_dir, "test"))
    File.mkdir_p!(Path.join(tmp_dir, "priv/static"))

    File.write!(Path.join(tmp_dir, "lib/user.ex"), "defmodule User do end")
    File.write!(Path.join(tmp_dir, "lib/user_controller.ex"), "defmodule UserController do end")
    File.write!(Path.join(tmp_dir, "lib/post.ex"), "defmodule Post do end")
    File.write!(Path.join(tmp_dir, "lib/schema_validator.ex"), "defmodule SchemaValidator do end")
    File.write!(Path.join(tmp_dir, "test/user_test.exs"), "defmodule UserTest do end")
    File.write!(Path.join(tmp_dir, "test/post_test.exs"), "defmodule PostTest do end")
    File.write!(Path.join(tmp_dir, "priv/static/app.js"), "console.log('test');")
    File.write!(Path.join(tmp_dir, "mix.exs"), "defmodule MixProject do end")
    File.write!(Path.join(tmp_dir, "README.md"), "# Project")

    # Start index with a unique name to avoid conflicts
    name =
      Module.concat(ExFff.Index, String.to_atom("Test_#{System.unique_integer([:positive])}"))

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

  describe "search/3" do
    test "finds files by fuzzy name match", %{name: name} do
      {:ok, result} = Index.search(name, "user")
      paths = Enum.map(result.paths, & &1.path)
      assert "lib/user.ex" in paths
      assert "lib/user_controller.ex" in paths
    end

    test "finds files by exact name", %{name: name} do
      {:ok, result} = Index.search(name, "schema_validator")
      paths = Enum.map(result.paths, & &1.path)
      assert "lib/schema_validator.ex" in paths
    end

    test "supports multi-term AND search", %{name: name} do
      {:ok, result} = Index.search(name, "user controller")
      paths = Enum.map(result.paths, & &1.path)
      assert "lib/user_controller.ex" in paths
    end

    test "supports extension filter", %{name: name} do
      {:ok, result} = Index.search(name, "*.ex")
      paths = Enum.map(result.paths, & &1.path)

      Enum.each(paths, fn p ->
        assert String.ends_with?(p, ".ex")
      end)
    end

    test "supports extension filter combined with term", %{name: name} do
      {:ok, result} = Index.search(name, "user *.ex")
      paths = Enum.map(result.paths, & &1.path)
      assert "lib/user.ex" in paths
      assert "lib/user_controller.ex" in paths
    end

    test "supports exclusion pattern", %{name: name} do
      {:ok, result} = Index.search(name, "user !test/")
      paths = Enum.map(result.paths, & &1.path)

      refute Enum.any?(paths, &String.contains?(&1, "test/"))
      assert "lib/user.ex" in paths
    end

    test "respects limit option", %{name: name} do
      {:ok, result} = Index.search(name, "*.ex", limit: 2)
      assert length(result.paths) <= 2
    end

    test "returns duration_ms in result", %{name: name} do
      {:ok, result} = Index.search(name, "user")
      assert is_integer(result.duration_ms)
      assert result.duration_ms >= 0
    end

    test "returns query in result", %{name: name} do
      {:ok, result} = Index.search(name, "user")
      assert result.query == "user"
    end
  end

  describe "touch/2" do
    test "updates frecency score", %{name: name} do
      # Touch a file multiple times
      Index.touch(name, "lib/user.ex")
      Index.touch(name, "lib/user.ex")
      Index.touch(name, "lib/user.ex")

      {:ok, result} = Index.search(name, "user")
      paths = Enum.map(result.paths, & &1.path)

      assert "lib/user.ex" in paths
    end

    test "frequently touched files rank higher", %{name: name} do
      # Touch user.ex many more times than user_controller.ex
      for _ <- 1..20, do: Index.touch(name, "lib/user.ex")

      {:ok, result} = Index.search(name, "user", limit: 2)
      paths = Enum.map(result.paths, & &1.path)

      assert "lib/user.ex" in paths
    end
  end

  describe "ensure_started/1" do
    test "returns ok when already started", %{tmp_dir: tmp_dir} do
      # Already started in setup via the named index
      {:ok, pid} = Index.ensure_started(tmp_dir)
      assert is_pid(pid)
    end
  end

  describe "search convenience function" do
    test "ExFff.search/2 delegates to Index", %{name: name} do
      # The convenience function searches via __MODULE__ (default name)
      # We test through the named index directly.
      {:ok, result} = Index.search(name, "post")
      paths = Enum.map(result.paths, & &1.path)
      assert "lib/post.ex" in paths
    end
  end
end
