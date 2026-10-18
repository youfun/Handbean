defmodule HandbeanProbe.NativeFolderBrowserTest do
  use ExUnit.Case, async: true

  alias HandbeanProbe.NativeFolderBrowser

  setup do
    base = Path.join(System.tmp_dir!(), "nfb_#{System.unique_integer([:positive])}")
    root = Path.join(base, "ws")
    File.mkdir_p!(Path.join(root, "sub/inner"))
    on_exit(fn -> File.rm_rf!(base) end)
    %{base: base, root: root}
  end

  test "accepts the root and real subdirectories", %{root: root} do
    assert NativeFolderBrowser.allowed?(root, root)
    assert NativeFolderBrowser.allowed?(Path.join(root, "sub"), root)
    assert NativeFolderBrowser.allowed?(Path.join(root, "sub/inner"), root)

    browser = NativeFolderBrowser.start(root)
    assert Enum.map(browser.entries, & &1.name) == ["sub"]

    entered = NativeFolderBrowser.action({:enter, "sub"}, browser)
    assert entered.path == Path.join(root, "sub")
    assert {:select, selected} = NativeFolderBrowser.action(:select, entered)
    assert selected == Path.join(root, "sub")
  end

  test "lazy start defers listing to list/2 and put_entries/3", %{root: root} do
    browser = NativeFolderBrowser.start(root, lazy: true)
    assert browser.entries == []
    assert NativeFolderBrowser.loading?(browser)

    entries = NativeFolderBrowser.list(browser.path, browser.root)
    assert Enum.map(entries, & &1.name) == ["sub"]

    loaded = NativeFolderBrowser.put_entries(browser, browser.path, entries)
    refute NativeFolderBrowser.loading?(loaded)
    assert loaded.entries == entries

    # A stale listing for another path is ignored; navigation stays lazy.
    entered = NativeFolderBrowser.action({:enter, "sub"}, loaded)
    assert NativeFolderBrowser.loading?(entered)
    assert NativeFolderBrowser.put_entries(entered, root, entries) == entered
  end

  test "rejects a sibling whose name shares the root prefix", %{base: base, root: root} do
    sibling = Path.join(base, "ws2")
    File.mkdir_p!(Path.join(sibling, "x"))

    refute NativeFolderBrowser.allowed?(sibling, root)
    refute NativeFolderBrowser.allowed?(Path.join(sibling, "x"), root)
    refute NativeFolderBrowser.allowed?(root <> "2", root)
  end

  test "rejects .. traversal and absolute escapes", %{root: root} do
    refute NativeFolderBrowser.allowed?(Path.join(root, "sub/../.."), root)
    refute NativeFolderBrowser.allowed?("/etc", root)

    browser = NativeFolderBrowser.start(root)
    assert NativeFolderBrowser.action({:enter, ".."}, browser) == browser
    assert NativeFolderBrowser.action(:up, browser).path == root
  end

  test "rejects a symlink that points outside the root", %{base: base, root: root} do
    outside = Path.join(base, "outside")
    File.mkdir_p!(outside)
    link = Path.join(root, "escape")
    File.ln_s!(outside, link)

    assert File.dir?(link)
    refute NativeFolderBrowser.allowed?(link, root)

    browser = NativeFolderBrowser.start(root)
    refute "escape" in Enum.map(browser.entries, & &1.name)
    assert NativeFolderBrowser.action({:enter, "escape"}, browser) == browser
  end
end
