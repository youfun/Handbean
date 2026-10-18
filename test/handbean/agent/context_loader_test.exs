defmodule Handbean.Agent.ContextLoaderTest do
  use ExUnit.Case, async: true

  alias Handbean.Agent.ContextLoader

  # ── Helpers ──

  defp write_file(path, content) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, content)
  end

  defp mark_project_root(dir) do
    # Present so older fixtures still look like a Mix project. Discovery
    # must not treat this file as a walk boundary.
    write_file(Path.join(dir, "mix.exs"), "# project root marker")
  end

  # ── discover/1 ──

  @tag :tmp_dir
  test "discover/1 returns AGENTS.md paths sorted by depth (shallow first, deep last)", %{
    tmp_dir: tmp_dir
  } do
    # Create nested structure:
    #   tmp_dir/AGENTS.md             (depth 0 — root)
    #   tmp_dir/sub1/AGENTS.md         (depth 1)
    #   tmp_dir/sub1/sub2/AGENTS.md    (depth 2) ← cwd
    root = tmp_dir
    sub1 = Path.join(root, "sub1")
    sub2 = Path.join(sub1, "sub2")

    mark_project_root(root)
    write_file(Path.join(root, "AGENTS.md"), "# root")
    write_file(Path.join(sub1, "AGENTS.md"), "# sub1")
    write_file(Path.join(sub2, "AGENTS.md"), "# sub2")

    paths = ContextLoader.discover(sub2)

    owned = [
      Path.join(root, "AGENTS.md"),
      Path.join(sub1, "AGENTS.md"),
      Path.join(sub2, "AGENTS.md")
    ]

    assert owned -- paths == []
    assert Enum.filter(paths, &(&1 in owned)) == owned
    assert List.last(paths) == Path.join(sub2, "AGENTS.md")
  end

  @tag :tmp_dir
  test "discover/1 returns no file from a directory without AGENTS.md", %{tmp_dir: tmp_dir} do
    mark_project_root(tmp_dir)
    paths = ContextLoader.discover(tmp_dir)
    refute Path.join(tmp_dir, "AGENTS.md") in paths
  end

  @tag :tmp_dir
  test "discover/1 stops at filesystem root", %{tmp_dir: tmp_dir} do
    write_file(Path.join(tmp_dir, "AGENTS.md"), "# root")
    sub = Path.join(tmp_dir, "sub")

    paths = ContextLoader.discover(sub)
    assert Path.join(tmp_dir, "AGENTS.md") in paths
    assert Enum.all?(paths, &String.ends_with?(&1, "AGENTS.md"))
  end

  @tag :tmp_dir
  test "discover/1 does not stop at mix.exs", %{tmp_dir: tmp_dir} do
    tree = Path.join(tmp_dir, "tree")
    above = Path.join(tree, "AGENTS.md")
    project = Path.join(tree, "app")
    nested = Path.join(project, "lib")

    write_file(above, "# above the mix project")
    mark_project_root(project)
    write_file(Path.join(project, "AGENTS.md"), "# mix project")

    paths = ContextLoader.discover(nested)

    assert above in paths
    assert Path.join(project, "AGENTS.md") in paths

    assert Enum.find_index(paths, &(&1 == above)) <
             Enum.find_index(paths, &(&1 == Path.join(project, "AGENTS.md")))

    bounded = ContextLoader.discover(nested, workspace: project)
    refute above in bounded
    assert Path.join(project, "AGENTS.md") in bounded
  end

  @tag :tmp_dir
  test "discover/1 includes AGENTS.md in immediate workspace children", %{tmp_dir: tmp_dir} do
    mobile = Path.join([tmp_dir, "mobile", "AGENTS.md"])
    nested = Path.join([tmp_dir, "mobile", "android", "AGENTS.md"])
    hidden = Path.join([tmp_dir, ".handbean", "AGENTS.md"])
    vendor = Path.join([tmp_dir, "deps", "left", "AGENTS.md"])
    outside = Path.join(Path.dirname(tmp_dir), "outside-agents")
    linked = Path.join(outside, "AGENTS.md")

    on_exit(fn -> File.rm_rf(outside) end)
    write_file(Path.join(tmp_dir, "AGENTS.md"), "# root")
    write_file(mobile, "# mobile")
    write_file(nested, "# nested")
    write_file(hidden, "# hidden")
    write_file(vendor, "# vendor")
    write_file(linked, "# linked")
    File.ln_s!(outside, Path.join(tmp_dir, "linked"))

    paths = ContextLoader.discover(tmp_dir, workspace: tmp_dir)

    assert Path.join(tmp_dir, "AGENTS.md") in paths
    assert mobile in paths
    refute nested in paths
    refute hidden in paths
    refute vendor in paths
    refute linked in paths

    assert Enum.find_index(paths, &(&1 == Path.join(tmp_dir, "AGENTS.md"))) <
             Enum.find_index(paths, &(&1 == mobile))
  end

  @tag :tmp_dir
  test "discover/1 sorts by path depth correctly for multiple levels", %{tmp_dir: tmp_dir} do
    root = tmp_dir
    a = Path.join(root, "a")
    b = Path.join(a, "b")
    c = Path.join(b, "c")

    mark_project_root(root)
    write_file(Path.join(root, "AGENTS.md"), "# root")
    # intentionally skip level a
    write_file(Path.join(b, "AGENTS.md"), "# b")
    write_file(Path.join(c, "AGENTS.md"), "# c")

    paths = ContextLoader.discover(c)
    owned = [Path.join(root, "AGENTS.md"), Path.join(b, "AGENTS.md"), Path.join(c, "AGENTS.md")]

    refute Path.join(a, "AGENTS.md") in paths
    assert Enum.filter(paths, &(&1 in owned)) == owned
    assert List.last(paths) == Path.join(c, "AGENTS.md")
  end

  # ── load/1 ──

  @tag :tmp_dir
  test "load/1 reads and merges files with path annotations", %{tmp_dir: tmp_dir} do
    f1 = Path.join(tmp_dir, "root_agents.md")
    f2 = Path.join(tmp_dir, "sub_agents.md")

    write_file(f1, "# Root instructions\nroot content")
    write_file(f2, "# Sub instructions\nsub content")

    {:ok, merged} = ContextLoader.load([f1, f2])

    assert merged =~ "root_agents.md"
    assert merged =~ "# Root instructions"
    assert merged =~ "sub_agents.md"
    assert merged =~ "# Sub instructions"
  end

  @tag :tmp_dir
  test "load/1 returns empty string for empty path list" do
    {:ok, merged} = ContextLoader.load([])
    assert merged == ""
  end

  @tag :tmp_dir
  test "load/1 skips non-existent files with warning, returns ok", %{tmp_dir: tmp_dir} do
    f1 = Path.join(tmp_dir, "exists.md")
    f2 = Path.join(tmp_dir, "does_not_exist.md")

    write_file(f1, "# exists")

    import ExUnit.CaptureLog

    {result, log} = with_log(fn -> ContextLoader.load([f1, f2]) end)

    assert {:ok, merged} = result
    assert merged =~ "# exists"
    assert log =~ ~r/does_not_exist\.md/
    refute merged =~ "does_not_exist"
  end

  @tag :tmp_dir
  test "load/1 skips unreadable files gracefully", %{tmp_dir: tmp_dir} do
    f1 = Path.join(tmp_dir, "readable.md")
    f2 = Path.join(tmp_dir, "unreadable.md")

    write_file(f1, "# readable")

    # Create file then remove read permissions
    write_file(f2, "# secret")
    File.chmod!(f2, 0o000)

    import ExUnit.CaptureLog

    {result, log} = with_log(fn -> ContextLoader.load([f1, f2]) end)

    # Restore permissions so tmp_dir cleanup works
    File.chmod!(f2, 0o644)

    assert {:ok, merged} = result
    assert merged =~ "# readable"
    assert log =~ ~r/unreadable\.md/
    refute merged =~ "secret"
  end

  @tag :tmp_dir
  test "load/1 works when all files fail (returns empty string)", %{tmp_dir: tmp_dir} do
    f = Path.join(tmp_dir, "nope.md")
    # Don't create the file

    import ExUnit.CaptureLog

    {result, _log} = with_log(fn -> ContextLoader.load([f]) end)

    assert {:ok, ""} = result
  end

  # ── truncate/2 ──

  test "truncate/2 returns content unchanged when within limits" do
    content = "short content under 2000 chars"

    {result, truncated?} = ContextLoader.truncate(content)

    assert result == content
    refute truncated?
  end

  test "truncate/2 enforces per-file 2000 char limit with [TRUNCATED] marker" do
    # Create content with 3 "files", each 1000 chars
    file_header = "### From: /path/to/file.md\n"

    # One file at 2500 chars (over 2000 limit)
    long_file_content = String.duplicate("A", 2500)
    long_file = file_header <> long_file_content <> "\n\n"

    # Two normal files at 1000 chars each
    normal1 = file_header <> String.duplicate("B", 1000) <> "\n\n"
    normal2 = file_header <> String.duplicate("C", 1000) <> "\n\n"

    content = normal1 <> long_file <> normal2

    {result, truncated?} = ContextLoader.truncate(content)

    assert truncated?
    assert result =~ "[TRUNCATED: exceeds 2000 chars per file]"
    # The truncated marker should appear in the long file section
    # Long file header should still be present
    assert result =~ "### From: /path/to/file.md"
  end

  test "truncate/2 enforces total 8000 char limit" do
    # Create 5 files of 2000 chars each = 10000 total
    files =
      Enum.map(1..5, fn i ->
        "### From: /path/file#{i}.md\n" <> String.duplicate("#{i}", 2000) <> "\n\n"
      end)

    content = Enum.join(files)

    {result, truncated?} = ContextLoader.truncate(content)

    assert truncated?
    assert result =~ "[TRUNCATED: total exceeds 8000 chars]"
    # Should NOT exceed 8000 bytes
    # small buffer for the marker itself
    assert byte_size(result) <= 8000 + 100
  end

  test "truncate/2 handles content exactly at the limit" do
    # 2000 chars exactly (header is 16 chars: "### From: /a.md\n")
    header = "### From: /a.md\n"
    content = header <> String.duplicate("X", 2000 - String.length(header))

    {result, truncated?} = ContextLoader.truncate(content)

    refute truncated?
    assert result == content
  end

  test "truncate/2 handles empty content" do
    {result, truncated?} = ContextLoader.truncate("")

    assert result == ""
    refute truncated?
  end

  test "truncate/2 supports custom limits via opts" do
    {:ok, _} = Application.ensure_all_started(:handbean)
    content = String.duplicate("A", 500)

    {result, truncated?} = ContextLoader.truncate(content, max_per_file: 100, max_total: 200)

    assert truncated?
    assert result =~ "[TRUNCATED: exceeds"
  end

  # ── inject/2 ──

  test "inject/2 adds AGENTS.md section to system prompt" do
    system_prompt = "You are a coding assistant."
    context = "# Project rules\n- use tabs"

    result = ContextLoader.inject(system_prompt, context)

    assert result =~ system_prompt
    assert result =~ "## Project Instructions (AGENTS.md)"
    assert result =~ "# Project rules"
    assert result =~ "- use tabs"
  end

  test "inject/2 skips injection when context is empty" do
    system_prompt = "You are a coding assistant."

    result = ContextLoader.inject(system_prompt, "")

    assert result == system_prompt
  end

  test "inject/2 skips injection when context is nil" do
    system_prompt = "You are a coding assistant."

    result = ContextLoader.inject(system_prompt, nil)

    assert result == system_prompt
  end

  # ── Integration: discover → load → truncate → inject ──

  @tag :tmp_dir
  test "full pipeline produces valid system prompt", %{tmp_dir: tmp_dir} do
    mark_project_root(tmp_dir)
    sub = Path.join(tmp_dir, "sub")
    write_file(Path.join(tmp_dir, "AGENTS.md"), "# Global rule\n- use Unix line endings")
    write_file(Path.join(sub, "AGENTS.md"), "# Local rule\n- max line length 100")

    paths = ContextLoader.discover(sub)
    {:ok, context} = ContextLoader.load(paths)
    {context, _truncated?} = ContextLoader.truncate(context)

    prompt = ContextLoader.inject("Base system prompt", context)

    assert prompt =~ "Base system prompt"
    assert prompt =~ "## Project Instructions (AGENTS.md)"
    assert prompt =~ "# Global rule"
    assert prompt =~ "# Local rule"
  end
end
