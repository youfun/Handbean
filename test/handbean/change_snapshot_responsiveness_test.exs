defmodule Handbean.ChangeSnapshotResponsivenessTest do
  use ExUnit.Case, async: true

  require Phoenix.LiveViewTest

  alias Handbean.ChangeSnapshot
  alias HandbeanWeb.FileChangeCard

  test "large created and deleted files retain exact snapshots within a bounded worker" do
    content = Enum.map_join(1..12_000, "\n", &"line #{&1}") <> "\n"

    for operation <- [:create, :delete] do
      snapshot =
        bounded(fn ->
          case operation do
            :create -> ChangeSnapshot.build_write_snapshot("large.txt", nil, content)
            :delete -> ChangeSnapshot.build_delete_snapshot("large.txt", content)
          end
        end)

      assert snapshot.reversible
      assert (snapshot.before_content || snapshot.after_content) == content
      assert Enum.count(snapshot.diff_lines, &(&1["type"] in ["ins", "del"])) == 12_000
    end
  end

  test "large rewrites and unbalanced inputs produce an exact script without unbounded alignment" do
    old = Enum.map_join(1..12_000, "\n", &"old #{&1}")
    new = Enum.map_join(1..12_000, "\n", &"new #{&1}")

    for {before_content, after_content} <- [{old, new}, {"tiny", new}, {old, "tiny"}] do
      script = bounded(fn -> ChangeSnapshot.line_diff(before_content, after_content) end)
      assert reconstruct(script, [:eq, :del]) == before_content
      assert reconstruct(script, [:eq, :ins]) == after_content
    end
  end

  test "large common edges retain a small precise change" do
    prefix = String.duplicate("prefix\n", 12_000)
    suffix = String.duplicate("\nsuffix", 12_000)

    lines =
      bounded(fn ->
        ChangeSnapshot.diff_lines(prefix <> "old" <> suffix, prefix <> "new" <> suffix)
      end)

    assert Enum.filter(lines, &(&1["type"] == "del")) == [%{"type" => "del", "text" => "old"}]
    assert Enum.filter(lines, &(&1["type"] == "ins")) == [%{"type" => "ins", "text" => "new"}]
    assert Enum.any?(lines, &(&1["type"] == "skip"))
  end

  test "scripts preserve blank lines, trailing newlines, CRLF, BOM and Unicode" do
    for {old, new} <- [
          {"", ""},
          {"", "\n"},
          {"a", "a\n"},
          {"a\n", "a"},
          {"\n\na\n", "\na\n\n"},
          {"\uFEFF你好\r\n旧\r\n", "\uFEFF你好\r\n新\r\n"},
          {String.duplicate("x\ny\n", 260), String.duplicate("y\nx\n", 260)},
          {String.duplicate("a", 150_000), String.duplicate("b", 150_000)}
        ] do
      script = bounded(fn -> ChangeSnapshot.line_diff(old, new) end)
      assert reconstruct(script, [:eq, :del]) == old
      assert reconstruct(script, [:eq, :ins]) == new
    end
  end

  test "net changes aggregate a large file before rendering a bounded preview" do
    contents = Enum.map_join(1..12_000, "\n", &"created #{&1}") <> "\n"
    entries = [entry("create", nil, contents), entry("update", contents, contents <> "latest\n")]
    [row] = bounded(fn -> FileChangeCard.changes(entries) end)

    assert row["change"]["before_content"] == nil
    assert row["change"]["after_content"] == contents <> "latest\n"
    assert row["change"]["reversible"]
    assert FileChangeCard.line_counts(row["diff_lines"]) == %{added: 12_001, removed: 0}

    html =
      bounded(fn ->
        Phoenix.LiveViewTest.render_component(&FileChangeCard.card/1, entry: row, open?: true)
      end)

    assert html =~ "created 1"
    assert html =~ "+12001"
    assert html =~ "Diff preview truncated"
    refute html =~ "created 12000"
    assert byte_size(html) < 250_000
  end

  test "a very long line cannot create an unbounded card preview" do
    content = String.duplicate("x", 150_000)
    [row] = bounded(fn -> FileChangeCard.changes([entry("long", nil, content)]) end)

    html =
      bounded(fn ->
        Phoenix.LiveViewTest.render_component(&FileChangeCard.card/1, entry: row, open?: true)
      end)

    assert html =~ "Diff preview truncated"
    refute html =~ content
    assert byte_size(html) < 10_000
  end

  @tag :tmp_dir
  test "coarse previews retain exact revert contents and conflict checks", %{tmp_dir: root} do
    path = Path.join(root, "rewrite.txt")
    old = Enum.map_join(1..2_000, "\n", &"before #{&1}")
    new = Enum.map_join(1..2_000, "\n", &"after #{&1}")
    snapshot = bounded(fn -> ChangeSnapshot.build_edit_snapshot(path, old, new) end)
    assert snapshot.reversible
    assert snapshot.before_sha256 == ChangeSnapshot.sha256(old)
    assert snapshot.after_sha256 == ChangeSnapshot.sha256(new)

    File.write!(path, "external change")
    assert {:conflict, _} = Handbean.ChangeReverter.revert(snapshot, root)
    assert File.read!(path) == "external change"

    File.write!(path, new)
    assert {:ok, _} = Handbean.ChangeReverter.revert(snapshot, root)
    assert File.read!(path) == old
  end

  defp entry(id, before_content, after_content) do
    %{
      "id" => id,
      "tool_name" => "write",
      "tool_status" => "done",
      "file_path" => "large.txt",
      "change" => %{
        "change_id" => id,
        "file_path" => "large.txt",
        "existed_before" => is_binary(before_content),
        "existed_after" => true,
        "before_content" => before_content,
        "after_content" => after_content,
        "before_sha256" => ChangeSnapshot.sha256(before_content),
        "after_sha256" => ChangeSnapshot.sha256(after_content)
      }
    }
  end

  defp reconstruct(script, types) do
    script
    |> Enum.flat_map(fn {type, lines} -> if type in types, do: lines, else: [] end)
    |> Enum.join("\n")
  end

  defp bounded(fun) do
    parent = self()
    result_ref = make_ref()

    {pid, monitor} =
      :erlang.spawn_opt(
        fn -> send(parent, {result_ref, fun.()}) end,
        [:monitor, {:max_heap_size, %{size: 8_000_000, kill: true, error_logger: false}}]
      )

    try do
      receive do
        {^result_ref, result} ->
          result

        {:DOWN, ^monitor, :process, ^pid, reason} ->
          flunk("diff worker failed: #{inspect(reason)}")
      after
        5_000 -> flunk("diff exceeded the interactive response deadline")
      end
    after
      Process.exit(pid, :kill)
      Process.demonitor(monitor, [:flush])
    end
  end
end
