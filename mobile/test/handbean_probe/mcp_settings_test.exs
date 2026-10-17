defmodule HandbeanProbe.MCPSettingsTest do
  use ExUnit.Case, async: true

  alias HandbeanProbe.MCPSettings

  setup do
    Gettext.put_locale(HandbeanProbe.Gettext, "en")
    :ok
  end

  test "renders HTTP and read-only stdio entries with empty and error states" do
    state =
      MCPSettings.loaded(MCPSettings.empty(), {
        :ok,
        [
          %{
            id: "web",
            name: "Web",
            transport: :http,
            disabled: false,
            workspace_access: %{"mode" => "all", "workspace_ids" => []},
            status: :connected,
            tool_count: 3,
            source: "/tmp/mcp.json"
          },
          %{
            id: "local",
            name: "Local",
            transport: :stdio,
            disabled: true,
            workspace_access: %{"mode" => "selected", "workspace_ids" => []},
            status: :not_connected,
            tool_count: 0,
            source: "/tmp/mcp.json"
          }
        ]
      })

    rendered = inspect(MCPSettings.render(state, []), limit: :infinity)
    assert rendered =~ "Web"
    assert rendered =~ "3 tools"
    assert rendered =~ "Read-only on mobile"
    assert rendered =~ "Disabled"

    empty = inspect(MCPSettings.render(MCPSettings.empty(), []), limit: :infinity)
    assert empty =~ "No MCP servers configured"

    failed = MCPSettings.loaded(MCPSettings.empty(), {:error, "cannot read settings"})
    assert inspect(MCPSettings.render(failed, [])) =~ "cannot read settings"
  end

  test "editor supports auth, masked keep-existing credentials and vertical workspace choices" do
    form = %{
      "id" => "server",
      "name" => "Docs",
      "url" => "https://example.test/mcp",
      "auth" => "bearer",
      "token" => "",
      "headers_json" => "",
      "has_credentials" => true,
      "disabled" => false,
      "access_mode" => "selected",
      "workspace_ids" => ["one"]
    }

    state = MCPSettings.open_edit(MCPSettings.empty(), {:ok, form})
    workspaces = [%{id: "one", name: "One"}, %{id: "two", name: "Two"}]
    tree = MCPSettings.render(state, workspaces)
    rendered = inspect(tree, limit: :infinity)

    assert rendered =~ "Leave blank to keep existing credentials"
    assert rendered =~ "secure: true"
    assert rendered =~ "{:mcp_access, \\\"all\\\"}"
    assert rendered =~ "One"
    assert rendered =~ "Two"

    state = MCPSettings.toggle_workspace(state, "two")
    assert state.form["workspace_ids"] == ["one", "two"]
    assert MCPSettings.dirty?(state)
  end

  test "test outcomes and destructive confirmations remain inline" do
    form = %{
      "id" => "server",
      "name" => "Docs",
      "url" => "https://example.test",
      "auth" => "none",
      "token" => "",
      "headers_json" => "",
      "has_credentials" => false,
      "disabled" => false,
      "access_mode" => "all",
      "workspace_ids" => []
    }

    state = MCPSettings.open_edit(MCPSettings.empty(), {:ok, form})

    assert MCPSettings.tested(%{state | testing?: true}, {:ok, %{tool_count: 7}}).test_result ==
             "Connected · 7 tools"

    assert MCPSettings.tested(%{state | testing?: true}, {:error, "offline"}).error == "offline"

    assert inspect(MCPSettings.render(%{state | confirm: :delete}, []), limit: :infinity) =~
             "mcp-delete-confirm"

    assert inspect(MCPSettings.render(%{state | confirm: :discard}, []), limit: :infinity) =~
             "mcp-discard-confirm"
  end
end
