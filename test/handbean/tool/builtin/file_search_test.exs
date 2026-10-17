defmodule Handbean.Tool.Builtin.FileSearchTest do
  @moduledoc """
  Tests for the FileSearch builtin tool.
  """

  use ExUnit.Case, async: false

  alias Handbean.Tool.Builtin.FileSearch

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "sigil_file_search_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    File.mkdir_p!(Path.join(tmp_dir, "lib"))
    File.mkdir_p!(Path.join(tmp_dir, "test"))

    File.write!(Path.join(tmp_dir, "lib/user.ex"), "module")
    File.write!(Path.join(tmp_dir, "lib/user_controller.ex"), "module")
    File.write!(Path.join(tmp_dir, "test/user_test.exs"), "module")

    {:ok, index} = ExFff.Index.ensure_started(tmp_dir)
    assert :ok = ExFff.Index.await_index(index)

    on_exit(fn ->
      case ExFff.Index.ensure_started(tmp_dir) do
        {:ok, pid} ->
          if Process.alive?(pid) do
            GenServer.stop(pid)
          end

        _ ->
          :ok
      end

      File.rm_rf(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  describe "tool metadata" do
    test "has correct name" do
      assert FileSearch.name() == "file_search"
    end

    test "description tells the model how to query" do
      description = FileSearch.description()
      assert description =~ "1–2 filename fragments"
      assert description =~ "file name only"
      assert description =~ "grep"
      refute description =~ "typo-tolerant"
    end

    test "input_schema requires query" do
      schema = FileSearch.input_schema()
      assert schema.type == "object"
      assert "query" in schema.required
      # Property keys are atoms in the map
      assert Map.has_key?(schema.properties, :query)
    end

    test "max_result_chars is a positive integer" do
      assert is_integer(FileSearch.max_result_chars())
      assert FileSearch.max_result_chars() > 0
    end
  end

  describe "execute/2" do
    test "returns error when query is missing" do
      {:error, reason} = FileSearch.execute(%{}, %{working_directory: "/tmp"})
      assert reason =~ "required"
    end

    test "requires an explicit workspace directory" do
      assert {:error, "working_directory is required"} =
               FileSearch.execute(%{"query" => "user"}, %{})
    end

    test "returns results for valid query", %{tmp_dir: tmp_dir} do
      {:ok, output} = FileSearch.execute(%{"query" => "user"}, %{working_directory: tmp_dir})

      assert output =~ "Found"
      assert output =~ "user"
      assert output =~ "[filename]"
      assert output =~ "ms"
    end

    test "yolo searches an explicit directory outside the workspace", %{tmp_dir: tmp_dir} do
      outside =
        Path.join(System.tmp_dir!(), "handbean-yolo-files-#{System.unique_integer([:positive])}")

      file = Path.join(outside, "external_widget.ex")
      File.mkdir_p!(outside)
      File.write!(file, "module")

      on_exit(fn ->
        case ExFff.Index.ensure_started(outside) do
          {:ok, pid} when is_pid(pid) -> GenServer.stop(pid)
          _ -> :ok
        end

        File.rm_rf!(outside)
      end)

      assert {:ok, output} =
               FileSearch.execute(%{"query" => "external_widget", "path" => outside}, %{
                 working_directory: tmp_dir,
                 approval_mode: :yolo
               })

      assert output =~ file
    end

    test "includes score in output", %{tmp_dir: tmp_dir} do
      {:ok, output} = FileSearch.execute(%{"query" => "user"}, %{working_directory: tmp_dir})

      # Output format: "1.\tpath\t(score)"
      assert output =~ "\t("
      assert output =~ ")"
    end

    test "respects limit option", %{tmp_dir: tmp_dir} do
      {:ok, output} =
        FileSearch.execute(%{"query" => "*.ex", "limit" => 1}, %{working_directory: tmp_dir})

      # Only one numbered result
      assert output =~ "1."
      refute output =~ "2."
    end

    test "supports path, exclude, and cursor pagination", %{tmp_dir: tmp_dir} do
      assert {:ok, first} =
               FileSearch.execute(%{"query" => "user", "path" => "lib", "limit" => 1}, %{
                 working_directory: tmp_dir
               })

      assert first =~ "next_cursor:"
      refute first =~ "test/user_test.exs"
      [_, cursor] = Regex.run(~r/next_cursor: (\S+)/, first)
      first_result = first |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "1.\t"))

      assert {:ok, second} =
               FileSearch.execute(
                 %{
                   "query" => "user",
                   "path" => "lib",
                   "limit" => 1,
                   "cursor" => cursor
                 },
                 %{working_directory: tmp_dir}
               )

      refute second =~ first_result

      assert {:ok, excluded} =
               FileSearch.execute(
                 %{"query" => "user", "path" => "lib", "exclude" => ["controller"]},
                 %{working_directory: tmp_dir}
               )

      refute excluded =~ "lib/user_controller.ex"
    end

    test "supports extension filter", %{tmp_dir: tmp_dir} do
      {:ok, output} = FileSearch.execute(%{"query" => "user *.ex"}, %{working_directory: tmp_dir})

      assert output =~ "Found"
      assert output =~ "user"
    end

    test "supports exclude pattern", %{tmp_dir: tmp_dir} do
      {:ok, output} =
        FileSearch.execute(%{"query" => "user !test/"}, %{working_directory: tmp_dir})

      # Results should not include test/ paths (header contains query string, skip it)
      lines = String.split(output, "\n")
      result_lines = Enum.drop_while(lines, &String.starts_with?(&1, "#"))

      Enum.each(result_lines, fn line ->
        if line != "" do
          refute line =~ "test/"
        end
      end)

      assert output =~ "lib/user"
    end

    test "returns no-results message for empty results", %{tmp_dir: tmp_dir} do
      {:ok, output} =
        FileSearch.execute(%{"query" => "zzz_nonexistent_xyz"}, %{working_directory: tmp_dir})

      assert output =~ "No files found"
      assert output =~ "Indexed"
      assert output =~ "use grep"
    end

    test "says a zero-hit star query was a filename glob", %{tmp_dir: tmp_dir} do
      {:ok, output} =
        FileSearch.execute(%{"query" => "sidebar*.heex"}, %{working_directory: tmp_dir})

      assert output =~ "No files found"
      assert output =~ "这是文件名 glob，不是路径 glob"
      assert output =~ "Indexed"
    end

    test "labels a partial multi-term match", %{tmp_dir: tmp_dir} do
      {:ok, output} =
        FileSearch.execute(%{"query" => "user missingterm"}, %{working_directory: tmp_dir})

      assert output =~ "partial match: 1/2 terms"
      assert output =~ "lib/user.ex"
      refute output =~ "partial match: 2/2"
    end

    test "marks partial results while the background index is still building", %{tmp_dir: tmp_dir} do
      {:ok, index} = ExFff.Index.ensure_started(tmp_dir)
      :sys.replace_state(index, &%{&1 | status: :indexing})

      assert {:ok, output} =
               FileSearch.execute(%{"query" => "user"}, %{working_directory: tmp_dir})

      assert output =~ "indexing"
      assert output =~ "user"
    end

    test "waits for a cold index instead of reporting zero files", %{tmp_dir: tmp_dir} do
      {:ok, index} = ExFff.Index.ensure_started(tmp_dir)
      task_ref = make_ref()

      state =
        :sys.replace_state(index, fn state ->
          :ets.delete_all_objects(state.files_ref)
          :ets.delete_all_objects(state.trigram_ref)

          %{
            state
            | status: :indexing,
              indexed_count: 0,
              task: %Task{ref: task_ref, pid: self(), owner: self(), mfa: {__MODULE__, :scan, 0}}
          }
        end)

      search =
        Task.async(fn ->
          FileSearch.execute(%{"query" => "*user*"}, %{working_directory: tmp_dir})
        end)

      await_pending_search(index)

      path = "lib/user.ex"
      trigrams = path |> ExFff.Matcher.tokenize() |> Enum.map(&{&1, path})

      send(
        index,
        {:index_batch, state.generation, [{path, %{mtime: {{2026, 1, 1}, {0, 0, 0}}, size: 6}}],
         trigrams}
      )

      send(index, {task_ref, {:ok, state.generation, 1}})

      assert {:ok, output} = Task.await(search)
      assert output =~ "lib/user.ex"
      refute output =~ "No files found"
    end
  end

  defp await_pending_search(index) do
    if :sys.get_state(index).pending_searches == [] do
      await_pending_search(index)
    end
  end
end
