defmodule HandbeanWeb.MCPSettingsLiveTest do
  use HandbeanWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    root = Path.join(System.tmp_dir!(), "handbean_mcp_live_#{System.unique_integer([:positive])}")
    config_path = Path.join(root, "mcp.json")
    workspaces_path = Path.join(root, "workspaces.json")
    workspace_path = Path.join(root, "workspace")
    old_config = Application.get_env(:handbean, :mcp_user_config_path)
    old_workspaces = System.get_env("HANDBEAN_WORKSPACES_FILE")
    old_workspace = System.get_env("HANDBEAN_WORKSPACE")

    Application.put_env(:handbean, :mcp_user_config_path, config_path)
    System.put_env("HANDBEAN_WORKSPACES_FILE", workspaces_path)
    System.put_env("HANDBEAN_WORKSPACE", workspace_path)

    on_exit(fn ->
      if old_config,
        do: Application.put_env(:handbean, :mcp_user_config_path, old_config),
        else: Application.delete_env(:handbean, :mcp_user_config_path)

      restore_env("HANDBEAN_WORKSPACES_FILE", old_workspaces)
      restore_env("HANDBEAN_WORKSPACE", old_workspace)
      File.rm_rf(root)
    end)

    :ok
  end

  test "saves workspace access, never renders credentials, preserves a blank secret, and deletes",
       %{
         conn: conn
       } do
    {:ok, workspace} = Handbean.WorkspaceStore.ensure_default!()
    {:ok, view, _html} = live(conn, "/settings?tab=mcp&workspace_id=#{workspace["id"]}")
    mcp = find_live_child(view, "settings-mcp")

    assert has_element?(mcp, "#mcp-empty")
    render_click(element(mcp, "#mcp-add"))

    params = %{
      "id" => "",
      "name" => "Docs",
      "url" => "https://mcp.example.test",
      "auth" => "bearer",
      "token" => "super-secret",
      "disabled" => "false",
      "access_mode" => "selected",
      "workspace_ids" => [workspace["id"]]
    }

    render_submit(element(mcp, "#mcp-server-form"), %{"server" => params})
    assert render(mcp) =~ "Docs"
    refute render(mcp) =~ "super-secret"

    {:ok, [server]} = Handbean.MCP.Settings.list()

    assert server.workspace_access == %{
             "mode" => "selected",
             "workspace_ids" => [workspace["id"]]
           }

    render_click(element(mcp, "#mcp-server-#{server.id} button[phx-click=edit]"))
    assert has_element?(mcp, ~s(input[name="server[token]"][value=""]))
    assert render(mcp) =~ "Leave blank to keep saved token"

    render_submit(element(mcp, "#mcp-server-form"), %{
      "server" => Map.put(params, "id", server.id) |> Map.put("token", "")
    })

    {:ok, edit_form} = Handbean.MCP.Settings.edit(server.id)
    assert edit_form["has_credentials"]
    refute render(mcp) =~ "super-secret"

    render_click(element(mcp, "#mcp-server-#{server.id} button[phx-click=confirm_delete]"))
    assert has_element?(mcp, "#mcp-delete-confirm-#{server.id}")
    render_click(element(mcp, "#mcp-delete-confirm-#{server.id} button[phx-click=delete]"))
    assert {:ok, []} = Handbean.MCP.Settings.list()
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
