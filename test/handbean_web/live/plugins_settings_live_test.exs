defmodule HandbeanWeb.PluginsSettingsLiveTest do
  use HandbeanWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    root =
      Path.join(System.tmp_dir!(), "handbean_plugins_live_#{System.unique_integer([:positive])}")

    home_dir = Path.join(root, "home")
    config_path = Path.join(home_dir, ".handbean/mcp.json")
    workspaces_path = Path.join(home_dir, ".handbean/workspaces.json")
    workspace_path = Path.join(home_dir, ".handbean/workspace")

    File.mkdir_p!(workspace_path)

    old_home = System.get_env("HOME")
    old_config = Application.get_env(:handbean, :mcp_user_config_path)
    old_workspaces = System.get_env("HANDBEAN_WORKSPACES_FILE")
    old_workspace = System.get_env("HANDBEAN_WORKSPACE")

    System.put_env("HOME", home_dir)
    Application.put_env(:handbean, :mcp_user_config_path, config_path)
    System.put_env("HANDBEAN_WORKSPACES_FILE", workspaces_path)
    System.put_env("HANDBEAN_WORKSPACE", workspace_path)

    on_exit(fn ->
      restore_env("HOME", old_home)

      if old_config,
        do: Application.put_env(:handbean, :mcp_user_config_path, old_config),
        else: Application.delete_env(:handbean, :mcp_user_config_path)

      restore_env("HANDBEAN_WORKSPACES_FILE", old_workspaces)
      restore_env("HANDBEAN_WORKSPACE", old_workspace)
      File.rm_rf(root)
    end)

    {:ok, workspace} = Handbean.WorkspaceStore.ensure_default!()
    %{root: root, home_dir: home_dir, workspace: workspace}
  end

  test "opens unified plugins tab via ?tab=plugins, installs templates from discover, and toggles items",
       %{conn: conn, workspace: workspace} do
    {:ok, view, html} = live(conn, "/settings?tab=plugins&workspace_id=#{workspace["id"]}")
    assert html =~ "插件"

    plugins = find_live_child(view, "settings-mcp")
    assert has_element?(plugins, "#plugins-view-installed")
    assert has_element?(plugins, "#ext-empty")
    assert has_element?(plugins, "#mcp-empty")

    # Switch to Discover mode
    render_click(element(plugins, "#plugins-mode-discover"))
    assert has_element?(plugins, "#plugins-view-discover")
    assert has_element?(plugins, "#catalog-card-cat-skill-code-review")
    assert has_element?(plugins, "#catalog-card-cat-ext-workspace-ping")

    # Install Skill template into workspace
    render_click(
      element(
        plugins,
        "#catalog-card-cat-skill-code-review button[phx-click=open_catalog_install]"
      )
    )

    assert has_element?(
             plugins,
             "#plugins-inspect-modal [role=dialog][aria-modal=true][aria-labelledby=plugins-inspect-dialog-title]"
           )

    render_submit(element(plugins, "#plugins-catalog-install-form"), %{
      "catalog_id" => "cat-skill-code-review",
      "scope" => "workspace"
    })

    # Automatically returns to Installed view and shows installed skill
    assert has_element?(plugins, "#plugins-view-installed")
    assert has_element?(plugins, "#skill-card-code-review-checklist")

    # Toggle workspace skill off and inspect it
    render_click(
      element(plugins, "#skill-card-code-review-checklist button[phx-click=toggle_skill]")
    )

    assert has_element?(plugins, "#skill-card-code-review-checklist.is-disabled")

    render_click(
      element(plugins, "#skill-card-code-review-checklist button[phx-click=inspect_skill]")
    )

    assert render(plugins) =~ "disable-model-invocation: true"
    render_click(element(plugins, "#plugins-inspect-close"))

    # Bundled skill is read-only when toggled
    if has_element?(plugins, "#skill-card-developing-handbean-extensions") do
      render_click(
        element(
          plugins,
          "#skill-card-developing-handbean-extensions button[phx-click=toggle_skill]"
        )
      )

      assert has_element?(plugins, "#plugins-notice")
      refute has_element?(plugins, "#skill-card-developing-handbean-extensions.is-disabled")
    end

    # Install Extension template into user scope
    render_click(element(plugins, "#plugins-mode-discover"))

    render_click(
      element(
        plugins,
        "#catalog-card-cat-ext-workspace-ping button[phx-click=open_catalog_install]"
      )
    )

    render_submit(element(plugins, "#plugins-catalog-install-form"), %{
      "catalog_id" => "cat-ext-workspace-ping",
      "scope" => "user"
    })

    assert has_element?(plugins, "#ext-card-user-workspace-ping")

    # Toggle extension off
    render_click(element(plugins, "#ext-card-user-workspace-ping button[phx-click=toggle_ext]"))
    assert has_element?(plugins, "#ext-card-user-workspace-ping.is-disabled")

    # Filter by mechanism and search
    render_click(element(plugins, "#plugins-filter-ext"))
    assert has_element?(plugins, "#plugins-section-ext")
    refute has_element?(plugins, "#plugins-section-mcp")
    refute has_element?(plugins, "#plugins-section-skill")

    render_click(element(plugins, "#plugins-filter-all"))
    render_change(element(plugins, "#plugins-search-form"), %{"query" => "workspace-ping"})
    assert has_element?(plugins, "#ext-card-user-workspace-ping")
    refute has_element?(plugins, "#skill-card-code-review-checklist")
    # Sections without matches stay hidden instead of showing their empty state
    assert has_element?(plugins, "#plugins-section-ext")
    refute has_element?(plugins, "#plugins-section-skill")
    refute has_element?(plugins, "#skill-empty")

    render_change(element(plugins, "#plugins-search-form"), %{"query" => "zzz-no-match"})
    refute has_element?(plugins, "#plugins-section-ext")
    refute has_element?(plugins, "#plugins-section-skill")
    assert has_element?(plugins, "#plugins-no-results")

    render_change(element(plugins, "#plugins-search-form"), %{"query" => ""})
    assert has_element?(plugins, "#plugins-section-skill")
    refute has_element?(plugins, "#plugins-no-results")
  end

  test "opens pre-filled MCP form from discover preset and toggles MCP disabled switch", %{
    conn: conn,
    workspace: workspace
  } do
    {:ok, view, _html} = live(conn, "/settings?tab=plugins&workspace_id=#{workspace["id"]}")
    plugins = find_live_child(view, "settings-mcp")

    render_click(element(plugins, "#plugins-mode-discover"))

    render_click(
      element(plugins, "#catalog-card-cat-mcp-context7 button[phx-click=open_mcp_preset]")
    )

    assert has_element?(plugins, "#mcp-server-form")
    assert has_element?(plugins, ~s(input[name="server[name]"][value="Context7"]))

    render_submit(element(plugins, "#mcp-server-form"), %{
      "server" => %{
        "id" => "",
        "name" => "Context7",
        "url" => "https://mcp.context7.com/mcp",
        "auth" => "none",
        "disabled" => "false",
        "access_mode" => "all"
      }
    })

    {:ok, [server]} = Handbean.MCP.Settings.list()
    assert has_element?(plugins, "#mcp-server-#{server.id}")
    refute has_element?(plugins, "#mcp-server-#{server.id}.is-disabled")

    render_click(element(plugins, "#mcp-server-#{server.id} button[phx-click=toggle_mcp]"))
    assert has_element?(plugins, "#mcp-server-#{server.id}.is-disabled")
  end

  test "imports local skill directory and launches agent builder with pre-filled composer draft",
       %{
         conn: conn,
         root: root,
         workspace: workspace
       } do
    local_skill_dir = Path.join(root, "my-imported-skill")
    File.mkdir_p!(local_skill_dir)

    File.write!(
      Path.join(local_skill_dir, "SKILL.md"),
      """
      ---
      name: my-imported-skill
      description: Local imported skill description.
      ---
      # My Imported Skill
      """
    )

    {:ok, view, _html} = live(conn, "/settings?tab=plugins&workspace_id=#{workspace["id"]}")
    plugins = find_live_child(view, "settings-mcp")

    render_click(element(plugins, "#plugins-import-dir"))

    assert has_element?(
             plugins,
             "#plugins-import-modal [role=dialog][aria-modal=true][aria-labelledby=plugins-import-dialog-title]"
           )

    render_submit(element(plugins, "#plugins-import-form"), %{
      "import" => %{
        "path" => local_skill_dir,
        "scope" => "workspace"
      }
    })

    assert has_element?(plugins, "#skill-card-my-imported-skill")

    # Submit Agent Builder prompt in Discover view
    render_click(element(plugins, "#plugins-mode-discover"))

    assert {:error, {:live_redirect, %{to: redirect_to}}} =
             render_submit(element(plugins, "#plugins-agent-builder-form"), %{
               "prompt" => "查询本地 SQLite 慢查询"
             })

    assert redirect_to =~ "/w/#{workspace["id"]}/c/"
    assert redirect_to =~ "draft="

    {:ok, _ws_view, ws_html} = live(conn, redirect_to)
    assert ws_html =~ "/skill:developing-handbean-extensions 查询本地 SQLite 慢查询"
  end

  test "saves OAuth client configuration and offers a scoped CSRF-protected authorization", %{
    conn: conn,
    workspace: workspace
  } do
    old_host = Application.get_env(:handbean, :host)
    Application.put_env(:handbean, :host, Map.put(old_host || %{}, :mcp, true))

    on_exit(fn ->
      if old_host,
        do: Application.put_env(:handbean, :host, old_host),
        else: Application.delete_env(:handbean, :host)
    end)

    {:ok, view, _html} = live(conn, "/settings?tab=plugins&workspace_id=#{workspace["id"]}")
    plugins = find_live_child(view, "settings-mcp")
    render_click(element(plugins, "#mcp-add"))

    assert has_element?(
             plugins,
             "[role=dialog][aria-modal=true][aria-labelledby=plugins-mcp-dialog-title]"
           )

    render_change(element(plugins, "#mcp-server-form"), %{"server" => %{"auth" => "oauth"}})

    render_submit(element(plugins, "#mcp-server-form"), %{
      "server" => %{
        "id" => "",
        "name" => "OAuth documents",
        "url" => "https://mcp.example.com/mcp",
        "auth" => "oauth",
        "oauth_client_id" => "handbean-public-client",
        "oauth_issuer" => "https://auth.example.com",
        "oauth_scopes" => "documents.read profile",
        "disabled" => "false",
        "access_mode" => "selected",
        "workspace_ids" => [workspace["id"]]
      }
    })

    {:ok, [server]} = Handbean.MCP.Settings.list()
    {:ok, config} = Handbean.MCP.OAuth.config(workspace["id"], server.id)
    assert config.oauth["client_id"] == "handbean-public-client"
    assert config.oauth["scopes"] == ["documents.read", "profile"]
    assert Handbean.MCP.OAuth.status(config) == :authorization_required

    action = "/mcp/oauth/#{workspace["id"]}/#{server.id}/start"
    assert has_element?(plugins, ~s(form[action="#{action}"][method="post"]))
    assert has_element?(plugins, ~s(form[action="#{action}"] input[name="_csrf_token"]))

    render_click(element(plugins, "#mcp-server-#{server.id} button[phx-click=edit]"))

    assert has_element?(
             plugins,
             ~s(input[name="server[oauth_client_id]"][value="handbean-public-client"])
           )

    Application.put_env(:handbean, :host, Map.put(old_host || %{}, :mcp, false))

    {:ok, disabled_view, _html} =
      live(conn, "/settings?tab=plugins&workspace_id=#{workspace["id"]}")

    disabled_plugins = find_live_child(disabled_view, "settings-mcp")
    refute has_element?(disabled_plugins, ~s(form[action="#{action}"]))

    assert has_element?(
             disabled_plugins,
             ~s(form[action="/mcp/oauth/#{workspace["id"]}/#{server.id}/disconnect"])
           )
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
