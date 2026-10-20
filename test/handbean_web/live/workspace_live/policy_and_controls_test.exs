defmodule HandbeanWeb.WorkspaceLive.PolicyAndControlsTest do
  use HandbeanWeb.WorkspaceLiveCase

  describe "workspace model policy" do
    @tag :tmp_dir

    test "empty policy allowlist is treated as unrestricted", %{conn: conn} do
      tmp_ws_dir =
        Path.join(System.tmp_dir!(), "sigil_lv_policy_#{System.unique_integer([:positive])}")

      store_path =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_store_policy_#{System.unique_integer([:positive])}.json"
        )

      models_path =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_models_policy_#{System.unique_integer([:positive])}.json"
        )

      write_test_models_config(models_path)

      # Empty models.allow.providers means no workspace restriction.
      settings_path = Handbean.WorkspaceSettings.path(tmp_ws_dir)
      File.mkdir_p!(Path.dirname(settings_path))

      File.write!(
        settings_path,
        Jason.encode!(%{
          "models" => %{
            "allow" => %{"providers" => %{}}
          }
        })
      )

      System.put_env("HANDBEAN_WORKSPACES_FILE", store_path)
      System.put_env("HANDBEAN_WORKSPACE", tmp_ws_dir)
      System.put_env("HANDBEAN_MODELS_FILE", models_path)
      Handbean.Workspace.ensure_root!()

      on_exit(fn ->
        System.delete_env("HANDBEAN_WORKSPACE")
        System.delete_env("HANDBEAN_WORKSPACES_FILE")
        System.delete_env("HANDBEAN_MODELS_FILE")
        if File.exists?(tmp_ws_dir), do: File.rm_rf!(tmp_ws_dir)
        if File.exists?(store_path), do: File.rm!(store_path)
        if File.exists?(models_path), do: File.rm!(models_path)
      end)

      {:ok, view, _html} = live(conn, "/")
      rendered = render(view)

      assert rendered =~ "model-picker"
      assert rendered =~ "stepfun"
      assert rendered =~ "sui2api"
    end

    test "model picker visible when settings file absent", %{conn: conn} do
      tmp_ws_dir =
        Path.join(System.tmp_dir!(), "sigil_lv_nopolicy_#{System.unique_integer([:positive])}")

      store_path =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_store_nopolicy_#{System.unique_integer([:positive])}.json"
        )

      models_path =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_models_nopolicy_#{System.unique_integer([:positive])}.json"
        )

      write_test_models_config(models_path)

      # NO settings file written — missing .handbean/settings.jsonc means unrestricted.

      System.put_env("HANDBEAN_WORKSPACES_FILE", store_path)
      System.put_env("HANDBEAN_WORKSPACE", tmp_ws_dir)
      System.put_env("HANDBEAN_MODELS_FILE", models_path)
      Handbean.Workspace.ensure_root!()

      on_exit(fn ->
        System.delete_env("HANDBEAN_WORKSPACE")
        System.delete_env("HANDBEAN_WORKSPACES_FILE")
        System.delete_env("HANDBEAN_MODELS_FILE")
        if File.exists?(tmp_ws_dir), do: File.rm_rf!(tmp_ws_dir)
        if File.exists?(store_path), do: File.rm!(store_path)
        if File.exists?(models_path), do: File.rm!(models_path)
      end)

      {:ok, view, _html} = live(conn, "/")
      rendered = render(view)

      # With no policy, model picker should be visible
      assert rendered =~ "model-picker"
      assert rendered =~ "stepfun"
      assert rendered =~ "sui2api"
    end

    test "refreshing model picker reloads latest model config", %{conn: conn} do
      tmp_ws_dir =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_refresh_models_#{System.unique_integer([:positive])}"
        )

      store_path =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_store_refresh_models_#{System.unique_integer([:positive])}.json"
        )

      models_path =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_models_refresh_#{System.unique_integer([:positive])}.json"
        )

      write_test_models_config(models_path)

      System.put_env("HANDBEAN_WORKSPACES_FILE", store_path)
      System.put_env("HANDBEAN_WORKSPACE", tmp_ws_dir)
      System.put_env("HANDBEAN_MODELS_FILE", models_path)
      Handbean.Workspace.ensure_root!()

      on_exit(fn ->
        System.delete_env("HANDBEAN_WORKSPACE")
        System.delete_env("HANDBEAN_WORKSPACES_FILE")
        System.delete_env("HANDBEAN_MODELS_FILE")
        if File.exists?(tmp_ws_dir), do: File.rm_rf!(tmp_ws_dir)
        if File.exists?(store_path), do: File.rm!(store_path)
        if File.exists?(models_path), do: File.rm!(models_path)
      end)

      {:ok, view, _html} = live(conn, "/")

      initial_render = render(view)
      assert initial_render =~ "Step Router v1 (StepFun)"
      refute initial_render =~ "GPT-5.4 Mini"

      File.write!(
        models_path,
        Jason.encode!(%{
          "defaultProvider" => "stepfun",
          "defaultModel" => "gpt-5.4-mini",
          "providers" => %{
            "stepfun" => %{
              "baseUrl" => "https://api.stepfun.com/step_plan/v1",
              "api" => "stepfun-step-plan",
              "provider" => "stepfun",
              "models" => [
                %{"id" => "step-router-v1", "name" => "Step Router v1 (StepFun)"},
                %{"id" => "gpt-5.4-mini", "name" => "GPT-5.4 Mini"}
              ]
            },
            "sui2api" => %{
              "baseUrl" => "https://example.test/v1",
              "api" => "openai-responses",
              "models" => [
                %{"id" => "gpt-5.5", "name" => "GPT-5.5"}
              ]
            }
          }
        })
      )

      view
      |> element("#model-picker")
      |> render_click()

      refreshed = render(view)
      assert refreshed =~ "GPT-5.4 Mini"
    end

    test "missing global model config is seeded on first visit", %{conn: conn} do
      tmp_ws_dir =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_missing_models_#{System.unique_integer([:positive])}"
        )

      store_path =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_store_missing_models_#{System.unique_integer([:positive])}.json"
        )

      models_path =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_models_missing_#{System.unique_integer([:positive])}.json"
        )

      System.put_env("HANDBEAN_WORKSPACES_FILE", store_path)
      System.put_env("HANDBEAN_WORKSPACE", tmp_ws_dir)
      System.put_env("HANDBEAN_MODELS_FILE", models_path)
      Handbean.Workspace.ensure_root!()

      on_exit(fn ->
        System.delete_env("HANDBEAN_WORKSPACE")
        System.delete_env("HANDBEAN_WORKSPACES_FILE")
        System.delete_env("HANDBEAN_MODELS_FILE")
        if File.exists?(tmp_ws_dir), do: File.rm_rf!(tmp_ws_dir)
        if File.exists?(store_path), do: File.rm!(store_path)
      end)

      refute File.exists?(models_path)

      {:ok, view, _html} = live(conn, "/")
      rendered = render(view)

      assert File.exists?(models_path)
      assert rendered =~ "model-picker"
      refute rendered =~ "Configure models before sending"
    end
  end

  describe "reasoning selector" do
    test "renders beside the input controls for reasoning-capable models", %{conn: conn} do
      models_path =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_reasoning_models_#{System.unique_integer([:positive])}.json"
        )

      write_test_models_config(models_path)
      System.put_env("HANDBEAN_MODELS_FILE", models_path)

      on_exit(fn ->
        System.delete_env("HANDBEAN_MODELS_FILE")
        if File.exists?(models_path), do: File.rm!(models_path)
      end)

      {:ok, view, _html} = live(conn, "/")

      render_change(view, "select_model", %{"model" => "stepfun/step-router-v1"})

      assert has_element?(view, "#reasoning-picker")
      assert has_element?(view, "#reasoning-picker option[value='medium']")
      assert has_element?(view, "#reasoning-picker option[value='high']")
      refute has_element?(view, "#reasoning-picker option[value='xhigh']")
    end

    test "selecting reasoning updates the selected value", %{conn: conn} do
      models_path =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_select_reasoning_models_#{System.unique_integer([:positive])}.json"
        )

      write_test_models_config(models_path)
      System.put_env("HANDBEAN_MODELS_FILE", models_path)

      on_exit(fn ->
        System.delete_env("HANDBEAN_MODELS_FILE")
        if File.exists?(models_path), do: File.rm!(models_path)
      end)

      {:ok, view, _html} = live(conn, "/")

      render_change(view, "select_model", %{"model" => "stepfun/step-router-v1"})

      view
      |> element("#reasoning-picker")
      |> render_change(%{"reasoning" => "high"})

      assert has_element?(view, "#reasoning-picker option[value='high']")
      assert render(view) =~ "reasoning-picker"
    end

    test "form-level composer_drop keeps a High reasoning pick", %{conn: conn} do
      models_path =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_composer_drop_reasoning_#{System.unique_integer([:positive])}.json"
        )

      write_test_models_config(models_path)
      System.put_env("HANDBEAN_MODELS_FILE", models_path)

      on_exit(fn ->
        System.delete_env("HANDBEAN_MODELS_FILE")
        if File.exists?(models_path), do: File.rm!(models_path)
      end)

      {:ok, view, _html} = live(conn, "/")

      render_change(view, "select_model", %{"model" => "stepfun/step-router-v1"})

      # Native <select> inside #composer fires the form phx-change, not only
      # the picker's own select_reasoning event.
      view
      |> element("#composer")
      |> render_change(%{"reasoning" => "high", "model" => "stepfun/step-router-v1"})

      html = render(view)
      assert html =~ ~s(option selected value="high") or html =~ ~s(value="high" selected)
    end

    test "model and reasoning stay visible as mid-conversation controls", %{conn: conn} do
      models_path =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_mid_thread_models_#{System.unique_integer([:positive])}.json"
        )

      write_test_models_config(models_path)
      System.put_env("HANDBEAN_MODELS_FILE", models_path)

      on_exit(fn ->
        System.delete_env("HANDBEAN_MODELS_FILE")
        if File.exists?(models_path), do: File.rm!(models_path)
      end)

      {:ok, view, _html} = live(conn, "/")
      render_change(view, "select_model", %{"model" => "stepfun/step-router-v1"})
      html = render(view)

      assert html =~ "composer-turn-controls"
      assert has_element?(view, "#model-picker")
      assert has_element?(view, "#reasoning-picker")
      refute html =~ "This conversation"
      refute html =~ "Next message"
      refute html =~ "本对话使用"
      refute html =~ "下一条使用"
    end
  end

  describe "tool permissions menu" do
    test "permission event without a workspace reports failure and keeps the session usable", %{
      conn: conn
    } do
      {:ok, workspace} = Handbean.WorkspaceStore.ensure_default!()
      :ok = Handbean.WorkspaceSettings.update_permission_mode(workspace["path"], :prompt)
      settings_path = Handbean.WorkspaceSettings.path(workspace["path"])
      original = File.read!(settings_path)
      {:ok, conversation} = Handbean.ConversationStore.create_free(title: "Permission regression")
      {:ok, view, _html} = live(conn, "/c/#{conversation["id"]}")

      assert capture_log(fn ->
               html = render_click(view, "select_permission_mode", %{"mode" => "yolo"})
               assert html =~ "Failed to update permission mode"
             end) =~ "invalid_path"

      assert File.read!(settings_path) == original
      render_click(view, "select_permission_mode", %{})
      render_click(view, "select_permission_mode", %{"mode" => "invalid"})
      assert render(view) =~ "Permission regression"
    end

    test "toggles permission menu and selects new permission mode", %{conn: conn} do
      {:ok, default_ws} = Handbean.WorkspaceStore.ensure_default!()
      workspace_root = default_ws["path"]

      {:ok, view, _html} = live(conn, "/")
      create_default_conversation(view)

      html = render(view)

      # Initial state: menu should not be visible
      refute html =~ "permission-dropdown-menu"
      assert has_element?(view, "button[phx-click='toggle_permission_menu']")

      # Click the permission pill to toggle menu
      view |> element("button[phx-click='toggle_permission_menu']") |> render_click()
      assert render(view) =~ "permission-dropdown-menu"

      refute has_element?(view, "button[phx-value-mode='auto']")
      assert has_element?(view, "button[phx-value-mode='prompt']")
      assert has_element?(view, "button[phx-value-mode='yolo']")

      view
      |> element("button[phx-click='select_permission_mode'][phx-value-mode='auto_review']")
      |> render_click()

      refute render(view) =~ "permission-dropdown-menu"
      assert render(view) =~ "智能审批"

      assert {:ok, settings} = Handbean.WorkspaceSettings.load(workspace_root)
      assert get_in(settings, ["tools", "default_mode"]) == "auto"
      assert get_in(settings, ["tools", "approvals_reviewer"]) == "auto_review"
    end

    test "permission mode changes propagate to other live sessions", %{conn: conn} do
      {:ok, default_ws} = Handbean.WorkspaceStore.ensure_default!()
      workspace_root = default_ws["path"]
      :ok = Handbean.WorkspaceSettings.update_permission_mode(workspace_root, :auto_review)

      {:ok, first_view, _html} = live(conn, "/")
      create_default_conversation(first_view)
      {:ok, second_view, _html} = live(conn, "/")
      create_default_conversation(second_view)

      assert render(first_view) =~ "智能审批"
      assert render(second_view) =~ "智能审批"

      first_view |> element("button[phx-click='toggle_permission_menu']") |> render_click()

      first_view
      |> element("button[phx-click='select_permission_mode'][phx-value-mode='yolo']")
      |> render_click()

      assert render(first_view) =~ "yolo"
      assert render(second_view) =~ "yolo"
      refute render(second_view) =~ "智能审批"
    end

    test "smart approval replaces yolo policy and safe mode restores human review", %{conn: conn} do
      {:ok, default_ws} = Handbean.WorkspaceStore.ensure_default!()
      workspace_root = default_ws["path"]
      settings_path = Handbean.WorkspaceSettings.path(workspace_root)
      original = if File.exists?(settings_path), do: File.read!(settings_path), else: nil

      on_exit(fn ->
        if is_binary(original), do: File.write!(settings_path, original)
      end)

      File.mkdir_p!(Path.dirname(settings_path))

      File.write!(settings_path, """
      {
        // keep me
        "tools": {
          "default_mode": "yolo",
          "allow": ["read"]
        }
      }
      """)

      {:ok, view, _html} = live(conn, "/")
      create_default_conversation(view)

      view |> element("button[phx-click='toggle_permission_menu']") |> render_click()

      view
      |> element("button[phx-click='select_permission_mode'][phx-value-mode='auto_review']")
      |> render_click()

      html = render(view)
      assert html =~ "智能审批"
      assert html =~ "只自动复审本来要问的操作，不扩大权限。"
      refute html =~ "permission-dropdown-menu"

      content = File.read!(settings_path)
      assert content =~ "// keep me"
      assert content =~ "\"default_mode\": \"auto\""
      assert content =~ "\"allow\": [\"read\"]"
      assert content =~ "\"approvals_reviewer\": \"auto_review\""

      {:ok, settings} = Handbean.WorkspaceSettings.load(workspace_root)
      assert get_in(settings, ["tools", "default_mode"]) == "auto"
      assert get_in(settings, ["tools", "approvals_reviewer"]) == "auto_review"

      view |> element("button[phx-click='toggle_permission_menu']") |> render_click()

      view
      |> element("button[phx-click='select_permission_mode'][phx-value-mode='prompt']")
      |> render_click()

      html = render(view)
      assert html =~ "安全模式" or html =~ "Safe Mode"
      refute html =~ "智能审批"

      content = File.read!(settings_path)
      assert content =~ "// keep me"
      assert content =~ "\"default_mode\": \"prompt\""
      {:ok, settings} = Handbean.WorkspaceSettings.load(workspace_root)
      assert get_in(settings, ["tools", "default_mode"]) == "prompt"
      assert get_in(settings, ["tools", "approvals_reviewer"]) == "user"
      assert get_in(settings, ["tools", "allow"]) == ["read"]
    end

    for action <- ["approve_all_tools", "deny_all_tools"] do
      @approval_action action
      test "#{action} defaults to once without saving workspace rules", %{conn: conn} do
        {:ok, workspace} = Handbean.WorkspaceStore.ensure_default!()
        :ok = Handbean.WorkspaceSettings.update_permission_mode(workspace["path"], :prompt)
        {:ok, before_settings} = Handbean.WorkspaceSettings.load(workspace["path"])
        {:ok, view, _html} = live(conn, "/")
        create_default_conversation(view)

        pending = %{
          type: :tool_approval,
          action_requests: [
            %{
              tool_call_id: "once-1",
              tool_name: "bash",
              arguments: %{"command" => "git status --short"},
              suggested_pattern: "bash(git status*)"
            }
          ]
        }

        send(view.pid, {:agent_event, agent_event(:tool_approval_requested, pending, 1)})

        view
        |> element(
          "#tool-approval-overlay button[phx-click='#{@approval_action}']:not([phx-value-remember])"
        )
        |> render_click()

        refute has_element?(view, "#tool-approval-overlay")
        assert {:ok, ^before_settings} = Handbean.WorkspaceSettings.load(workspace["path"])
      end
    end

    test "always-allow persists a matcher pattern and skips the next HITL", %{conn: conn} do
      {:ok, default_ws} = Handbean.WorkspaceStore.ensure_default!()
      workspace_root = default_ws["path"]

      :ok = Handbean.WorkspaceSettings.update_permission_mode(workspace_root, :prompt)

      {:ok, view, _html} = live(conn, "/")
      create_default_conversation(view)

      pending = %{
        type: :tool_approval,
        action_requests: [
          %{
            tool_call_id: "b1",
            tool_name: "bash",
            arguments: %{"command" => "git status --short"},
            suggested_pattern: "bash(git status*)"
          }
        ]
      }

      send(view.pid, {:agent_event, agent_event(:tool_approval_requested, pending, 1)})
      html = render(view)

      assert html =~ "tool-approval-overlay"
      assert html =~ "Always allow"
      assert html =~ "bash(git status*)"

      assert has_element?(
               view,
               "#approval-more-options:not([open]) summary",
               "More approval options"
             )

      assert has_element?(view, "#approval-more-options button[phx-value-remember='session']")
      assert has_element?(view, "#approval-more-options button[phx-value-remember='always']")
      assert has_element?(view, "#approval-more-options li", "bash(git status*)")

      assert has_element?(
               view,
               "#tool-approval-overlay button[phx-click='approve_all_tools']:not([phx-value-remember])",
               "Allow once"
             )

      assert has_element?(
               view,
               "#tool-approval-overlay button[phx-click='deny_all_tools']",
               "Deny"
             )

      refute has_element?(
               view,
               "#tool-approval-overlay button[phx-click='deny_all_tools'][phx-value-remember]"
             )

      view
      |> element("button[phx-click='approve_all_tools'][phx-value-remember='always']")
      |> render_click()

      refute render(view) =~ "tool-approval-overlay"

      assert {:ok, settings} = Handbean.WorkspaceSettings.load(workspace_root)
      assert "bash(git status*)" in (get_in(settings, ["tools", "allow"]) || [])

      policy = Handbean.Permissions.ToolPolicy.from_workspace(workspace_root)

      assert Handbean.Permissions.ToolPolicy.decision(policy, %{
               name: "bash",
               input: %{"command" => "git status"}
             }) == :auto

      assert Handbean.Permissions.ToolPolicy.decision(policy, %{
               name: "bash",
               input: %{"command" => "rm -rf tmp"}
             }) == :prompt
    end
  end

  describe "settings panel" do
    test "shows memory processing parameters without a global enable switch", %{conn: conn} do
      models_path =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_settings_models_#{System.unique_integer([:positive])}.json"
        )

      write_test_models_config(models_path)
      System.put_env("HANDBEAN_MODELS_FILE", models_path)

      on_exit(fn ->
        System.delete_env("HANDBEAN_MODELS_FILE")
        if File.exists?(models_path), do: File.rm!(models_path)
      end)

      {:ok, view, _html} = live(conn, "/")
      result = view |> element("#open-settings") |> render_click()
      {:ok, settings_view, html} = follow_redirect(result, conn)

      assert html =~ "Model / AI"
      assert has_element?(settings_view, "select[name='om_model']")
      refute has_element?(settings_view, "input[name='om_enabled']")
    end

    test "updates default model and reasoning settings without crashing", %{conn: conn} do
      models_path =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_settings_models_#{System.unique_integer([:positive])}.json"
        )

      write_test_models_config(models_path)
      System.put_env("HANDBEAN_MODELS_FILE", models_path)

      on_exit(fn ->
        System.delete_env("HANDBEAN_MODELS_FILE")
        if File.exists?(models_path), do: File.rm!(models_path)
      end)

      {:ok, view, _html} = live(conn, "/")

      # Open settings panel
      result = view |> element("#open-settings") |> render_click()
      {:ok, settings_view, _html} = follow_redirect(result, conn)

      # Change default model
      html =
        settings_view
        |> element("select[name='default_model']")
        |> render_change(%{"default_model" => "stepfun/step-router-v1"})

      # The default_model option is selected
      assert html =~ "selected"

      # Change reasoning
      html =
        settings_view
        |> element("select[name='reasoning']")
        |> render_change(%{"reasoning" => "high"})

      assert html =~ "selected"
    end
  end
end
