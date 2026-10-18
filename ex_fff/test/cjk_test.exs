defmodule ExFff.CjkTest do
  @moduledoc """
  Regression tests for CJK / non-ASCII / invalid UTF-8 paths.

  Background: the original byte-based trigram implementation produced
  invalid UTF-8 binaries for multi-byte characters (CJK each takes 3
  bytes in UTF-8). When such binaries were later passed to `String.*`
  functions (e.g. `String.downcase`, `String.jaro_distance`), they
  could raise `ArgumentError` and crash the indexer GenServer.

  These tests pin down the expected behaviour after the fix:

    * `tokenize/1` MUST slide trigrams over graphemes, not bytes.
    * `tokenize/1` MUST NOT raise on invalid UTF-8 binaries.
    * Indexer MUST NOT crash when encountering CJK file names.
    * Searching by CJK substring MUST find CJK files.
  """
  use ExUnit.Case, async: false

  alias ExFff.{Index, Matcher}

  describe "tokenize/1 with CJK characters" do
    test "produces grapheme-based trigrams for pure CJK token" do
      # 4 graphemes ⇒ 2 trigrams of 3 graphemes each
      tokens = Matcher.tokenize("测试用户")
      assert "测试用" in tokens
      assert "试用户" in tokens
    end

    test "all trigrams are valid UTF-8 for CJK input" do
      tokens = Matcher.tokenize("用户控制器模块")

      Enum.each(tokens, fn t ->
        assert String.valid?(t), "trigram #{inspect(t)} is not valid UTF-8"
      end)

      # 7 graphemes ⇒ 5 trigrams expected
      assert length(tokens) == 5
    end

    test "mixed CJK + ASCII path tokenises both sides" do
      tokens = Matcher.tokenize("lib/用户_controller.ex")
      assert "lib" in tokens
      assert "con" in tokens
      assert "用户" not in tokens, "tokens shorter than 3 graphemes must be dropped"
      Enum.each(tokens, fn t -> assert String.valid?(t) end)
    end

    test "CJK token shorter than 3 graphemes yields no trigrams" do
      assert Matcher.tokenize("中文") == []
      assert Matcher.tokenize("中") == []
    end

    test "longer CJK token yields a sliding window over graphemes" do
      tokens = Matcher.tokenize("用户控制器")
      assert "用户控" in tokens
      assert "户控制" in tokens
      assert "控制器" in tokens
      assert length(tokens) == 3
    end
  end

  describe "split_camel_case/1 with CJK" do
    test "leaves a pure CJK token intact (lowercased identity)" do
      assert Matcher.split_camel_case("测试用户") == ["测试用户"]
    end

    test "downcase ASCII suffix but keep CJK unchanged" do
      assert Matcher.split_camel_case("用户Controller") == ["用户controller"]
    end
  end

  describe "tokenize/1 robustness against invalid UTF-8" do
    test "does not raise on invalid UTF-8 binary" do
      bad = <<0xFF, 0xFE, "abc">>
      assert Matcher.tokenize(bad) == []
    end
  end

  describe "Index with CJK file names" do
    setup do
      tmp_dir =
        Path.join(System.tmp_dir!(), "ex_fff_cjk_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      File.mkdir_p!(Path.join(tmp_dir, "lib"))

      File.write!(Path.join(tmp_dir, "lib/用户控制器.ex"), "defmodule X do end")
      File.write!(Path.join(tmp_dir, "lib/订单服务.ex"), "defmodule Y do end")
      File.write!(Path.join(tmp_dir, "lib/normal.ex"), "defmodule N do end")

      name =
        Module.concat(
          ExFff.CjkTest,
          String.to_atom("Idx_#{System.unique_integer([:positive])}")
        )

      {:ok, pid} = Index.start_link(root_path: tmp_dir, name: name, max_files: 100)
      Process.sleep(100)

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

      {:ok, name: name, pid: pid, tmp_dir: tmp_dir}
    end

    test "indexer survives CJK file names", %{name: name, pid: pid} do
      assert Process.alive?(pid)
      # Still able to serve a plain ASCII query.
      {:ok, result} = Index.search(name, "normal")
      paths = Enum.map(result.paths, & &1.path)
      assert "lib/normal.ex" in paths
    end

    test "finds CJK file by 3-character CJK substring", %{name: name} do
      {:ok, result} = Index.search(name, "用户控")
      paths = Enum.map(result.paths, & &1.path)
      assert Enum.any?(paths, &String.contains?(&1, "用户控制器"))
    end

    test "finds CJK file by 4-character CJK substring", %{name: name} do
      {:ok, result} = Index.search(name, "用户控制")
      paths = Enum.map(result.paths, & &1.path)
      assert Enum.any?(paths, &String.contains?(&1, "用户控制器"))
    end

    test "finds another CJK file by exact CJK token", %{name: name} do
      {:ok, result} = Index.search(name, "订单服")
      paths = Enum.map(result.paths, & &1.path)
      assert Enum.any?(paths, &String.contains?(&1, "订单服务"))
    end
  end
end
