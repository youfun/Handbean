defmodule ExFff.SearchQualityTest do
  use ExUnit.Case, async: false

  alias ExFff.Index

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "ex_fff_quality_#{System.unique_integer([:positive])}")

    files = [
      "assets/js/hooks/conversation_context_menu.js",
      "lib/conversation_store.ex",
      "lib/conversation_context.ex",
      "lib/conversation_hot.ex",
      "assets/js/hooks/conversation_context_menu.js.bak",
      "test/support/data_case.ex",
      "lib/data_case_helper.ex",
      "lib/handbean/security/path_validator.ex",
      "docs/schedule-plan.md",
      "docs/schedule-plan.md.backup",
      "priv/repo/migrations/20260718000000_create_schedules.exs",
      "schedules/readme.md",
      "desktop/macos/ui/ConversationPanel.swift",
      "desktop/macos/Other.swift",
      "desktop/linux/ConversationPanel.swift",
      "desktop/macos/Sources/WebView.swift",
      "desktop/macos/Sources/ConversationWebView.swift",
      "lib/handbean_web/components/sidebar_components.ex",
      "assets/images/icon_20.png"
    ]

    for relative <- files do
      path = Path.join(tmp_dir, relative)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, relative)
    end

    name =
      Module.concat(ExFff.Index, String.to_atom("Quality_#{System.unique_integer([:positive])}"))

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

    {:ok, pid: pid, name: name}
  end

  test "exact filename outranks hot fuzzy conversation files", %{pid: pid, name: name} do
    boost(pid, "lib/conversation_hot.ex")
    boost(pid, "lib/conversation_store.ex")
    boost(pid, "lib/conversation_context.ex")
    boost(pid, "assets/js/hooks/conversation_context_menu.js.bak")
    boost(pid, "assets/images/icon_20.png")

    paths = search_paths(name, "conversation_context_menu.js")

    assert hd(paths) == "assets/js/hooks/conversation_context_menu.js"
    refute "assets/images/icon_20.png" in paths
  end

  test "data_case.ex ranks above a hot filename that only contains the stem", %{
    pid: pid,
    name: name
  } do
    boost(pid, "lib/data_case_helper.ex")
    boost(pid, "lib/handbean/security/path_validator.ex")

    paths = search_paths(name, "data_case.ex")

    assert hd(paths) == "test/support/data_case.ex"
    assert Enum.find_index(paths, &(&1 == "lib/data_case_helper.ex")) > 0
  end

  test "schedule-plan.md ranks above a hot path that merely contains the name", %{
    pid: pid,
    name: name
  } do
    boost(pid, "docs/schedule-plan.md.backup")

    paths = search_paths(name, "schedule-plan.md")

    assert hd(paths) == "docs/schedule-plan.md"
    assert Enum.find_index(paths, &(&1 == "docs/schedule-plan.md.backup")) > 0
  end

  test "basename contains-glob hits create_schedules and not a schedules directory", %{name: name} do
    paths = search_paths(name, "*schedules*")

    assert "priv/repo/migrations/20260718000000_create_schedules.exs" in paths
    refute "schedules/readme.md" in paths
  end

  test "path glob combined with a directory term hits Conversation files under desktop/macos",
       %{name: name} do
    paths = search_paths(name, "desktop/macos **/*Conversation*")

    assert "desktop/macos/ui/ConversationPanel.swift" in paths
    refute "desktop/macos/Other.swift" in paths

    macos = Enum.find_index(paths, &(&1 == "desktop/macos/ui/ConversationPanel.swift"))
    linux = Enum.find_index(paths, &(&1 == "desktop/linux/ConversationPanel.swift"))
    if linux, do: assert(macos < linux)
  end

  test "*.ex stays a suffix filter", %{name: name} do
    paths = search_paths(name, "*.ex")

    assert "test/support/data_case.ex" in paths
    assert "lib/conversation_store.ex" in paths
    refute Enum.any?(paths, &(not String.ends_with?(&1, ".ex")))
    refute "priv/repo/migrations/20260718000000_create_schedules.exs" in paths
  end

  test "a basename glob retries the full path, but a wrong extension stays empty", %{name: name} do
    assert {:ok, hit} = Index.search(name, "desktop*webview*", limit: 20)
    paths = Enum.map(hit.paths, & &1.path)

    assert "desktop/macos/Sources/WebView.swift" in paths
    assert Enum.all?(hit.paths, &(&1.tier == :path))
    assert hit.partial_match == nil

    assert {:ok, missed} = Index.search(name, "sidebar*.heex", limit: 20)
    assert missed.paths == []
  end

  test "an empty multi-term AND falls back to OR coverage", %{name: name} do
    assert {:ok, result} = Index.search(name, "conversation webview schedules", limit: 20)

    assert result.partial_match == %{matched: 2, total: 3}
    assert hd(result.paths).path == "desktop/macos/Sources/ConversationWebView.swift"
    assert hd(result.paths).matched_terms == 2

    paths = Enum.map(result.paths, & &1.path)
    assert "priv/repo/migrations/20260718000000_create_schedules.exs" in paths

    assert Enum.find_index(
             paths,
             &(&1 == "priv/repo/migrations/20260718000000_create_schedules.exs")
           ) >
             0
  end

  test "a successful AND does not report a partial match", %{name: name} do
    assert {:ok, result} = Index.search(name, "conversation store", limit: 20)
    assert result.partial_match == nil
    assert hd(result.paths).tier == :filename
  end

  defp search_paths(name, query) do
    assert {:ok, result} = Index.search(name, query, limit: 50)
    Enum.map(result.paths, & &1.path)
  end

  defp boost(pid, path) do
    state = :sys.get_state(pid)
    :ets.match_delete(state.frecency_ref, {{:_, path}, :_})
    :ets.insert(state.frecency_ref, {{10_000.0, path}, true})
    :ets.insert(state.git_ref, {path, :modified})
  end
end
