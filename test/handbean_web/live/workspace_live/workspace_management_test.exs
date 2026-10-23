defmodule HandbeanWeb.WorkspaceLive.WorkspaceManagementTest do
  use HandbeanWeb.WorkspaceLiveCase

  describe "workspace integration" do
    setup do
      base_dir =
        Path.join(System.tmp_dir!(), "sigil_lv_ws_case_#{System.unique_integer([:positive])}")

      store_path = Path.join(base_dir, "workspaces.json")
      old_home = System.get_env("HOME")
      home_dir = Path.join(base_dir, "home")
      ws_dir = Path.join(home_dir, ".handbean/workspace")

      File.mkdir_p!(base_dir)
      Application.put_env(:handbean, :host, %{data_dir: home_dir})
      System.put_env("HOME", home_dir)
      System.put_env("HANDBEAN_WORKSPACES_FILE", store_path)
      System.put_env("HANDBEAN_WORKSPACE", ws_dir)
      Handbean.Workspace.ensure_root!()

      on_exit(fn ->
        if old_home, do: System.put_env("HOME", old_home), else: System.delete_env("HOME")
        System.delete_env("HANDBEAN_WORKSPACE")
        System.delete_env("HANDBEAN_WORKSPACES_FILE")
        if File.exists?(base_dir), do: File.rm_rf!(base_dir)
      end)

      {:ok, ws_dir: ws_dir, home_dir: home_dir}
    end

    test "outdated workspace configuration stays intact and can be retried after repair", %{
      conn: conn
    } do
      path = Handbean.WorkspaceStore.storage_path()
      {:ok, workspace} = Handbean.WorkspaceStore.ensure_default!()
      current = File.read!(path)

      legacy =
        Handbean.JSON.encode!(%{"workspaces" => [Map.take(workspace, ["id", "name", "path"])]})

      File.write!(path, legacy)

      for route <- ["/", "/w/#{workspace["id"]}/c/missing", "/c/missing"] do
        {:ok, view, html} = live(conn, route)
        assert html =~ "Workspace configuration needs attention"
        assert html =~ "older workspace format"
        assert html =~ path
        assert has_element?(view, "a[href='/']", "Retry")
        assert File.read!(path) == legacy
      end

      File.write!(path, current)
      {:ok, view, _html} = live(conn, "/")
      assert has_element?(view, "#workspace-shell")
      assert {:ok, restored} = Handbean.WorkspaceStore.get(workspace["id"])

      assert restored["path"] ==
               Handbean.Security.PathValidator.resolve_symlink(workspace["path"])
    end

    test "checkout picker heading has a zh_CN translation" do
      assert {:ok, _translation} =
               HandbeanWeb.Gettext.lgettext("zh_CN", "default", "Choose a checkout", %{})
    end

    test "adding two linked checkouts creates one workspace with checkout-bound conversations", %{
      conn: conn
    } do
      base =
        Path.join(System.tmp_dir!(), "sigil_linked_project_#{System.unique_integer([:positive])}")

      repo = Path.join(base, "repo")
      linked = Path.join(base, "linked")
      init_git_repo!(repo)
      git!(repo, ["worktree", "add", "-b", "feature", linked])

      try do
        {:ok, view, _html} = live(conn, "/")

        for {path, name} <- [{repo, "Repo"}, {linked, "Linked"}] do
          view |> element("#activity-bar button[phx-click='open_add_project']") |> render_click()
          view |> render_keyup("update_add_path", %{"value" => path})
          view |> render_keyup("update_add_name", %{"value" => name})
          view |> element("button[phx-click='confirm_add_project']") |> render_click()
        end

        assert {:ok, main_workspace} = Handbean.WorkspaceStore.get_by_path(repo)
        assert {:ok, linked_workspace} = Handbean.WorkspaceStore.get_by_path(linked)
        assert main_workspace["id"] == linked_workspace["id"]

        conversations =
          Handbean.ConversationStore.list_for_workspace(main_workspace["id"])

        assert MapSet.new(Enum.map(conversations, & &1["checkout_path"])) ==
                 MapSet.new([
                   Handbean.Security.PathValidator.resolve_symlink(repo),
                   Handbean.Security.PathValidator.resolve_symlink(linked)
                 ])

        view
        |> element("#new-conversation-picker-toggle")
        |> render_click()

        view
        |> element(".new-conversation-chip[aria-controls='new-conversation-projects']")
        |> render_click()

        view
        |> element("#new-conversation-project-#{main_workspace["id"]}")
        |> render_click()

        html = render(view)
        assert html =~ ~s(id="new-conversation-page")
        assert has_element?(view, "#new-conversation-page")
        assert html =~ Path.basename(repo)
        assert html =~ Path.basename(linked)
        assert html =~ "feature"

        linked_path = Handbean.Security.PathValidator.resolve_symlink(linked)
        before = Handbean.ConversationStore.list_for_workspace(main_workspace["id"])

        view
        |> element("#new-conversation-checkout")
        |> render_change(%{"checkout_path" => linked_path})

        assert Handbean.ConversationStore.list_for_workspace(main_workspace["id"]) == before

        view
        |> form("#new-conversation-composer", %{
          "message" => "Inspect the linked checkout",
          "checkout_path" => linked_path
        })
        |> render_submit()

        conversations = Handbean.ConversationStore.list_for_workspace(main_workspace["id"])

        assert Enum.count(conversations, &(&1["checkout_path"] == linked_path)) ==
                 Enum.count(before, &(&1["checkout_path"] == linked_path)) + 1

        assert length(Enum.reject(Handbean.WorkspaceStore.list(), & &1["default"])) == 1
        html = render(view)
        refute html =~ ~s(id="new-conversation-page")
        assert html =~ ~s(data-checkout-path="#{linked_path}")
      after
        File.rm_rf!(base)
      end
    end

    test "checkout picker dialog keeps the full branch name", %{conn: conn} do
      base =
        Path.join(System.tmp_dir!(), "sigil_long_branch_#{System.unique_integer([:positive])}")

      repo = Path.join(base, "bomeasy")
      linked = Path.join(base, "feedback-70-5f9aa617fa")
      branch = "feedback/70-5f9aa617fa-chore-code-security-hardening"
      init_git_repo!(repo)
      git!(repo, ["worktree", "add", "-b", branch, linked])

      try do
        {:ok, view, _html} = live(conn, "/")

        for {path, name} <- [{repo, "bomeasy"}, {linked, "Linked"}] do
          view |> element("#activity-bar button[phx-click='open_add_project']") |> render_click()
          view |> render_keyup("update_add_path", %{"value" => path})
          view |> render_keyup("update_add_name", %{"value" => name})
          view |> element("button[phx-click='confirm_add_project']") |> render_click()
        end

        {:ok, workspace} = Handbean.WorkspaceStore.get_by_path(repo)

        view
        |> element(
          "#workspace-group-#{workspace["id"]} button[phx-click='new_conversation_in_workspace']"
        )
        |> render_click()

        linked_path = Handbean.Security.PathValidator.resolve_symlink(linked)

        assert has_element?(
                 view,
                 "#new-conversation-page"
               )

        assert has_element?(
                 view,
                 "#new-conversation-checkout option[value='#{linked_path}']",
                 branch
               )
      after
        File.rm_rf!(base)
      end
    end

    test "workspace rows keep a new-conversation button next to the count", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(
               view,
               "#workspace-group-default .workspace-row-actions button[phx-click='new_conversation_in_workspace'][phx-value-ws_id='default']"
             )
    end

    test "new conversation draft does not create until a non-empty message is sent", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/")
      before = Handbean.ConversationStore.list_for_workspace("default")

      view |> element("#new-conversation-picker-toggle") |> render_click()

      assert has_element?(view, "#new-conversation-composer")
      assert has_element?(view, ".new-conversation-heading", "Start with a message")
      assert Handbean.ConversationStore.list_for_workspace("default") == before

      view |> element("#new-conversation-composer") |> render_submit(%{"message" => ""})

      assert has_element?(view, ".composer-error", "请输入消息")
      assert Handbean.ConversationStore.list_for_workspace("default") == before

      view
      |> form("#new-conversation-composer", %{"message" => "Start only when sent"})
      |> render_submit()

      after_list = Handbean.ConversationStore.list_for_workspace("default")
      assert length(after_list) == length(before) + 1
      refute has_element?(view, "#new-conversation-page")
    end

    test "adding a workspace creates a checkout-bound first conversation", %{conn: conn} do
      project_dir =
        Path.join(System.tmp_dir!(), "sigil_added_project_#{System.unique_integer([:positive])}")

      File.mkdir_p!(project_dir)

      try do
        {:ok, view, _html} = live(conn, "/")

        view |> element("#activity-bar button[phx-click='open_add_project']") |> render_click()
        assert has_element?(view, "#add-project-builtin-memory[checked]")
        view |> render_keyup("update_add_path", %{"value" => project_dir})
        view |> render_keyup("update_add_name", %{"value" => "Added Project"})
        view |> element("button[phx-click='confirm_add_project']") |> render_click()

        rendered = render(view)

        assert rendered =~ "Added Project"
        refute rendered =~ "sid:none"
        assert rendered =~ "No messages yet"
        {:ok, added_ws} = Handbean.WorkspaceStore.get_by_path(project_dir)
        assert Handbean.WorkspaceSettings.builtin_memory_enabled(project_dir)
        assert [conversation] = Handbean.ConversationStore.list_for_workspace(added_ws["id"])

        assert conversation["checkout_path"] ==
                 Handbean.Security.PathValidator.resolve_symlink(project_dir)
      after
        File.rm_rf!(project_dir)
      end
    end

    test "new workspace dialog can disable built-in memory", %{conn: conn} do
      project_dir =
        Path.join(
          System.tmp_dir!(),
          "sigil_external_memory_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(project_dir)

      try do
        {:ok, view, _html} = live(conn, "/")

        view |> element("#activity-bar button[phx-click='open_add_project']") |> render_click()
        view |> element("#add-project-builtin-memory") |> render_click()
        refute has_element?(view, "#add-project-builtin-memory[checked]")

        view |> render_keyup("update_add_path", %{"value" => project_dir})
        view |> render_keyup("update_add_name", %{"value" => "External Memory"})
        view |> element("button[phx-click='confirm_add_project']") |> render_click()

        refute Handbean.WorkspaceSettings.builtin_memory_enabled(project_dir)
        assert {:ok, settings} = Handbean.WorkspaceSettings.load(project_dir)
        assert get_in(settings, ["memory", "builtin_enabled"]) == false
      after
        File.rm_rf!(project_dir)
      end
    end

    test "removing a workspace archives its conversations and keeps the directory", %{conn: conn} do
      project_dir =
        Path.join(
          System.tmp_dir!(),
          "sigil_removed_project_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(project_dir)
      File.write!(Path.join(project_dir, "keep.txt"), "still here")

      try do
        {:ok, added} = Handbean.WorkspaceStore.add(project_dir, name: "To Remove")

        {:ok, conversation} =
          Handbean.ConversationStore.create(added["id"],
            title: "Kept chat",
            timeline: [%{"id" => "kept-1", "role" => "user", "content" => "do not delete"}]
          )

        {:ok, view, _html} = live(conn, "/")

        rendered = render(view)
        assert rendered =~ ~s(id="workspace-hover-remove")
        refute rendered =~ "workspace-menu-#{added["id"]}"

        view
        |> render_click("open_remove_workspace", %{"id" => added["id"]})

        dialog = render(view)
        assert dialog =~ "Remove workspace"
        assert dialog =~ "archives its conversations"

        view |> element("#confirm-remove-workspace") |> render_click()

        rendered = render(view)
        refute rendered =~ "To Remove"
        assert rendered =~ "Archived"
        assert rendered =~ "Kept chat"
        assert File.read!(Path.join(project_dir, "keep.txt")) == "still here"
        assert {:error, :not_found} = Handbean.WorkspaceStore.get(added["id"])

        assert {:ok, archived} =
                 Handbean.ConversationStore.get(conversation["id"], include_timeline?: false)

        assert is_binary(archived["archived_at"])
      after
        File.rm_rf!(project_dir)
      end
    end

    test "sandbox host imports a copied directory as the workspace", %{conn: conn} do
      previous = Application.get_env(:handbean, :host)

      imported =
        Path.join(System.tmp_dir!(), "sigil_imported_ws_#{System.unique_integer([:positive])}")

      File.mkdir_p!(imported)
      File.write!(Path.join(imported, "README.md"), "from downloads")

      Handbean.Host.put!(%{
        data_dir:
          Path.join(System.tmp_dir!(), "handbean_host_#{System.unique_integer([:positive])}"),
        shell: false,
        terminal: false,
        browser_backend: nil
      })

      try do
        {:ok, view, _html} = live(conn, "/")

        view |> element("#activity-bar button[phx-click='open_add_project']") |> render_click()
        assert render(view) =~ "Import from Downloads"

        send(view.pid, {:workspace_imported, %{path: imported, name: "Downloads Project"}})
        rendered = render(view)

        assert rendered =~ "Downloads Project"
        {:ok, added_ws} = Handbean.WorkspaceStore.get_by_path(imported)
        assert added_ws["name"] == "Downloads Project"
      after
        if previous,
          do: Application.put_env(:handbean, :host, previous),
          else: Application.delete_env(:handbean, :host)

        File.rm_rf!(imported)
      end
    end

    test "status bar shows MCP and skills counts for the current workspace", %{conn: conn} do
      project_dir =
        Path.join(System.tmp_dir!(), "sigil_counts_project_#{System.unique_integer([:positive])}")

      File.mkdir_p!(project_dir)
      File.mkdir_p!(Path.join(project_dir, ".handbean/skills/code-review"))
      File.mkdir_p!(Path.join(project_dir, ".handbean/skills/docs"))

      File.write!(
        Path.join(project_dir, ".mcp.json"),
        Jason.encode!(%{
          "mcpServers" => %{
            "one" => %{"command" => "echo"},
            "two" => %{"command" => "printf"}
          }
        })
      )

      File.write!(
        Path.join(project_dir, ".handbean/skills/code-review/SKILL.md"),
        """
        ---
        name: code-review
        description: Review code
        ---

        Review instructions.
        """
      )

      File.write!(
        Path.join(project_dir, ".handbean/skills/docs/SKILL.md"),
        """
        ---
        name: docs
        description: Write docs
        ---

        Docs instructions.
        """
      )

      try do
        {:ok, view, _html} = live(conn, "/")

        view |> element("#activity-bar button[phx-click='open_add_project']") |> render_click()
        view |> render_keyup("update_add_path", %{"value" => project_dir})
        view |> render_keyup("update_add_name", %{"value" => "Counted Project"})
        view |> element("button[phx-click='confirm_add_project']") |> render_click()

        bundled_count =
          Handbean.Skills.Loader.load(workspace: project_dir).skills
          |> Enum.count(&(&1.source == :bundled))

        assert has_element?(view, "#status-mcp-count", "2")
        assert has_element?(view, "#status-skills-count", to_string(2 + bundled_count))
      after
        File.rm_rf!(project_dir)
      end
    end

    test "status bar includes global MCP and skills counts", %{conn: conn, home_dir: home_dir} do
      project_dir =
        Path.join(
          System.tmp_dir!(),
          "sigil_global_counts_project_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(project_dir)
      File.mkdir_p!(Path.join(project_dir, ".handbean/skills/code-review"))
      File.mkdir_p!(Path.join(project_dir, ".agents/skills/docs"))
      File.mkdir_p!(Path.join(home_dir, ".handbean"))
      File.mkdir_p!(Path.join(home_dir, ".handbean/skills/global-review"))

      File.write!(
        Path.join(home_dir, ".handbean/mcp.json"),
        Jason.encode!(%{
          "mcpServers" => %{
            "global" => %{"command" => "global-cmd"}
          }
        })
      )

      File.write!(
        Path.join(project_dir, ".mcp.json"),
        Jason.encode!(%{
          "mcpServers" => %{
            "one" => %{"command" => "echo"},
            "two" => %{"command" => "printf"}
          }
        })
      )

      File.write!(
        Path.join(project_dir, ".handbean/skills/code-review/SKILL.md"),
        """
        ---
        name: code-review
        description: Review code
        ---

        Review instructions.
        """
      )

      File.write!(
        Path.join(project_dir, ".agents/skills/docs/SKILL.md"),
        """
        ---
        name: docs
        description: Write docs
        ---

        Docs instructions.
        """
      )

      File.write!(
        Path.join(home_dir, ".handbean/skills/global-review/SKILL.md"),
        """
        ---
        name: global-review
        description: Global review
        ---

        Global review instructions.
        """
      )

      try do
        {:ok, view, _html} = live(conn, "/")

        view |> element("#activity-bar button[phx-click='open_add_project']") |> render_click()
        view |> render_keyup("update_add_path", %{"value" => project_dir})
        view |> render_keyup("update_add_name", %{"value" => "Global Counted Project"})
        view |> element("button[phx-click='confirm_add_project']") |> render_click()

        bundled_count =
          Handbean.Skills.Loader.load(workspace: project_dir, user_home: home_dir).skills
          |> Enum.count(&(&1.source == :bundled))

        assert has_element?(view, "#status-mcp-count", "3")
        assert has_element?(view, "#status-skills-count", to_string(3 + bundled_count))
      after
        File.rm_rf!(project_dir)
      end
    end

    for {default_model, expected_model} <- [
          {"stepfun/step-router-v1", "stepfun/step-router-v1"},
          {"removed/model", "sui2api/gpt-5.5"}
        ] do
      @default_model default_model
      @expected_model expected_model

      test "new conversations resolve workspace default #{default_model} before persisting", %{
        conn: conn,
        ws_dir: ws_dir
      } do
        configure_test_models!()
        :ok = Handbean.Settings.save_global(%{"default_model" => "sui2api/gpt-5.5"})
        {:ok, view, _html} = live(conn, "/")
        first_id = choose_new_conversation_project(view, "default")
        render_change(view, "select_model", %{"model" => "sui2api/gpt-5.5"})

        # Read the workspace setting afresh, rather than the mounted socket's cached settings.
        :ok =
          Handbean.Settings.save_workspace_model_ai(ws_dir, %{"default_model" => @default_model})

        second_id = choose_new_conversation_project(view, "default")

        assert second_id != first_id
        assert has_element?(view, "#model-picker option[value='#{@expected_model}'][selected]")

        assert {:ok, %{"selected_model" => @expected_model}} =
                 Handbean.ConversationStore.get(second_id)

        assert {:ok, %{"selected_model" => "sui2api/gpt-5.5"}} =
                 Handbean.ConversationStore.get(first_id)

        view
        |> element(
          ".conversation-item[phx-click='select_conversation'][phx-value-id='#{first_id}']"
        )
        |> render_click()

        assert has_element?(view, "#model-picker option[value='sui2api/gpt-5.5'][selected]")

        view
        |> element(
          ".conversation-item[phx-click='select_conversation'][phx-value-id='#{second_id}']"
        )
        |> render_click()

        assert has_element?(view, "#model-picker option[value='#{@expected_model}'][selected]")
      end
    end
  end
end
