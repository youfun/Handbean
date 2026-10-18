defmodule Handbean.Tool.Builtin.GrepTest do
  use ExUnit.Case, async: false

  alias Handbean.Tool.Builtin.Grep

  @work_dir Path.join(System.tmp_dir!(), "sigil_grep_test_#{System.unique_integer([:positive])}")

  setup do
    File.rm_rf!(@work_dir)
    File.mkdir_p!(@work_dir)
    on_exit(fn -> File.rm_rf!(@work_dir) end)
  end

  test "searches file contents with line numbers" do
    File.write!(
      Path.join(@work_dir, "sample.ex"),
      "defmodule Sample do\n  def hello, do: :world\nend\n"
    )

    {:ok, output} =
      grep(%{"pattern" => "def hello", "path" => "."}, %{working_directory: @work_dir})

    assert output =~ "sample.ex:2:"
    assert output =~ "def hello"
  end

  test "ripgrep keeps the filename when path selects one file" do
    File.write!(Path.join(@work_dir, "sample.ex"), "one\nsingle_file_marker\n")
    bin = Path.join(@work_dir, "bin")
    File.mkdir_p!(bin)
    rg = Path.join(bin, "rg")

    File.write!(
      rg,
      "#!/bin/sh\ncase \" $* \" in *\" --with-filename \"*) printf 'sample.ex:2:single_file_marker\\n'; exit 0;; *) printf '2:single_file_marker\\n'; exit 0;; esac\n"
    )

    File.chmod!(rg, 0o755)
    original_path = System.get_env("PATH")

    try do
      System.put_env("PATH", bin)

      assert {:ok, output} =
               grep(%{"pattern" => "single_file_marker", "path" => "sample.ex"}, %{
                 working_directory: @work_dir
               })

      assert output =~ "sample.ex:2:single_file_marker"
    after
      if original_path, do: System.put_env("PATH", original_path)
    end
  end

  test "ripgrep traverses the scope once instead of spawning per inventory batch" do
    for index <- 1..250 do
      File.write!(Path.join(@work_dir, "file-#{index}.txt"), "bulk_marker\n")
    end

    bin = Path.join(@work_dir, "bin")
    counter = Path.join(@work_dir, "rg-count")
    File.mkdir_p!(bin)
    rg = Path.join(bin, "rg")

    File.write!(
      rg,
      "#!/bin/sh\necho x >> '#{counter}'\nprintf 'file-250.txt:1:bulk_marker\\n'\n"
    )

    File.chmod!(rg, 0o755)
    original_path = System.get_env("PATH")

    try do
      System.put_env("PATH", bin)

      assert {:ok, output} =
               grep(%{"pattern" => "bulk_marker", "path" => "."}, %{
                 working_directory: @work_dir
               })

      assert output =~ "file-250.txt:1:bulk_marker"
      assert counter |> File.read!() |> String.split("\n", trim: true) |> length() == 1
    after
      if original_path, do: System.put_env("PATH", original_path)
    end
  end

  test "accepts Claude-style -A and -n arguments" do
    File.write!(Path.join(@work_dir, "sample.ex"), "one\ntwo\nthree\nfour\n")

    {:ok, output} =
      grep(
        %{"pattern" => "two", "path" => ".", "-n" => true, "-A" => 2, "output_mode" => "content"},
        %{working_directory: @work_dir}
      )

    assert output =~ "sample.ex:2:two"
    assert output =~ "sample.ex-3-three"
    assert output =~ "sample.ex-4-four"
  end

  test "returns no matches as ok" do
    File.write!(Path.join(@work_dir, "sample.ex"), "abc\n")

    assert {:ok, "No matches found"} =
             grep(%{"pattern" => "missing", "path" => "."}, %{
               working_directory: @work_dir
             })
  end

  test "groups results and continues with an opaque cursor" do
    File.write!(Path.join(@work_dir, "one.txt"), "marker one\nmarker two\n")
    File.write!(Path.join(@work_dir, "two.txt"), "marker three\nmarker four\n")

    assert {:ok, first} =
             grep(%{"pattern" => "marker", "path" => ".", "limit" => 2}, %{
               working_directory: @work_dir
             })

    assert first =~ "== one.txt =="
    assert first =~ "next_cursor:"
    [_, cursor] = Regex.run(~r/next_cursor: (\S+)/, first)

    assert {:ok, second} =
             grep(%{"pattern" => "marker", "path" => ".", "limit" => 2, "cursor" => cursor}, %{
               working_directory: @work_dir
             })

    refute second =~ "marker one"
    refute second =~ "marker two"
    assert second =~ "marker three"
    assert second =~ "marker four"
  end

  test "treats omitted, nil, and empty cursors as the first page" do
    File.write!(Path.join(@work_dir, "one.txt"), "marker one\nmarker two\n")

    base = %{"pattern" => "marker", "path" => ".", "limit" => 1}
    context = %{working_directory: @work_dir}

    assert {:ok, omitted} = grep(base, context)
    assert {:ok, nil_cursor} = grep(Map.put(base, "cursor", nil), context)
    assert {:ok, empty_cursor} = grep(Map.put(base, "cursor", ""), context)

    assert nil_cursor == omitted
    assert empty_cursor == omitted
    assert omitted =~ "marker one"
    refute omitted =~ "marker two"
  end

  test "rejects a cursor returned by a different query with actionable guidance" do
    File.write!(Path.join(@work_dir, "one.txt"), "marker one\nmarker two\nother\n")

    assert {:ok, first} =
             grep(%{"pattern" => "marker", "path" => ".", "limit" => 1}, %{
               working_directory: @work_dir
             })

    [_, cursor] = Regex.run(~r/next_cursor: (\S+)/, first)

    assert {:error, reason, details} =
             Grep.execute(
               %{"pattern" => "other", "path" => ".", "limit" => 1, "cursor" => cursor},
               %{working_directory: @work_dir}
             )

    assert reason =~ "Omit cursor for a new query"
    assert reason =~ "next_cursor returned by the same query"
    assert details.code == :cursor_invalid
  end

  test "paginates 5000 fallback matches without duplicates or one huge result" do
    body = Enum.map_join(1..5_000, "\n", &"bulk_page_marker #{&1}")
    File.write!(Path.join(@work_dir, "bulk.txt"), body)

    without_rg(fn ->
      {seen, final_cursor} =
        Enum.reduce(1..5, {MapSet.new(), nil}, fn _page, {seen, cursor} ->
          input =
            %{"pattern" => "bulk_page_marker", "path" => ".", "limit" => 1_000}
            |> then(fn input -> if cursor, do: Map.put(input, "cursor", cursor), else: input end)

          assert {:ok, output} = grep(input, %{working_directory: @work_dir})
          assert byte_size(output) < 100_000

          numbers =
            Regex.scan(~r/bulk_page_marker (\d+)/, output, capture: :all_but_first)
            |> Enum.map(fn [number] -> String.to_integer(number) end)

          assert length(numbers) == 1_000
          assert Enum.all?(numbers, &(not MapSet.member?(seen, &1)))

          next_cursor =
            case Regex.run(~r/next_cursor: (\S+)/, output) do
              [_, value] -> value
              nil -> nil
            end

          {Enum.reduce(numbers, seen, &MapSet.put(&2, &1)), next_cursor}
        end)

      assert MapSet.size(seen) == 5_000
      assert final_cursor == nil
    end)
  end

  test "rejects paths outside workspace" do
    assert {:error, reason} =
             grep(%{"pattern" => "root", "path" => "/etc"}, %{
               working_directory: @work_dir
             })

    assert reason =~ "outside workspace"
  end

  test "yolo searches an explicit path outside the workspace" do
    outside =
      Path.join(System.tmp_dir!(), "handbean-yolo-grep-#{System.unique_integer([:positive])}")

    file = Path.join(outside, "external.txt")
    File.mkdir_p!(outside)
    File.write!(file, "external_marker\n")
    on_exit(fn -> File.rm_rf!(outside) end)

    assert {:ok, output} =
             grep(%{"pattern" => "external_marker", "path" => outside}, %{
               working_directory: @work_dir,
               approval_mode: :yolo
             })

    assert output =~ file <> ":1:external_marker"
  end

  test "has expected metadata" do
    assert Grep.name() == "grep"
    assert Grep.concurrent?() == true
    assert is_integer(Grep.max_result_chars())
    assert Grep.input_schema().required == []
    assert Grep.description() =~ "file_search"
    assert Grep.input_schema().properties.pattern.description =~ "omit"
    assert Grep.input_schema().properties.glob.description =~ "not a search pattern"

    for compatibility_field <- [:output_mode, :"-n", :"-A", :"-B", :"-C"] do
      refute Map.has_key?(Grep.input_schema().properties, compatibility_field)
    end
  end

  test "elixir fallback finds matches without rg" do
    File.write!(
      Path.join(@work_dir, "sample.ex"),
      "defmodule Sample do\n  def hello, do: :world\nend\n"
    )

    original_path = System.get_env("PATH")

    try do
      System.put_env("PATH", "/nonexistent")

      {:ok, output} =
        grep(%{"pattern" => "def hello", "path" => "."}, %{working_directory: @work_dir})

      assert output =~ "sample.ex:2:"
      assert output =~ "def hello"
    after
      if original_path, do: System.put_env("PATH", original_path)
    end
  end

  test "elixir fallback glob matches nested files like rg" do
    nested = Path.join([@work_dir, "src", "sample.ex"])
    File.mkdir_p!(Path.dirname(nested))
    File.write!(nested, "defmodule Nested do\n  def hello, do: :ok\nend\n")

    original_path = System.get_env("PATH")

    try do
      System.put_env("PATH", "/nonexistent")

      {:ok, output} =
        grep(%{"pattern" => "def hello", "path" => ".", "glob" => "*.ex"}, %{
          working_directory: @work_dir
        })

      assert output =~ "src/sample.ex"
      assert output =~ "def hello"
    after
      if original_path, do: System.put_env("PATH", original_path)
    end
  end

  test "elixir fallback expands brace globs" do
    File.write!(Path.join(@work_dir, "one.ex"), "shared_marker\n")
    File.write!(Path.join(@work_dir, "two.heex"), "shared_marker\n")
    File.write!(Path.join(@work_dir, "three.css"), "shared_marker\n")

    without_rg(fn ->
      assert {:ok, output} =
               grep(
                 %{"pattern" => "shared_marker", "path" => ".", "glob" => "*.{ex,heex}"},
                 %{working_directory: @work_dir}
               )

      assert output =~ "one.ex"
      assert output =~ "two.heex"
      refute output =~ "three.css"
    end)
  end

  test "elixir fallback skips dependency and build directories" do
    for dir <- ["deps", "node_modules", "_build", ".git", "build", "tmp"] do
      File.mkdir_p!(Path.join(@work_dir, dir))
      File.write!(Path.join([@work_dir, dir, "ignored.ex"]), "ignored_vendor_marker\n")
    end

    without_rg(fn ->
      assert {:ok, "No matches found"} =
               grep(%{"pattern" => "ignored_vendor_marker", "path" => "."}, %{
                 working_directory: @work_dir
               })
    end)
  end

  test "uses the same gitignore-aware ExFff inventory" do
    git = System.find_executable("git")

    if git do
      File.mkdir_p!(Path.join([@work_dir, "desktop", "Resources", "generated"]))
      File.write!(Path.join(@work_dir, "visible.ex"), "visible_inventory_marker\n")

      File.write!(
        Path.join([@work_dir, "desktop", "Resources", "generated", "bundle.js"]),
        "ignored_inventory_marker\n"
      )

      File.write!(
        Path.join([@work_dir, "desktop", ".gitignore"]),
        "Resources/generated/**\n"
      )

      {_output, 0} = System.cmd(git, ["init", "-q", @work_dir])

      assert {:ok, ignored} =
               grep(%{"pattern" => "ignored_inventory_marker", "path" => "."}, %{
                 working_directory: @work_dir
               })

      assert ignored == "No matches found"

      assert {:ok, visible} =
               grep(%{"pattern" => "visible_inventory_marker", "path" => "."}, %{
                 working_directory: @work_dir
               })

      assert visible =~ "visible.ex"
    end
  end

  test "elixir fallback does not follow workspace symlinks" do
    outside_dir =
      Path.join(System.tmp_dir!(), "sigil_grep_symlink_#{System.unique_integer([:positive])}")

    File.mkdir_p!(outside_dir)
    File.write!(Path.join(outside_dir, "secret.txt"), "symlink_secret_marker\n")
    File.ln_s!(outside_dir, Path.join(@work_dir, "linked"))

    try do
      without_rg(fn ->
        assert {:ok, "No matches found"} =
                 grep(%{"pattern" => "symlink_secret_marker", "path" => "."}, %{
                   working_directory: @work_dir
                 })
      end)
    after
      File.rm_rf!(outside_dir)
    end
  end

  test "a native file watcher crash does not terminate the shared watcher" do
    index_name =
      Module.concat(
        ExFff.Index,
        String.to_atom("WatcherIndex_#{System.unique_integer([:positive])}")
      )

    watcher_name =
      Module.concat(
        Handbean.Search.Watcher,
        String.to_atom("Isolated_#{System.unique_integer([:positive])}")
      )

    {:ok, index} = ExFff.Index.start_link(root_path: @work_dir, name: index_name)
    assert :ok = ExFff.Index.await_index(index)
    {:ok, watcher} = Handbean.Search.Watcher.start_link(name: watcher_name)
    GenServer.cast(watcher, {:watch, Path.expand(@work_dir), index})

    first =
      eventually(fn ->
        case :sys.get_state(watcher).workspaces[Path.expand(@work_dir)] do
          %{watcher: pid} when is_pid(pid) -> {:ok, pid}
          _ -> :retry
        end
      end)

    watcher_ref = Process.monitor(watcher)
    Process.exit(first, :kill)

    second =
      eventually(fn ->
        case :sys.get_state(watcher).workspaces[Path.expand(@work_dir)] do
          %{watcher: pid} when is_pid(pid) and pid != first -> {:ok, pid}
          _ -> :retry
        end
      end)

    assert Process.alive?(second)
    refute_receive {:DOWN, ^watcher_ref, :process, ^watcher, _reason}, 50
    GenServer.stop(watcher)
    GenServer.stop(index)
  end

  test "an unavailable native watcher retains inventory and can recover" do
    # Missing platform executables make FileSystem.start_link return :ignore,
    # not {:error, reason}. This must not crash the shared application.
    workspace = Path.expand(@work_dir)
    File.write!(Path.join(workspace, "initial.txt"), "initial inventory\n")
    index_name = Module.concat(ExFff.Index, "Unavailable_#{System.unique_integer([:positive])}")

    watcher_name =
      Module.concat(Handbean.Search.Watcher, "Unavailable_#{System.unique_integer([:positive])}")

    index = start_supervised!({ExFff.Index, root_path: workspace, name: index_name})
    assert :ok = ExFff.Index.await_index(index)
    watcher = start_supervised!({Handbean.Search.Watcher, name: watcher_name})
    original_path = System.get_env("PATH")
    original_mac = System.get_env("FILESYSTEM_FSMAC_EXECUTABLE_FILE")
    original_inotify = System.get_env("FILESYSTEM_FSINOTIFY_EXECUTABLE_FILE")
    original_config = Application.fetch_env(:file_system, :fs_inotify)

    try do
      System.put_env("PATH", "/nonexistent")
      System.put_env("FILESYSTEM_FSMAC_EXECUTABLE_FILE", "/nonexistent/fswatch")
      System.delete_env("FILESYSTEM_FSINOTIFY_EXECUTABLE_FILE")
      Application.put_env(:file_system, :fs_inotify, executable_file: nil)
      assert :ignore = FileSystem.start_link(dirs: [workspace])
      GenServer.cast(watcher, {:watch, workspace, index})
      assert %{index: ^index, watcher: nil} = :sys.get_state(watcher).workspaces[workspace]

      added = Path.join(workspace, "added.txt")
      File.write!(added, "explicit update\n")
      GenServer.cast(watcher, {:path_changed, workspace, added})
      :sys.get_state(watcher)

      assert eventually(fn ->
               {:ok, inventory} = ExFff.Index.files(index)
               if inventory.paths == ["added.txt", "initial.txt"], do: {:ok, true}, else: :retry
             end)
    after
      for {key, value} <- [
            {"PATH", original_path},
            {"FILESYSTEM_FSMAC_EXECUTABLE_FILE", original_mac},
            {"FILESYSTEM_FSINOTIFY_EXECUTABLE_FILE", original_inotify}
          ] do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end

      case original_config do
        {:ok, value} -> Application.put_env(:file_system, :fs_inotify, value)
        :error -> Application.delete_env(:file_system, :fs_inotify)
      end
    end

    send(watcher, {:restart_watcher, workspace})
    assert %{watcher: native} = :sys.get_state(watcher).workspaces[workspace]
    assert is_pid(native)
    assert Process.alive?(native)
    GenServer.stop(native)
  end

  test "elixir fallback glob cannot escape the workspace" do
    outside_dir =
      Path.join(System.tmp_dir!(), "sigil_grep_outside_#{System.unique_integer([:positive])}")

    File.mkdir_p!(outside_dir)
    outside = Path.join(outside_dir, "secret.txt")
    File.write!(outside, "outside_workspace_marker\n")

    original_path = System.get_env("PATH")

    try do
      System.put_env("PATH", "/nonexistent")

      {:ok, output} =
        grep(
          %{"pattern" => "outside_workspace_marker", "path" => ".", "glob" => "../secret.txt"},
          %{working_directory: @work_dir}
        )

      refute output =~ "outside_workspace_marker"
      assert output == "No matches found"
    after
      if original_path, do: System.put_env("PATH", original_path)
      File.rm_rf(outside_dir)
    end
  end

  test "lists files when glob is set and pattern is omitted" do
    live = Path.join(@work_dir, "live")
    File.mkdir_p!(live)
    File.write!(Path.join(live, "mcp_settings_live.html.heex"), "<div></div>\n")
    File.write!(Path.join(@work_dir, "other.txt"), "nope\n")

    {:ok, output} =
      grep(%{"glob" => "**/mcp_settings_live*"}, %{working_directory: @work_dir})

    assert output =~ "live/mcp_settings_live.html.heex"
    refute output =~ "other.txt"
    refute output =~ "pattern is required"
  end

  test "rewrites a hallucinated absolute project root into the current workspace" do
    File.write!(
      Path.join(@work_dir, "sample.ex"),
      "defmodule Sample do\n  def hello, do: :world\nend\n"
    )

    base = Path.basename(@work_dir)

    {:ok, output} =
      grep(
        %{
          "pattern" => "def hello",
          "path" => "/Users/zhangxianwei/#{base}/#{base}",
          "glob" => "*.ex"
        },
        %{working_directory: @work_dir}
      )

    assert output =~ "sample.ex:2:"
    assert output =~ "path rewritten into workspace"
    refute output =~ "Path traversal"
  end

  test "keeps an unrelated absolute path outside the workspace" do
    assert {:error, reason} =
             Grep.execute(
               %{"pattern" => "def hello", "path" => "/Users/xuelei/Projects/open-design"},
               %{working_directory: @work_dir}
             )

    assert reason =~ "Path traversal blocked"
    assert reason =~ @work_dir
    assert reason =~ "workspace-relative"
    refute reason =~ "narrow path"
  end

  test "does not follow a rewritten path out of the workspace" do
    base = Path.basename(@work_dir)

    assert {:error, reason} =
             Grep.execute(
               %{
                 "pattern" => "secret",
                 "path" => "/Users/zhangxianwei/#{base}/../../etc/passwd"
               },
               %{working_directory: @work_dir}
             )

    assert reason =~ "Path traversal blocked"
    refute reason =~ "root:"
  end

  test "missing pattern without glob names the workspace instead of asking to change path" do
    assert {:error, reason} = Grep.execute(%{}, %{working_directory: @work_dir})
    assert reason =~ "pattern is required"
    assert reason =~ @work_dir
    refute reason =~ "narrow path"
  end

  defp grep(input, context) do
    workspace = context[:working_directory]
    {:ok, index} = ExFff.Index.ensure_started(workspace)
    ExFff.Index.refresh(index)
    assert :ok = await_current_index(index)
    Grep.execute(input, context)
  end

  defp await_current_index(index, attempts \\ 3)

  defp await_current_index(index, attempts) when attempts > 0 do
    case ExFff.Index.await_index(index, 5_000) do
      {:error, "index restarted"} -> await_current_index(index, attempts - 1)
      result -> result
    end
  end

  defp await_current_index(_index, 0), do: {:error, "index kept restarting"}

  defp without_rg(fun) do
    original_path = System.get_env("PATH")

    try do
      System.put_env("PATH", "/nonexistent")
      fun.()
    after
      if original_path, do: System.put_env("PATH", original_path)
    end
  end

  test "rejects a sensitive search root and does not return workspace secret files" do
    File.write!(Path.join(@work_dir, ".env"), "SECRET_MARKER_DO_NOT_LEAK\n")
    File.write!(Path.join(@work_dir, "app.ex"), "visible_marker\n")
    ssh = Path.join(@work_dir, ".ssh")
    File.mkdir_p!(ssh)
    File.write!(Path.join(ssh, "id_rsa"), "SECRET_KEY_DO_NOT_LEAK\n")

    assert {:error, "sensitive path blocked"} =
             grep(%{"pattern" => "SECRET", "path" => ".ssh"}, %{
               working_directory: @work_dir
             })

    {:ok, visible} =
      grep(%{"pattern" => "visible_marker", "path" => "."}, %{
        working_directory: @work_dir
      })

    assert visible =~ "visible_marker"
    refute visible =~ "SECRET_MARKER_DO_NOT_LEAK"

    assert {:ok, "No matches found"} =
             grep(%{"pattern" => "SECRET_", "path" => "."}, %{
               working_directory: @work_dir
             })
  end

  defp eventually(fun, attempts \\ 60)

  defp eventually(fun, attempts) when attempts > 0 do
    case fun.() do
      {:ok, value} ->
        value

      :retry ->
        receive do
        after
          50 -> eventually(fun, attempts - 1)
        end
    end
  end

  defp eventually(_fun, 0), do: flunk("condition did not become true")
end
