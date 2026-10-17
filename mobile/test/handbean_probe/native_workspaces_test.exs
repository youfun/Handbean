defmodule HandbeanProbe.NativeWorkspacesTest do
  use ExUnit.Case, async: false

  alias Handbean.{ConversationStore, WorkspaceStore}
  alias HandbeanProbe.{NativeFolderBrowser, NativeWorkspaceImport, NativeWorkspaces}

  setup do
    dir = Path.join(System.tmp_dir!(), "native_ws_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    host = Application.get_env(:handbean, :host)
    Handbean.Host.put!(%{data_dir: dir, shell: false, mcp: false})

    vars = %{
      "HANDBEAN_WORKSPACE" => Path.join(dir, "workspace"),
      "HANDBEAN_MODELS_FILE" => Path.join(dir, "models.json"),
      "HANDBEAN_WORKSPACES_FILE" => Path.join(dir, "workspaces.json"),
      "HANDBEAN_GLOBAL_SETTINGS_FILE" => Path.join(dir, "settings.json")
    }

    previous = Map.new(vars, fn {key, _} -> {key, System.get_env(key)} end)
    Enum.each(vars, fn {key, value} -> System.put_env(key, value) end)
    {:ok, default} = WorkspaceStore.ensure_default!()

    on_exit(fn ->
      if host,
        do: Application.put_env(:handbean, :host, host),
        else: Application.delete_env(:handbean, :host)

      Enum.each(previous, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)

      File.rm_rf!(dir)
    end)

    %{dir: dir, default: default}
  end

  test "create empty workspace uses a generated private directory", %{default: default} do
    assert {:error, :blank_name} = NativeWorkspaces.create_empty("   ")
    assert {:ok, created} = NativeWorkspaces.create_empty("中文🙂 / not-a-path")
    assert created["name"] == "中文🙂 / not-a-path"
    assert NativeWorkspaces.owned_path?(created["path"], NativeWorkspaces.created_root())
    refute String.contains?(created["path"], "not-a-path")
    assert File.dir?(created["path"])
    assert created["id"] != default["id"]
    assert ConversationStore.list_for_workspace(created["id"]) == []
  end

  test "create rolls back only the directory from this request" do
    sibling = Path.join(NativeWorkspaces.created_root(), "keep-me")
    File.mkdir_p!(sibling)
    File.write!(Path.join(sibling, "note.txt"), "keep")

    assert {:error, :boom} =
             NativeWorkspaces.create_empty("fails-register",
               register: fn dir, _opts ->
                 send(self(), {:created, dir})
                 {:error, :boom}
               end
             )

    assert_received {:created, created}
    refute File.exists?(created)
    refute Enum.any?(File.ls!(NativeWorkspaces.created_root()), &String.starts_with?(&1, "ws_"))
    assert File.read!(Path.join(sibling, "note.txt")) == "keep"
  end

  test "add accessible folder rejects URIs, files, missing and dangerous paths", %{dir: dir} do
    assert {:error, :not_posix} =
             NativeWorkspaces.add_accessible("content://com.android.ext/tree/1")

    assert {:error, :not_posix} = NativeWorkspaces.add_accessible("file:///tmp/project")
    file = Path.join(dir, "file.txt")
    File.write!(file, "nope")
    assert {:error, reason} = NativeWorkspaces.add_accessible(file)
    assert reason =~ "directory"
    assert {:error, _} = NativeWorkspaces.add_accessible(Path.join(dir, "missing"))
    assert {:error, _} = NativeWorkspaces.add_accessible("/")
  end

  test "symlink aliases resolve to the same workspace", %{dir: dir, default: default} do
    project = Path.join(dir, "project")
    File.mkdir_p!(project)
    {:ok, added} = NativeWorkspaces.add_accessible(project)
    link = Path.join(dir, "project-alias")
    File.ln_s!(project, link)
    {:ok, again} = NativeWorkspaces.add_accessible(link)
    assert again["id"] == added["id"]
    ids = Enum.map(WorkspaceStore.list(), & &1["id"])
    assert length(ids) == length(Enum.uniq(ids))
    assert default["id"] in ids
  end

  test "canonicalize treats the macOS /var alias as /private/var" do
    if File.dir?("/private/var") do
      assert NativeWorkspaces.canonicalize("/var") ==
               Handbean.Security.PathValidator.resolve_symlink("/private/var")
    end
  end

  test "folder browser stays under the app root", %{dir: dir} do
    nested = Path.join(dir, "a/b")
    File.mkdir_p!(nested)
    browser = NativeFolderBrowser.start(dir)
    browser = NativeFolderBrowser.action({:enter, "a"}, browser)
    assert browser.path == Path.join(dir, "a")
    assert {:select, path} = NativeFolderBrowser.action(:select, browser)
    assert path == Path.join(dir, "a")
    refute NativeFolderBrowser.allowed?(Path.expand("/etc"), dir)
    up = NativeFolderBrowser.action(:up, NativeFolderBrowser.start(dir))
    assert up.path == dir
  end

  test "import registers a committed receipt once; cancel and late receipts do not", %{dir: dir} do
    # Android (WorkspaceImport.kt) owns the copy; Elixir receives the committed path.
    dest = Path.join(NativeWorkspaces.imported_root(), "imp_ok")
    File.mkdir_p!(Path.join(dest, "sub"))
    File.write!(Path.join(dest, "sub/readme.md"), "from-source")
    outsider = Path.join(dir, "outsider.txt")
    File.write!(outsider, "leave")

    request = %{request_id: "imp_ok", status: :picking}

    {:ok, workspace, idle} =
      NativeWorkspaceImport.handle_picked(request, [
        %{path: dest, name: "Src", request_id: "imp_ok"}
      ])

    assert idle.status == :idle
    assert workspace["name"] == "Src"
    assert File.read!(Path.join(dest, "sub/readme.md")) == "from-source"
    assert length(Enum.filter(WorkspaceStore.list(), &(&1["id"] == workspace["id"]))) == 1

    cancelled = NativeWorkspaceImport.cancel(%{request_id: "imp_late", status: :picking})
    late_dir = Path.join(NativeWorkspaces.imported_root(), "imp_late")
    File.mkdir_p!(late_dir)
    File.write!(Path.join(late_dir, "x.txt"), "late")

    {:ignored, _} =
      NativeWorkspaceImport.handle_picked(cancelled, [
        %{path: late_dir, name: "Late", request_id: "imp_late"}
      ])

    refute File.dir?(late_dir)
    refute Enum.any?(WorkspaceStore.list(), &(&1["name"] == "Late"))

    other = %{request_id: "imp_now", status: :picking}

    {:ignored, _} =
      NativeWorkspaceImport.handle_picked(other, [
        %{path: dest, name: "Wrong", request_id: "imp_old"}
      ])

    assert File.read!(outsider) == "leave"
  end

  test "receipts outside imported_root or for a missing directory do not register", %{dir: dir} do
    outside = Path.join(dir, "elsewhere")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "keep.txt"), "user file")
    current = %{request_id: "imp_out", status: :picking}

    assert {:error, :copy_failed, %{status: :idle}} =
             NativeWorkspaceImport.handle_picked(current, [
               %{path: outside, name: "Out", request_id: "imp_out"}
             ])

    assert File.read!(Path.join(outside, "keep.txt")) == "user file"

    missing = Path.join(NativeWorkspaces.imported_root(), "imp_missing")

    assert {:error, :copy_failed, %{status: :idle}} =
             NativeWorkspaceImport.handle_picked(%{request_id: "imp_missing", status: :picking}, [
               %{path: missing, name: "Missing", request_id: "imp_missing"}
             ])

    refute Enum.any?(WorkspaceStore.list(), &(&1["path"] =~ "imp_"))
  end

  test "late cancellation cannot cancel a newer request or delete a registered workspace" do
    path = Path.join(NativeWorkspaces.imported_root(), "imp_existing")
    File.mkdir_p!(path)
    File.write!(Path.join(path, "keep"), "user changes")
    {:ok, _} = WorkspaceStore.add(path)
    cancelled = %{request_id: "imp_existing", status: :cancelled}

    assert {:ignored, _} =
             NativeWorkspaceImport.handle_picked(cancelled, [
               %{path: path, request_id: "imp_existing"}
             ])

    assert File.read!(Path.join(path, "keep")) == "user changes"
    current = %{request_id: "imp_new", status: :picking}

    assert {:ignored, ^current} =
             NativeWorkspaceImport.handle_picked(current, [
               %{error: "cancelled", request_id: "imp_old"}
             ])

    assert {:error, :too_large, %{status: :idle}} =
             NativeWorkspaceImport.handle_picked(current, [
               %{error: "too_large", request_id: "imp_new"}
             ])
  end

  test "drafts and preference restore are workspace-scoped", %{default: default, dir: dir} do
    {:ok, extra} = NativeWorkspaces.create_empty("B")
    {:ok, conv} = ConversationStore.create(default["id"], title: "A chat")
    drafts = NativeWorkspaces.put_draft(%{}, default, %{conversation: conv}, "draft-a")
    drafts = NativeWorkspaces.put_draft(drafts, extra, nil, "draft-b")
    assert NativeWorkspaces.get_draft(drafts, default, conv) == "draft-a"
    assert NativeWorkspaces.get_draft(drafts, extra, nil) == "draft-b"

    {:ok, free} = ConversationStore.create_free(title: "Free")
    drafts = NativeWorkspaces.put_draft(drafts, nil, %{conversation: free}, "free-open")
    drafts = NativeWorkspaces.put_draft(drafts, nil, nil, "free-new")
    assert NativeWorkspaces.get_draft(drafts, nil, free) == "free-open"
    assert NativeWorkspaces.get_draft(drafts, nil, nil) == "free-new"

    NativeWorkspaces.persist(extra, nil)
    File.rm_rf!(extra["path"])
    {workspace, conversation} = NativeWorkspaces.restore(default)
    assert workspace["id"] == default["id"]
    assert conversation["id"] == conv["id"]
    assert File.exists?(Path.join(dir, ".handbean/native_ui.json"))
  end
end
