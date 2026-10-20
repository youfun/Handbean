defmodule HandbeanWeb.WorkspaceLive.PreviewAndFilesTest do
  use HandbeanWeb.WorkspaceLiveCase

  describe "preview and browser cards" do
    test "preview_serve tool_end renders open preview card without covering composer", %{
      conn: conn
    } do
      {:ok, view, html} = live(conn, "/")
      refute html =~ "preview-card"

      send(
        view.pid,
        agent_event(:tool_end, %{
          tool: "preview_serve",
          duration_ms: 12,
          details: %{
            preview_id: "pv_live",
            title: "Demo site",
            conversation_id: "conv-preview-card",
            preview_path: "/preview/pv_live"
          }
        })
      )

      rendered = render(view)
      assert rendered =~ "preview-card"
      assert rendered =~ "Open preview"
      assert rendered =~ "Open in browser"
      assert rendered =~ "Demo site"
      assert rendered =~ ~s(id="composer") or rendered =~ "phx-submit=\"send_message\""
    end

    test "needs_user browser result shows takeover prompt, not an auto overlay", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        agent_event(:tool_end, %{
          tool: "browser",
          duration_ms: 8,
          details: %{
            needs_user: true,
            reason: "captcha",
            session_id: "bws_live",
            backend: "webview"
          }
        })
      )

      rendered = render(view)
      assert rendered =~ "Take over browser"
      assert rendered =~ "captcha"
      refute rendered =~ "Mob.UI.webview"
    end
  end

  describe "file preview" do
    test "default workspace preview is isolated from inherited project overrides", %{conn: conn} do
      System.put_env("HANDBEAN_WORKSPACE", Path.join(Handbean.Home.path(), "inherited-project"))
      isolate_conversation_home!()
      {:ok, workspace} = Handbean.WorkspaceStore.ensure_default!()
      assert Handbean.Workspace.root() == workspace["path"]

      path = Path.join(Handbean.Workspace.ensure_root!(), "isolated-preview.txt")
      File.write!(path, "isolated preview fixture")
      {:ok, view, _html} = live(conn, "/")
      _ = create_default_conversation(view)

      view
      |> element(
        "button[phx-click='select_workspace_file'][phx-value-path='isolated-preview.txt']"
      )
      |> render_click()

      assert render(view) =~ "isolated preview fixture"
    end

    test "a chat file citation opens the files panel on a collapsed changes view", %{conn: conn} do
      ws = Handbean.Workspace.ensure_root!()

      File.write!(
        Path.join(ws, "AGENTS.md"),
        Enum.map_join(1..30, "\n", fn line -> "line #{line}" end)
      )

      {:ok, view, _html} = live(conn, "/")
      _ = create_default_conversation(view)

      view
      |> element("button[phx-click='select_right_panel_view'][phx-value-view='changes']")
      |> render_click()

      view
      |> element("#workspace-panel-collapse")
      |> render_click()

      refute has_element?(view, "#workspace-files")
      refute has_element?(view, "#workspace-panel-collapse")

      render_click(view, "open_file_change", %{"path" => "AGENTS.md", "line" => "22"})

      assert has_element?(view, "#workspace-files")
      assert has_element?(view, "#workspace-panel-collapse")
      assert has_element?(view, "[role='tab'][aria-selected='true']", "AGENTS.md")
      html = render(view)
      assert html =~ "line 22"
      assert html =~ ~s(data-preview-line="22")
    end

    test "a deleted inactive tab can be selected and switching back restores its neighbor", %{
      conn: conn
    } do
      ws = Handbean.Workspace.ensure_root!()
      File.write!(Path.join(ws, "tab-a.txt"), "content from tab A")
      File.write!(Path.join(ws, "tab-b.txt"), "content from tab B")
      {:ok, view, _html} = live(conn, "/")
      conversation_id = create_default_conversation(view)

      render_click(view, "select_workspace_file", %{"path" => "tab-a.txt"})
      render_click(view, "select_workspace_file", %{"path" => "tab-b.txt"})
      render_click(view, "select_editor_file", %{"path" => "tab-a.txt"})
      File.rm!(Path.join(ws, "tab-b.txt"))

      view
      |> element("[role='tab'][phx-value-path='tab-b.txt']")
      |> render_click()

      assert has_element?(view, "[role='tab'][aria-selected='true']", "tab-b.txt")
      assert render(view) =~ "File no longer exists"
      assert Handbean.ConversationStore.load_files(conversation_id)["active_file"] == "tab-b.txt"

      view
      |> element("[role='tab'][phx-value-path='tab-a.txt']")
      |> render_click()

      assert has_element?(view, "[role='tab'][aria-selected='true']", "tab-a.txt")
      assert render(view) =~ "content from tab A"
      refute render(view) =~ "File no longer exists"
    end

    test "invalid Markdown targets report errors without changing the current file preview", %{
      conn: conn
    } do
      ws = Handbean.Workspace.ensure_root!()
      File.write!(Path.join(ws, "current.md"), "# Current document")
      File.write!(Path.join(ws, "unopened.md"), "# Unopened document")
      {:ok, view, _html} = live(conn, "/")
      conversation_id = create_default_conversation(view)
      render_click(view, "select_workspace_file", %{"path" => "current.md"})

      for event <- ["select_file", "select_workspace_file"] do
        render_click(view, event, %{"path" => "missing.md"})
        assert has_element?(view, "#flash-error", "File no longer exists")
        assert has_element?(view, "[role='tab'][aria-selected='true']", "current.md")
        assert render(view) =~ "Current document"

        assert Handbean.ConversationStore.load_files(conversation_id)["active_file"] ==
                 "current.md"
      end

      render_click(view, "select_editor_file", %{"path" => "unopened.md"})
      refute has_element?(view, "[role='tab']", "unopened.md")
      assert has_element?(view, "[role='tab'][aria-selected='true']", "current.md")
    end

    test "Agent updates to the active image refresh its URL and served content", %{conn: conn} do
      before_image =
        Base.decode64!(
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg=="
        )

      after_image =
        Base.decode64!(
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYPj/HwADAgH/5ncLrgAAAABJRU5ErkJggg=="
        )

      assert byte_size(before_image) == byte_size(after_image)
      path = Path.join(Handbean.Workspace.ensure_root!(), "current.png")
      File.write!(path, before_image)
      {:ok, view, _html} = live(conn, "/")
      _ = create_default_conversation(view)
      render_click(view, "select_workspace_file", %{"path" => "current.png"})

      image_src = fn ->
        view
        |> render()
        |> Floki.parse_document!()
        |> Floki.find("img[alt='current.png']")
        |> Floki.attribute("src")
        |> List.first()
      end

      before_src = image_src.()
      assert response(get(conn, before_src), 200) == before_image
      File.write!(path, after_image)

      send(
        view.pid,
        agent_event(:tool_end, %{
          tool: "edit",
          duration_ms: 100,
          file_path: path,
          details: %{diff_lines: [%{"type" => "ins", "text" => "updated image"}]}
        })
      )

      after_src = image_src.()
      assert after_src != before_src
      assert response(get(conn, after_src), 200) == after_image
      assert has_element?(view, "[role='tab'][aria-selected='true']", "current.png")
    end

    test "opening a file after the asynchronous sidebar loads preserves restored tabs across reload",
         %{
           conn: conn
         } do
      root = Handbean.Workspace.ensure_root!()

      for name <- ["restored-a.ex", "restored-b.ex", "new-c.ex"],
          do: File.write!(Path.join(root, name), "content of #{name}")

      {:ok, conversation} = Handbean.ConversationStore.create("default", title: "Restored tabs")
      id = conversation["id"]
      url = "/w/default/c/#{id}"

      :ok =
        Handbean.ConversationStore.save_files(id, %{
          "editor_files" => Enum.map(["restored-a.ex", "restored-b.ex"], &%{"path" => &1}),
          "active_file" => "restored-b.ex"
        })

      {:ok, view, _html} = live(conn, url)
      html = render_async(view, 5_000)
      refute html =~ ~s(id="conversation-list-loading")
      assert html =~ ~s(data-conversation-id="#{id}")
      assert has_element?(view, "[role='tab'][aria-selected='true']", "restored-b.ex")

      render_click(view, "select_workspace_file", %{"path" => "new-c.ex"})

      for name <- ["restored-a.ex", "restored-b.ex", "new-c.ex"],
          do: assert(has_element?(view, "[role='tab']", name))

      assert has_element?(view, "[role='tab'][aria-selected='true']", "new-c.ex")
      stored = Handbean.ConversationStore.load_files(id)

      assert Enum.map(stored["editor_files"], & &1["path"]) ==
               ["restored-a.ex", "restored-b.ex", "new-c.ex"]

      assert stored["active_file"] == "new-c.ex"

      {:ok, restored, _html} = live(recycle(conn), url)
      render_async(restored, 5_000)

      for name <- ["restored-a.ex", "restored-b.ex", "new-c.ex"],
          do: assert(has_element?(restored, "[role='tab']", name))

      assert has_element?(restored, "[role='tab'][aria-selected='true']", "new-c.ex")
    end

    test "mount restores the active relative file before editor defaults exist", %{conn: conn} do
      ws = Handbean.Workspace.ensure_root!()
      File.write!(Path.join(ws, "restored.ex"), "# restored on initial mount")
      {:ok, conversation} = Handbean.ConversationStore.create("default", title: "Restored files")

      :ok =
        Handbean.ConversationStore.save_files(conversation["id"], %{
          "editor_files" => [%{"path" => "restored.ex", "name" => "restored.ex"}],
          "active_file" => "restored.ex"
        })

      {:ok, view, html} = live(conn, "/w/default/c/#{conversation["id"]}")

      assert Process.alive?(view.pid)
      assert html =~ "# restored on initial mount"

      assert has_element?(
               view,
               "button[phx-click='close_editor_file'][phx-value-path='restored.ex']"
             )
    end

    test "render_file_preview returns content for valid file" do
      ws = Handbean.Workspace.ensure_root!()
      tmp = Path.join(ws, "sigil_lv_test_preview.txt")
      File.write!(tmp, "hello\nworld")

      try do
        result = HandbeanWeb.WorkspaceLive.render_file_preview(tmp)
        assert result =~ "hello"
        assert result =~ "world"
      after
        File.rm(tmp)
      end
    end

    test "render_file_preview returns access denied for non-existent file" do
      result = HandbeanWeb.WorkspaceLive.render_file_preview("/nonexistent/path.txt")
      assert result =~ "Access denied"
    end

    test "render_file_preview returns empty for nil" do
      assert HandbeanWeb.WorkspaceLive.render_file_preview(nil) == ""
    end

    test "select_file shows error for non-existent file in UI", %{conn: conn} do
      ws = Handbean.Workspace.ensure_root!()
      bad_path = Path.join(ws, "nonexistent.txt")

      {:ok, view, _html} = live(conn, "/")

      # A missing tool path must not appear in the workspace tree or open a preview.
      send(
        view.pid,
        agent_event(:tool_end, %{tool: "edit", duration_ms: 100, file_path: bad_path})
      )

      refute has_element?(view, ".workspace-file-row.file", "nonexistent.txt")
      refute has_element?(view, "#editor-content")
    end

    test "select_file shows file content in preview", %{conn: conn} do
      ws = Handbean.Workspace.ensure_root!()
      tmp = Path.join(ws, "sigil_lv_test_ui.txt")
      File.write!(tmp, "preview content line 1")

      {:ok, view, _html} = live(conn, "/")
      _ = create_default_conversation(view)

      try do
        # Add a file to editor_files
        send(
          view.pid,
          agent_event(:tool_end, %{
            tool: "edit",
            duration_ms: 100,
            file_path: tmp,
            details: %{diff_lines: [%{"type" => "ins", "text" => "preview content line 1"}]}
          })
        )

        view
        |> element(
          "button[phx-click='select_workspace_file'][phx-value-path='sigil_lv_test_ui.txt']"
        )
        |> render_click()

        rendered = render(view)
        assert rendered =~ "preview content line 1"
      after
        File.rm(tmp)
      end
    end

    test "selecting a binary workspace file keeps the LiveView alive", %{conn: conn} do
      ws = Handbean.Workspace.ensure_root!()
      path = Path.join(ws, "sigil_lv_test.db-shm")
      File.write!(path, <<0, 0xFF, "sqlite">>)

      {:ok, view, _html} = live(conn, "/")
      _ = create_default_conversation(view)

      try do
        view
        |> element(
          "button[phx-click='select_workspace_file'][phx-value-path='sigil_lv_test.db-shm']"
        )
        |> render_click()

        rendered = render(view)
        assert Process.alive?(view.pid)
        assert rendered =~ "This file format is not rendered in the workspace yet."
        assert rendered =~ "sigil_lv_test.db-shm"
      after
        File.rm(path)
      end
    end
  end
end
