defmodule ExFff.SearchBudgetTest do
  use ExUnit.Case, async: true

  alias ExFff.Index

  setup do
    root = Path.join(System.tmp_dir!(), "fff-budget-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "target.ex"), "target")
    File.write!(Path.join(root, "abc.ex"), "mixed case")
    index = start_supervised!({Index, root_path: root, name: nil, frecency_dir: root})
    :ok = Index.await_index(index)
    on_exit(fn -> File.rm_rf!(root) end)
    %{index: index, root: root}
  end

  test "queue timeout is an explicit search error and expired work is discarded", %{index: index} do
    :ok = :sys.suspend(index)

    try do
      results =
        1..8
        |> Task.async_stream(fn _ -> Index.search(index, "target", timeout: 10) end,
          max_concurrency: 8
        )
        |> Enum.to_list()

      assert Enum.all?(results, fn {:ok, {:error, message}} -> message =~ "timed out" end)
    after
      :sys.resume(index)
    end

    assert {:ok, %{paths: [%{path: "target.ex"}]}} = Index.search(index, "target")
  end

  test "an expired computation budget never becomes an empty success", %{index: index} do
    expired = System.monotonic_time(:millisecond) - 1
    assert {:error, message} = Index.search(index, "missing", deadline: expired)
    assert message =~ "timed out"
    assert {:error, message} = Index.files(index, deadline: expired)
    assert message =~ "timed out"
  end

  test "three-character camel-case queries retain whole-needle matches", %{index: index} do
    assert {:ok, result} = Index.search(index, "aBc")
    assert Enum.any?(result.paths, &(&1.path == "abc.ex"))
  end

  test "substring candidates preserve combining-mark and ZWJ boundaries", %{
    index: index,
    root: root
  } do
    combining = "abc\u0301.ex"
    emoji = "👨‍👩‍👧‍👦ab.ex"
    for path <- [combining, emoji], do: File.write!(Path.join(root, path), "unicode")
    Index.update_paths(index, [combining, emoji])

    assert {:ok, result} = Index.search(index, "abc")
    assert "abc.ex" in Enum.map(result.paths, & &1.path)
    assert combining in Enum.map(result.paths, & &1.path)
    assert {:ok, result} = Index.search(index, "\u200D👩‍👧‍👦ab")
    assert emoji in Enum.map(result.paths, & &1.path)
  end

  test "an in-flight broad query releases the owner when its budget expires", %{index: index} do
    generation = :sys.get_state(index).generation
    entries = for n <- 1..100_000, do: {"bulk/file_#{n}.ex", %{size: 1}}
    :sys.replace_state(index, &%{&1 | status: :indexing})
    send(index, {:index_batch, generation, entries, []})
    :sys.get_state(index)

    assert {:error, message} = Index.search(index, "*.ex", limit: 1, timeout: 10)
    assert message =~ "timed out"
    assert {:ok, %{paths: ["target.ex"]}} = Index.files(index, path: "target.ex", timeout: 200)
  end

  test "tied search pages preserve every scoped result and exclude adjacent prefixes", %{
    index: index
  } do
    generation = :sys.get_state(index).generation
    paths = ["lib/a.ex", "lib/b.ex", "lib/c.ex", "lib-other/a.ex", "lib.other/a.ex"]
    entries = Enum.map(paths, &{&1, %{size: 1}})
    :sys.replace_state(index, &%{&1 | status: :indexing})
    send(index, {:index_batch, generation, entries, []})
    :sys.get_state(index)

    assert {:ok, all} = Index.search(index, "*.ex", path: "lib", limit: 10)
    assert {:ok, first} = Index.search(index, "*.ex", path: "lib", limit: 2)

    assert {:ok, second} =
             Index.search(index, "*.ex", path: "lib", limit: 2, cursor: first.cursor)

    assert first.paths ++ second.paths == all.paths
    assert Enum.map(all.paths, & &1.path) == ["lib/a.ex", "lib/b.ex", "lib/c.ex"]
    assert second.cursor == nil
    assert {:ok, %{paths: ["lib/a.ex", "lib/b.ex", "lib/c.ex"]}} = Index.files(index, path: "lib")
  end

  test "large inventory has stable small pages and applies scope before limiting", %{index: index} do
    generation = :sys.get_state(index).generation

    entries =
      for n <- 1..30_000 do
        {"bulk/file_#{String.pad_leading(to_string(n), 5, "0")}.ex", %{size: 1}}
      end

    # Use the normal indexing batch contract while the scan is in progress.
    :sys.replace_state(index, &%{&1 | status: :indexing})
    send(index, {:index_batch, generation, entries, []})
    :sys.get_state(index)

    assert {:ok, first} = Index.files(index, path: "bulk", limit: 2)
    assert first.paths == ["bulk/file_00001.ex", "bulk/file_00002.ex"]
    assert {:ok, second} = Index.files(index, path: "bulk", limit: 2, cursor: first.cursor)
    assert second.paths == ["bulk/file_00003.ex", "bulk/file_00004.ex"]

    assert {:ok, %{paths: ["target.ex"], cursor: nil}} =
             Index.files(index, path: "target.ex", limit: 1)

    started_at = System.monotonic_time(:millisecond)

    for _ <- 1..100 do
      assert {:ok, %{paths: ["target.ex"], cursor: nil}} =
               Index.files(index, path: "target.ex", limit: 1)
    end

    assert System.monotonic_time(:millisecond) - started_at < 1_000

    assert {:ok, result} = Index.search(index, "*.ex", path: "target.ex", limit: 1)
    assert Enum.map(result.paths, & &1.path) == ["target.ex"]
    assert result.cursor == nil
  end
end
