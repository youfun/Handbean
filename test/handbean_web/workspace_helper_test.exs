defmodule HandbeanWeb.WorkspaceHelperTest do
  @moduledoc """
  Tests for HandbeanWeb.WorkspaceHelper — pure template helper functions
  extracted from HandbeanWeb.WorkspaceLive.
  """

  use ExUnit.Case, async: true

  alias HandbeanWeb.WorkspaceHelper

  # ── Setup for file-based tests ──

  setup do
    ws_root = Handbean.Workspace.ensure_root!()
    {:ok, ws_root: ws_root}
  end

  describe "presentation helper input normalization" do
    test "status classes use the idle fallback for unknown inputs" do
      assert WorkspaceHelper.status_dot_class(:unknown) == WorkspaceHelper.status_dot_class(:idle)

      assert WorkspaceHelper.status_dot_class("anything") ==
               WorkspaceHelper.status_dot_class(:idle)
    end

    test "tool icons normalize atom and string statuses and share an unknown fallback" do
      for status <- [:running, :done, :error] do
        assert WorkspaceHelper.tool_status_icon(status) ==
                 WorkspaceHelper.tool_status_icon(Atom.to_string(status))
      end

      assert WorkspaceHelper.tool_status_icon(:unknown) == WorkspaceHelper.tool_status_icon(nil)
    end

    test "tool classes normalize atom and string statuses" do
      for status <- [:running, :done, :error] do
        assert WorkspaceHelper.tool_status_class(status) ==
                 WorkspaceHelper.tool_status_class(Atom.to_string(status))
      end
    end
  end

  # ── render_tool_status/1 ──

  describe "render_tool_status/1" do
    test "returns 'running' for running atom" do
      assert WorkspaceHelper.render_tool_status(:running) == "running"
    end

    test "returns 'done' for done atom" do
      assert WorkspaceHelper.render_tool_status(:done) == "done"
    end

    test "returns 'error' for error atom" do
      assert WorkspaceHelper.render_tool_status(:error) == "error"
    end

    test "returns 'running' for running string" do
      assert WorkspaceHelper.render_tool_status("running") == "running"
    end

    test "returns 'done' for done string" do
      assert WorkspaceHelper.render_tool_status("done") == "done"
    end

    test "returns 'error' for error string" do
      assert WorkspaceHelper.render_tool_status("error") == "error"
    end

    test "returns empty string for unknown" do
      assert WorkspaceHelper.render_tool_status(:unknown) == ""
    end
  end

  # ── tool_entry_count/1 ──

  describe "tool_entry_count/1" do
    test "counts tool entries in a list" do
      entries = [
        %{"content_type" => "tool", "tool" => "read"},
        %{"content_type" => "assistant_msg", "content" => "hello"},
        %{"content_type" => "tool", "tool" => "edit"},
        %{"content_type" => "user_msg", "content" => "hi"},
        %{:content_type => "tool", :tool => "write"}
      ]

      assert WorkspaceHelper.tool_entry_count(entries) == 3
    end

    test "returns 0 for empty list" do
      assert WorkspaceHelper.tool_entry_count([]) == 0
    end

    test "returns 0 for non-list input" do
      assert WorkspaceHelper.tool_entry_count(nil) == 0
      assert WorkspaceHelper.tool_entry_count(%{}) == 0
    end
  end

  # ── timeline_summary/1 ──

  describe "timeline_summary/1" do
    test "returns first non-empty content truncated to 80 chars" do
      entries = [
        %{"content_type" => "tool", "tool" => "read"},
        %{"content" => "short"},
        %{"content" => "this should not appear"}
      ]

      assert WorkspaceHelper.timeline_summary(entries) == "short"
    end

    test "returns truncated content for long messages" do
      long = String.duplicate("a", 100)
      entries = [%{"content" => long}]

      assert WorkspaceHelper.timeline_summary(entries) == String.slice(long, 0, 80)
    end

    test "returns empty string when no content found" do
      entries = [
        %{"content_type" => "tool", "tool" => "read"},
        %{"content_type" => "tool", "tool" => "edit"}
      ]

      assert WorkspaceHelper.timeline_summary(entries) == ""
    end

    test "returns empty string for empty list" do
      assert WorkspaceHelper.timeline_summary([]) == ""
    end

    test "returns empty string for non-list input" do
      assert WorkspaceHelper.timeline_summary(nil) == ""
    end

    test "finds content from atom-keyed entries" do
      entries = [
        %{content: "from atom key"},
        %{"content" => "from string key"}
      ]

      assert WorkspaceHelper.timeline_summary(entries) == "from atom key"
    end

    test "skips entries with empty content" do
      entries = [
        %{"content" => ""},
        %{"content" => "actual content"}
      ]

      assert WorkspaceHelper.timeline_summary(entries) == "actual content"
    end
  end

  describe "user_message_nav_items/1" do
    test "keeps only user messages with 1-based indexes and truncated summaries" do
      long = String.duplicate("问", 50)

      items =
        WorkspaceHelper.user_message_nav_items([
          %{"id" => "u1", "content_type" => "user_msg", "content" => "第一轮"},
          %{"id" => "a1", "content_type" => "assistant_msg", "content" => "助手回复"},
          %{"id" => "t1", "content_type" => "tool", "content" => "read README"},
          %{"id" => "u2", "content_type" => "user_msg", "content" => long},
          %{id: "u3", content_type: "user_msg", content: "atom keyed"}
        ])

      assert Enum.map(items, & &1.id) == ["u1", "u2", "u3"]
      assert Enum.map(items, & &1.index) == [1, 2, 3]
      assert hd(items).summary == "第一轮"
      assert hd(items).age == ""
      assert Enum.at(items, 1).summary == String.duplicate("问", 36) <> "…"
      assert List.last(items).summary == "atom keyed"
    end

    test "uses image or empty fallbacks and skips entries without ids" do
      items =
        WorkspaceHelper.user_message_nav_items([
          %{"content_type" => "user_msg", "content" => "no id"},
          %{
            "id" => "img",
            "content_type" => "user_msg",
            "content" => "  ",
            "attachments" => [%{}]
          },
          %{"id" => "empty", "content_type" => "user_msg", "content" => ""}
        ])

      assert Enum.map(items, &{&1.id, &1.summary}) == [
               {"img", "(image)"},
               {"empty", "(empty message)"}
             ]
    end

    test "formats the message age on the right of the navigator" do
      now = DateTime.utc_now() |> DateTime.add(-7 * 60, :second) |> DateTime.to_iso8601()

      [item] =
        WorkspaceHelper.user_message_nav_items([
          %{"id" => "u1", "content_type" => "user_msg", "content" => "问时间", "created_at" => now}
        ])

      assert item.age == "7m ago"
    end

    test "returns empty list for non-lists" do
      assert WorkspaceHelper.user_message_nav_items(nil) == []
    end
  end

  # ── tool work collapse ──

  describe "tool_work_kind/1" do
    test "classifies file, search, and command tools" do
      assert WorkspaceHelper.tool_work_kind("read") == :file
      assert WorkspaceHelper.tool_work_kind("write") == :file
      assert WorkspaceHelper.tool_work_kind("grep") == :search
      assert WorkspaceHelper.tool_work_kind("file_search") == :search
      assert WorkspaceHelper.tool_work_kind("code_search") == :search
      assert WorkspaceHelper.tool_work_kind("bash") == :command
    end
  end

  describe "browser_install_prompt/1" do
    test "returns the install card for missing-binary browser results" do
      prompt =
        WorkspaceHelper.browser_install_prompt(%{
          "tool" => "browser",
          "details" => %{"failure_category" => "missing-binary"}
        })

      assert prompt.command == Handbean.Browser.InstallPrompt.command()
      assert prompt.title =~ "agent-browser"
    end

    test "returns nil for ordinary tool errors" do
      assert WorkspaceHelper.browser_install_prompt(%{
               "tool" => "bash",
               "error" => "Permission denied"
             }) == nil
    end
  end

  describe "tool_work_summary/1" do
    test "builds Amp-style explored summaries" do
      tools = [
        %{"content_type" => "tool", "tool" => "read"},
        %{"content_type" => "tool", "tool" => "grep"},
        %{"content_type" => "tool", "tool" => "file_search"}
      ]

      assert WorkspaceHelper.tool_work_summary(tools) == "Explored 1 file, 2 searches"
    end

    test "summarizes commands" do
      tools = [%{"content_type" => "tool", "tool" => "bash"}]
      assert WorkspaceHelper.tool_work_summary(tools) == "Ran 1 command"
    end

    test "includes edits and creates separately from exploration" do
      tools = [
        %{"tool" => "read"},
        %{"tool" => "grep"},
        %{"tool" => "bash"},
        %{
          "tool" => "edit",
          "tool_status" => "done",
          "input" => %{"file_path" => "lib/app.ex"},
          "diff_lines" => [%{type: :ins, text: "new"}, %{type: :del, text: "old"}]
        },
        %{
          "tool" => "write",
          "tool_status" => "done",
          "details" => %{
            "change" => %{
              "file_path" => "lib/new.ex",
              "diff_lines" => [%{"type" => "add", "text" => "created"}]
            }
          }
        }
      ]

      assert WorkspaceHelper.tool_work_summary(tools) ==
               "Edited 2 files (+2 -1), Explored 1 file, 1 search, 1 command"
    end

    test "counts repeated edited paths once and sums the visible recorded diffs" do
      edit = %{
        "tool_name" => "edit",
        "tool_status" => "done",
        "change" => %{
          "file_path" => "lib/app.ex",
          "diff_lines" => [%{"type" => "add", "text" => "new"}]
        }
      }

      assert WorkspaceHelper.tool_work_summary([edit, edit]) == "Edited 1 file (+2 -0)"
    end

    test "does not count failed changes as edited files" do
      tools = [
        %{"tool" => "edit", "status" => :error, "input" => %{"file_path" => "missing"}}
      ]

      assert WorkspaceHelper.tool_work_summary(tools) == "Used 1 action"
    end

    test "shows edited paths without inventing line counts for unavailable diffs" do
      tools = [%{"tool" => "edit", "input" => %{"file_path" => "lib/app.ex"}}]
      assert WorkspaceHelper.tool_work_summary(tools) == "Edited 1 file"
    end

    test "translates the edit summary" do
      Gettext.with_locale(Handbean.Gettext, "zh_CN", fn ->
        assert WorkspaceHelper.tool_work_summary([%{"tool" => "write"}]) == "已编辑 1 个文件"
      end)
    end

    test "returns empty string for no tools" do
      assert WorkspaceHelper.tool_work_summary([]) == ""
    end
  end

  describe "apply_tool_work_collapse/2" do
    test "collapses a completed consecutive tool streak" do
      entries = [
        %{"id" => "u1", "content_type" => "user_msg", "content" => "go"},
        %{
          "id" => "t1",
          "content_type" => "tool",
          "tool" => "read",
          "tool_status" => "done"
        },
        %{
          "id" => "t2",
          "content_type" => "tool",
          "tool" => "grep",
          "status" => :done
        },
        %{"id" => "a1", "content_type" => "assistant_msg", "content" => "ok"}
      ]

      [user, first, second, assistant] = WorkspaceHelper.apply_tool_work_collapse(entries)

      refute Map.get(user, "work_group_id")
      assert first["work_group_id"] == "t1"
      assert first["work_group_first"]
      assert first["work_group_complete"]
      assert first["work_collapsed"]
      assert first["work_summary"] == "Explored 1 file, 1 search"
      assert second["work_group_id"] == "t1"
      refute second["work_group_first"]
      assert second["work_collapsed"]
      refute Map.get(assistant, "work_group_id")
    end

    test "keeps a running streak expanded" do
      entries = [
        %{"id" => "t1", "content_type" => "tool", "tool" => "read", "tool_status" => "done"},
        %{"id" => "t2", "content_type" => "tool", "tool" => "bash", "tool_status" => "running"}
      ]

      [first, second] = WorkspaceHelper.apply_tool_work_collapse(entries)
      refute first["work_collapsed"]
      refute second["work_collapsed"]
      refute first["work_group_complete"]
    end

    test "keeps prior rows stable while appending to an active tool streak" do
      first_two = [
        %{"id" => "t1", "content_type" => "tool", "tool" => "read", "tool_status" => "done"},
        %{"id" => "t2", "content_type" => "tool", "tool" => "grep", "tool_status" => "done"}
      ]

      projected =
        WorkspaceHelper.apply_tool_work_collapse(
          first_two,
          MapSet.new(),
          trailing_open?: true
        )

      appended =
        WorkspaceHelper.apply_tool_work_collapse(
          first_two ++
            [
              %{
                "id" => "t3",
                "content_type" => "tool",
                "tool" => "bash",
                "tool_status" => "running"
              }
            ],
          MapSet.new(),
          trailing_open?: true
        )

      assert Enum.take(appended, 2) == projected
      assert Enum.all?(appended, &(not &1["work_group_complete"]))
      assert Enum.all?(appended, &(not &1["work_collapsed"]))
    end

    test "expands a completed group when its id is in the set" do
      entries = [
        %{"id" => "t1", "content_type" => "tool", "tool" => "read", "tool_status" => "done"}
      ]

      [first] = WorkspaceHelper.apply_tool_work_collapse(entries, MapSet.new(["t1"]))
      assert first["work_group_complete"]
      refute first["work_collapsed"]
    end

    test "tool detail labels stay untranslated in Chinese and English" do
      for locale <- ["zh_CN", "en"] do
        Gettext.with_locale(Handbean.Gettext, locale, fn ->
          for {tool, label} <- [
                {"read", "read"},
                {"read_file", "read"},
                {"edit", "edit"},
                {"apply_patch", "edit"},
                {"write", "Created"},
                {"grep", "Grep"},
                {"rg", "Grep"},
                {"file_search", "Searched files"},
                {"glob", "Searched files"},
                {"code_search", "Searched"},
                {"semantic_search", "Searched"},
                {"list_dir", "List"},
                {"bash", "$"},
                {"web_fetch", "web_fetch"},
                {"browser", "browser"},
                {"mem_recall", "mem_recall"}
              ] do
            [entry] =
              WorkspaceHelper.apply_tool_work_collapse([
                %{"id" => "t1", "content_type" => "tool", "tool" => tool, "tool_status" => "done"}
              ])

            assert entry["work_verb"] == label
          end
        end)
      end
    end

    test "nests reads and searches one step past edits and commands" do
      entries = [
        %{
          "id" => "t1",
          "content_type" => "tool",
          "tool_name" => "read",
          "tool_status" => "done",
          "input" => %{"file_path" => "lib/app.ex", "offset" => 1, "limit" => 40}
        },
        %{
          "id" => "t2",
          "content_type" => "tool",
          "tool_name" => "grep",
          "tool_status" => "done",
          "input" => %{"path" => "lib", "pattern" => "def run"}
        },
        %{
          "id" => "t3",
          "content_type" => "tool",
          "tool_name" => "edit",
          "tool_status" => "done",
          "input" => %{"file_path" => "lib/app.ex"}
        },
        %{
          "id" => "t4",
          "content_type" => "tool",
          "tool_name" => "bash",
          "tool_status" => "done",
          "input" => %{"command" => "mix test"}
        }
      ]

      [read, grep, edit, bash] = WorkspaceHelper.apply_tool_work_collapse(entries)

      assert read["work_verb"] == "read"
      assert read["work_target"] == "lib/app.ex L1-40"
      assert grep["work_verb"] == "Grep"
      assert grep["work_target"] == "lib \"def run\""
      assert edit["work_verb"] == "edit"
      assert edit["work_target"] == "lib/app.ex"
      assert bash["work_verb"] == "$"
      assert bash["work_target"] == "mix test"
    end
  end

  # ── format_duration/1 ──

  describe "format_duration/1" do
    test "returns nil for nil" do
      assert WorkspaceHelper.format_duration(nil) == nil
    end

    test "returns milliseconds for durations under 1s" do
      assert WorkspaceHelper.format_duration(500) == "500ms"
      assert WorkspaceHelper.format_duration(0) == "0ms"
      assert WorkspaceHelper.format_duration(999) == "999ms"
    end

    test "returns seconds for durations at or above 1s" do
      assert WorkspaceHelper.format_duration(1000) == "1.0s"
      assert WorkspaceHelper.format_duration(1500) == "1.5s"
      assert WorkspaceHelper.format_duration(12_345) == "12.3s"
    end
  end

  test "format_tokens uses decimal units, trims zeros and promotes rounded boundaries" do
    for {tokens, expected} <- [
          {0, "0"},
          {827, "827"},
          {999, "999"},
          {1000, "1K"},
          {1049, "1K"},
          {1050, "1.1K"},
          {5481, "5.5K"},
          {33_261, "33.3K"},
          {999_949, "999.9K"},
          {999_950, "1M"},
          {999_999, "1M"},
          {1_000_000, "1M"},
          {1_049_999, "1M"},
          {1_050_000, "1.1M"},
          {1_200_000, "1.2M"},
          {10_000_000, "10M"}
        ] do
      assert WorkspaceHelper.format_tokens(tokens) == expected
    end
  end

  test "cache rate uses normalized prompt totals and distinguishes cold writes from no activity" do
    assert WorkspaceHelper.format_cache_hit_rate(%{}) == "—"

    assert WorkspaceHelper.format_cache_hit_rate(%{
             total_input_tokens: 0,
             cache_read_tokens: 0,
             cache_write_tokens: 0
           }) == "—"

    assert WorkspaceHelper.format_cache_hit_rate(%{
             total_input_tokens: 100,
             cache_read_tokens: 0,
             cache_write_tokens: 0
           }) == "—"

    assert WorkspaceHelper.format_cache_hit_rate(%{
             total_input_tokens: 100,
             cache_read_tokens: 0,
             cache_write_tokens: 80
           }) == "0.0%"

    assert WorkspaceHelper.format_cache_hit_rate(%{
             total_input_tokens: 100,
             cache_read_tokens: 100,
             cache_write_tokens: 0
           }) == "100.0%"

    assert WorkspaceHelper.format_cache_hit_rate(%{
             total_input_tokens: 300,
             cache_read_tokens: 100,
             cache_write_tokens: 0
           }) == "33.3%"

    assert WorkspaceHelper.format_cache_hit_rate(%{
             total_input_tokens: 1000,
             cache_read_tokens: 180,
             cache_write_tokens: 750
           }) == "18.0%"

    assert WorkspaceHelper.format_cache_hit_rate(%{
             total_input_tokens: :unknown,
             cache_read_tokens: 180,
             cache_write_tokens: 0
           }) == "—"

    assert WorkspaceHelper.format_cache_hit_rate(%{
             total_input_tokens: 1000,
             cache_read_tokens: 180,
             cache_write_tokens: 0,
             usage_incomplete: true
           }) == "—"
  end

  # ── format_bytes/1 ──

  describe "format_bytes/1" do
    test "returns '0 B' for nil" do
      assert WorkspaceHelper.format_bytes(nil) == "0 B"
    end

    test "returns bytes for values under 1 KB" do
      assert WorkspaceHelper.format_bytes(0) == "0 B"
      assert WorkspaceHelper.format_bytes(512) == "512 B"
      assert WorkspaceHelper.format_bytes(1023) == "1023 B"
    end

    test "returns KB for values between 1 KB and 1 MB" do
      assert WorkspaceHelper.format_bytes(1024) == "1.0 KB"
      assert WorkspaceHelper.format_bytes(1536) == "1.5 KB"
      assert WorkspaceHelper.format_bytes(1_048_575) == "1024.0 KB"
    end

    test "returns MB for values at or above 1 MB" do
      assert WorkspaceHelper.format_bytes(1_048_576) == "1.0 MB"
      assert WorkspaceHelper.format_bytes(5_242_880) == "5.0 MB"
    end
  end

  # ── diff_prefix/1 ──

  describe "diff_prefix/1" do
    test "returns '+' for insertion" do
      assert WorkspaceHelper.diff_prefix("ins") == "+"
    end

    test "returns '-' for deletion" do
      assert WorkspaceHelper.diff_prefix("del") == "-"
    end

    test "returns ' ' for eq" do
      assert WorkspaceHelper.diff_prefix("eq") == " "
    end

    test "returns '⋯' for skip" do
      assert WorkspaceHelper.diff_prefix("skip") == "⋯"
    end

    test "returns ' ' for unknown types" do
      assert WorkspaceHelper.diff_prefix("unknown") == " "
      assert WorkspaceHelper.diff_prefix(nil) == " "
    end
  end

  # ── file_value/3 ──

  describe "file_value/3" do
    test "reads atom key from map" do
      map = %{path: "/some/file.ex", name: "file.ex"}
      assert WorkspaceHelper.file_value(map, :path, nil) == "/some/file.ex"
      assert WorkspaceHelper.file_value(map, :name, nil) == "file.ex"
    end

    test "reads string key from map" do
      map = %{"path" => "/some/file.ex", "name" => "file.ex"}
      assert WorkspaceHelper.file_value(map, "path", nil) == "/some/file.ex"
    end

    test "falls back to string key when atom key missing" do
      map = %{"path" => "/other/file.ex"}
      assert WorkspaceHelper.file_value(map, :path, nil) == "/other/file.ex"
    end

    test "returns default when key not found" do
      map = %{}
      assert WorkspaceHelper.file_value(map, :path, "/default") == "/default"
    end
  end

  # ── archived_stream_count/1 ──

  describe "archived_stream_count/1" do
    test "counts archived conversations in stream entries" do
      entries = [
        {1, %{archived: true}},
        {2, %{archived: false}},
        {3, %{archived: true}},
        {4, %{archived: false}}
      ]

      assert WorkspaceHelper.archived_stream_count(entries) == 2
    end

    test "returns 0 for empty list" do
      assert WorkspaceHelper.archived_stream_count([]) == 0
    end

    test "returns 0 for non-list input" do
      assert WorkspaceHelper.archived_stream_count(nil) == 0
    end

    test "returns 0 when no archived entries" do
      entries = [
        {1, %{archived: false}},
        {2, %{archived: false}}
      ]

      assert WorkspaceHelper.archived_stream_count(entries) == 0
    end
  end

  # ── render_file_preview/2 ──

  describe "render_file_preview/2" do
    test "returns empty string for nil path", %{ws_root: ws_root} do
      assert WorkspaceHelper.render_file_preview(nil) == ""
      assert WorkspaceHelper.render_file_preview(nil, ws_root) == ""
    end

    test "returns escaped content for workspace file", %{ws_root: ws_root} do
      tmp = Path.join(ws_root, "helper_test_preview.txt")
      File.write!(tmp, "hello\nworld")

      try do
        result = WorkspaceHelper.render_file_preview(tmp)
        assert result =~ "hello"
        assert result =~ "world"
      after
        File.rm(tmp)
      end
    end

    test "escapes HTML in preview content", %{ws_root: ws_root} do
      tmp = Path.join(ws_root, "helper_test_html.txt")
      File.write!(tmp, "<script>alert('xss')</script>")

      try do
        result = WorkspaceHelper.render_file_preview(tmp)
        assert result =~ "&lt;script&gt;"
        refute result =~ "<script>"
      after
        File.rm(tmp)
      end
    end

    test "truncates content to 10_000 chars", %{ws_root: ws_root} do
      tmp = Path.join(ws_root, "helper_test_large.txt")
      large = String.duplicate("x", 20_000)
      File.write!(tmp, large)

      try do
        result = WorkspaceHelper.render_file_preview(tmp)
        assert String.length(result) == 10_000
      after
        File.rm(tmp)
      end
    end

    test "does not return invalid UTF-8 for a binary file", %{ws_root: ws_root} do
      path = Path.join(ws_root, "helper_test.db-shm")
      File.write!(path, <<0, 0xFF, "sqlite">>)

      try do
        result = WorkspaceHelper.render_file_preview(path, ws_root)
        assert result == "[Binary file preview unavailable]"
        assert String.valid?(result)
        assert WorkspaceHelper.file_preview_error(path, ws_root) =~ "Binary files"
      after
        File.rm(path)
      end
    end

    test "returns access denied for file outside workspace", %{ws_root: ws_root} do
      result = WorkspaceHelper.render_file_preview("/etc/passwd", ws_root)
      assert result =~ "Access denied"
    end

    test "returns access denied when using default workspace for non-workspace file" do
      result = WorkspaceHelper.render_file_preview("/etc/passwd")
      assert result =~ "Access denied"
    end

    test "allows file in custom workspace_root", %{ws_root: _ws_root} do
      custom_dir =
        Path.join(System.tmp_dir!(), "sigil_helper_custom_#{System.unique_integer([:positive])}")

      File.mkdir_p!(custom_dir)

      file_path = Path.join(custom_dir, "custom.exs")
      File.write!(file_path, "defmodule Custom do\n  def run, do: :custom\nend")

      try do
        # With global workspace root — access denied
        result1 = WorkspaceHelper.render_file_preview(file_path)
        assert result1 =~ "Access denied"

        # With custom workspace root — works
        result2 = WorkspaceHelper.render_file_preview(file_path, custom_dir)
        assert result2 =~ "defmodule Custom do"
        assert result2 =~ ":custom"
      after
        File.rm_rf!(custom_dir)
      end
    end

    test "returns error message for non-existent file", %{ws_root: ws_root} do
      result =
        WorkspaceHelper.render_file_preview("/nonexistent/path.txt", ws_root)

      assert result =~ "Access denied"
    end
  end

  # ── Edge cases / regression ──

  describe "edge cases" do
    test "tool_entry_count handles map keys that are atoms" do
      entries = [
        %{content_type: "tool", tool: "read"},
        %{:content_type => "tool", :tool => "write"}
      ]

      assert WorkspaceHelper.tool_entry_count(entries) == 2
    end

    test "format_bytes handles edge values precisely" do
      assert WorkspaceHelper.format_bytes(1) == "1 B"
      assert WorkspaceHelper.format_bytes(1024) == "1.0 KB"
      assert WorkspaceHelper.format_bytes(1_048_576) == "1.0 MB"
    end

    test "all helpers are deterministic" do
      # Run each helper twice, assert same result
      for _ <- 1..2 do
        assert WorkspaceHelper.format_duration(1500) == "1.5s"
        assert WorkspaceHelper.format_bytes(2048) == "2.0 KB"
        assert WorkspaceHelper.diff_prefix("ins") == "+"
        assert WorkspaceHelper.tool_entry_count([]) == 0
        assert WorkspaceHelper.timeline_summary([]) == ""
        assert WorkspaceHelper.render_tool_status(:running) == "running"
      end
    end
  end
end
