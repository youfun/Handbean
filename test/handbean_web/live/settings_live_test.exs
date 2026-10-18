defmodule HandbeanWeb.SettingsLiveTest do
  @moduledoc """
  Tests for the unified Settings page (SettingsLive).

  Covers:
    - Mount renders settings page with left menu
    - Default tab is Model / AI with form
    - Tab switching works via menu clicks
    - Available Models tab renders nested AvailableModelsLive (text presence,
      interaction tests are in a separate AvailableModelsLive test)
    - Advanced diagnostics render without placeholder-only tabs
    - URL query param sets initial tab
    - Top bar has back-to-workspace link
  """

  use HandbeanWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    home_dir = isolate_sigil_home!()
    write_test_models_config(Path.join(home_dir, ".handbean/models.json"))
    :ok
  end

  # ── Helpers ──

  defp isolate_sigil_home! do
    old_home = System.get_env("HOME")

    home_dir =
      Path.join(System.tmp_dir!(), "sigil_settings_home_#{System.unique_integer([:positive])}")

    System.put_env("HOME", home_dir)

    models_path = Path.join(home_dir, ".handbean/models.json")
    workspaces_path = Path.join(home_dir, ".handbean/workspaces.json")
    workspace_path = Path.join(home_dir, ".handbean/workspace")
    System.put_env("HANDBEAN_MODELS_FILE", models_path)
    System.put_env("HANDBEAN_WORKSPACES_FILE", workspaces_path)
    System.put_env("HANDBEAN_WORKSPACE", workspace_path)

    on_exit(fn ->
      if old_home, do: System.put_env("HOME", old_home), else: System.delete_env("HOME")
      System.delete_env("HANDBEAN_MODELS_FILE")
      System.delete_env("HANDBEAN_WORKSPACES_FILE")
      System.delete_env("HANDBEAN_WORKSPACE")
      if File.exists?(home_dir), do: File.rm_rf!(home_dir)
    end)

    home_dir
  end

  defp write_test_models_config(path) do
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      Jason.encode!(%{
        "defaultProvider" => "stepfun",
        "defaultModel" => "step-router-v1",
        "providers" => %{
          "stepfun" => %{
            "name" => "StepFun",
            "baseUrl" => "https://api.stepfun.com/step_plan/v1",
            "api" => "stepfun-step-plan",
            "provider" => "stepfun",
            "apiKey" => "env:OPENAI_API_KEY",
            "models" => [
              %{
                "id" => "step-router-v1",
                "name" => "Step Router v1",
                "reasoning" => true,
                "defaultReasoning" => "medium",
                "contextWindow" => 256_000,
                "input" => ["text"]
              },
              %{
                "id" => "step-3.5-flash",
                "name" => "Step 3.5 Flash",
                "input" => ["text"],
                "contextWindow" => 128_000
              }
            ]
          },
          "openai" => %{
            "name" => "OpenAI",
            "baseUrl" => "https://api.openai.com/v1",
            "api" => "openai",
            "provider" => "openai",
            "apiKey" => "env:OPENAI_API_KEY",
            "models" => [
              %{
                "id" => "gpt-4o",
                "name" => "GPT-4o",
                "input" => ["text", "image"],
                "contextWindow" => 128_000
              }
            ]
          }
        }
      })
    )
  end

  # ── Tests ──

  describe "GET /settings" do
    test "renders settings page with left menu", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings")

      assert html =~ "Settings"
      assert html =~ "Model / AI"
      assert html =~ "Workspace Models"
      assert html =~ "Available Models"
      assert html =~ "Advanced"
      assert html =~ "UI"
      refute html =~ "Coming soon"
      refute html =~ "即将推出"
    end

    test "has back-to-workspace link", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings")

      assert html =~ "Back to Workspace"
    end

    test "defaults to Model / AI tab showing the form", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings")

      # Form with model selection and reasoning is rendered
      assert html =~ ~s(name="default_model")
      assert html =~ ~s(name="reasoning")
      assert html =~ ~s(name="advisor_model")
      assert html =~ ~s(name="advisor_reasoning")
      assert html =~ ~s(name="om_model")
      assert html =~ ~s(id="default-model-picker-trigger")
      refute html =~ ~s(name="om_enabled")
    end

    test "configures advisor and one shared memory model with supported think levels", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/settings")

      render_change(view, "update_field", %{"advisor_model" => "stepfun/step-router-v1"})

      assert has_element?(
               view,
               ~s(select[name="advisor_reasoning"] option[value="high"])
             )

      render_change(view, "update_field", %{"advisor_reasoning" => "high"})
      render_change(view, "update_field", %{"om_model" => "stepfun/step-router-v1"})

      assert has_element?(view, ~s(select[name="om_model"]))
      assert has_element?(view, ~s(select[name="om_reasoning"] option[value="low"]))
      refute has_element?(view, ~s(select[name="om_observer_model"]))
      refute has_element?(view, ~s(select[name="om_reflector_model"]))

      render_change(view, "update_field", %{"om_reasoning" => "low"})
      view |> element(~s(button[phx-click="save_settings"])) |> render_click()

      saved = Handbean.Settings.global_model_ai()
      assert saved.advisor_model == "stepfun/step-router-v1"
      assert saved.advisor_reasoning == "high"
      assert saved.om_model == "stepfun/step-router-v1"
      assert saved.om_reasoning == "low"
    end

    test "Chinese model settings translate advisor and memory labels and reasoning options", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/settings?locale=zh_CN")

      render_change(view, "update_field", %{"advisor_model" => "stepfun/step-router-v1"})
      render_change(view, "update_field", %{"om_model" => "stepfun/step-router-v1"})

      html = render(view)
      assert html =~ "思考等级"
      assert html =~ "记忆模型"
      assert html =~ "顾问 Agent 使用的思考等级。"
      assert html =~ "记忆反思使用的思考等级。"
      assert html =~ "记忆反思"
      assert html =~ "用于从压缩后的对话生成可审核的记忆候选。"
      refute html =~ "Think level"
      refute html =~ "Reasoning level used"

      for field <- ["advisor_reasoning", "om_reasoning"] do
        assert has_element?(view, ~s(select[name="#{field}"] option[value=""]), "模型默认值")
        assert has_element?(view, ~s(select[name="#{field}"] option[value="medium"]), "中")
        assert has_element?(view, ~s(select[name="#{field}"] option[value="high"]), "高")
        refute has_element?(view, ~s(select[name="#{field}"]), "Medium")
        refute has_element?(view, ~s(select[name="#{field}"]), "High")
      end
    end

    test "keeps configured advisor and memory models visible when the catalog is temporarily missing them",
         %{conn: conn} do
      assert :ok =
               Handbean.Settings.save_global(%{
                 "advisor" => %{
                   "model" => "anthropic/claude-opus-4-6",
                   "reasoning" => "high"
                 },
                 "observational_memory" => %{
                   "enabled" => true,
                   "model" => "xai/grok-4-1-fast-non-reasoning",
                   "reasoning" => "low"
                 }
               })

      {:ok, view, _html} = live(conn, "/settings")

      assert has_element?(
               view,
               ~s(select[name="advisor_model"] option[value="anthropic/claude-opus-4-6"][selected])
             )

      assert has_element?(
               view,
               ~s(select[name="om_model"] option[value="xai/grok-4-1-fast-non-reasoning"][selected])
             )

      view |> element(~s(button[phx-click="save_settings"])) |> render_click()

      saved = Handbean.Settings.global_model_ai()
      assert saved.advisor_model == "anthropic/claude-opus-4-6"
      assert saved.advisor_reasoning == "high"
      assert saved.om_model == "xai/grok-4-1-fast-non-reasoning"
      assert saved.om_reasoning == "low"
    end

    test "first visit seeds default models into the Model / AI picker", %{conn: conn} do
      models_path = System.fetch_env!("HANDBEAN_MODELS_FILE")
      File.rm(models_path)
      refute File.exists?(models_path)

      {:ok, _view, html} = live(conn, "/settings?tab=model_ai")

      assert File.exists?(models_path)
      assert html =~ ~s(name="default_model")
      assert html =~ "Step Router v1"
    end

    test "Model / AI model lists use global models even when workspace policy is restricted",
         %{conn: conn} do
      {:ok, default_workspace} = Handbean.WorkspaceStore.ensure_default!()

      settings_path = Handbean.WorkspaceSettings.path(default_workspace["path"])
      File.mkdir_p!(Path.dirname(settings_path))

      File.write!(
        settings_path,
        Jason.encode!(%{
          "models" => %{
            "allow" => %{
              "providers" => %{
                "stepfun" => %{"models" => ["step-router-v1"]}
              }
            }
          }
        })
      )

      {:ok, _view, html} = live(conn, "/settings")

      assert html =~ "stepfun / Step Router v1"
      assert html =~ "stepfun / Step 3.5 Flash"
    end

    test "can switch to Available Models tab and see provider list", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      view
      |> element(~s|button[phx-value-tab="available_models"]|)
      |> render_click()

      html = render(view)

      # Nested AvailableModelsLive renders provider list from models.json
      assert html =~ "Providers"
      assert html =~ "StepFun"
      assert html =~ "OpenAI"
    end

    test "Local WebGPU tab exposes the browser-only capability probe", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      view
      |> element(~s|button[phx-value-tab="local_webgpu"]|)
      |> render_click()

      html = render(view)
      assert html =~ "Local WebGPU capability probe"
      assert has_element?(view, ~s|button[phx-value-tab="local_webgpu"]|, "Advanced")
      assert html =~ ~s(id="local-webgpu-probe")
      assert html =~ ~s(phx-hook="LocalWebGPUProbe")
      assert html =~ ~s(data-probe-check="compute")
      assert html =~ "does not download or run a model"
    end

    test "Workspace Models tab edits current workspace policy", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      view
      |> element(~s|button[phx-value-tab="workspace_models"]|)
      |> render_click()

      html = render(view)
      assert html =~ "Current workspace models"
      assert html =~ "Unrestricted"

      view
      |> element(~s|button[phx-click="set_workspace_model_mode"][phx-value-mode="restricted"]|)
      |> render_click()

      html = render(view)
      assert html =~ "Step Router v1"
      assert html =~ "Step 3.5 Flash"

      view
      |> element(~s|input[phx-click="toggle_workspace_model"][phx-value-model="step-router-v1"]|)
      |> render_click()

      render_change(view, "set_workspace_default_model", %{
        "default_model" => "stepfun/step-router-v1"
      })

      view
      |> element(~s|button[phx-click="save_workspace_models"]|)
      |> render_click()

      default_workspace =
        Handbean.WorkspaceStore.list()
        |> Enum.find(&(&1["default"] || &1["id"] == "default"))

      workspace_settings_path = Handbean.WorkspaceSettings.path(default_workspace["path"])

      {:ok, settings} =
        workspace_settings_path
        |> File.read!()
        |> Jason.decode()

      assert get_in(settings, ["models", "default"]) == %{
               "provider" => "stepfun",
               "model" => "step-router-v1"
             }

      assert get_in(settings, ["models", "allow", "providers", "stepfun", "models"]) == [
               "step-router-v1"
             ]
    end

    test "restricted workspace models can be searched and selected by provider", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings?tab=workspace_models")

      view
      |> element(~s|button[phx-click="set_workspace_model_mode"][phx-value-mode="restricted"]|)
      |> render_click()

      assert has_element?(view, "#workspace-model-filter")
      assert has_element?(view, ".settings-model-row", "Step Router v1")
      assert has_element?(view, ".settings-model-row", "Step 3.5 Flash")

      view
      |> form(~s|form[phx-change="filter_workspace_models"]|, %{query: "router"})
      |> render_change()

      assert has_element?(view, ".settings-model-row", "Step Router v1")
      refute has_element?(view, ".settings-model-row", "Step 3.5 Flash")

      view
      |> element(
        ~s|button[phx-click="set_workspace_provider_models"][phx-value-provider="stepfun"][phx-value-action="all"]|
      )
      |> render_click()

      view
      |> form(~s|form[phx-change="filter_workspace_models"]|, %{query: ""})
      |> render_change()

      assert has_element?(
               view,
               ~s|input[phx-value-model="step-router-v1"][checked]|
             )

      assert has_element?(
               view,
               ~s|input[phx-value-model="step-3.5-flash"][checked]|
             )
    end

    test "Available Models tab shows default provider badge", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      view
      |> element(~s|button[phx-value-tab="available_models"]|)
      |> render_click()

      html = render(view)

      assert html =~ "Default"
    end

    test "switching back to Model / AI tab shows form again", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      view
      |> element(~s|button[phx-value-tab="available_models"]|)
      |> render_click()

      view
      |> element(~s|button[phx-value-tab="model_ai"]|)
      |> render_click()

      html = render(view)

      assert html =~ ~s(name="default_model")
    end

    test "does not expose inactive placeholder settings", %{conn: conn} do
      {:ok, view, html} = live(conn, "/settings")

      refute has_element?(view, ~s|button[phx-value-tab="coming_soon"]|)
      refute html =~ "coming soon"

      {:ok, _view, legacy_html} = live(conn, "/settings?tab=coming_soon")
      assert legacy_html =~ ~s(name="default_model")
    end

    test "Workspace Memory tab renders isolated memories and supports filters and search", %{
      conn: conn
    } do
      {:ok, workspace} = Handbean.WorkspaceStore.ensure_default!()
      workspace_id = workspace["id"]

      {:ok, long_term} =
        Handbean.Memory.MemoryStore.learn("Current workspace durable rule", :rule,
          short_term: false,
          workspace_id: workspace_id,
          memory_scope: :workspace,
          privacy_mode: :standard
        )

      {:ok, short_term} =
        Handbean.Memory.MemoryStore.learn("Current workspace searchable pattern", :pattern,
          short_term: true,
          workspace_id: workspace_id,
          memory_scope: :workspace,
          privacy_mode: :standard
        )

      {:ok, _other_workspace} =
        Handbean.Memory.MemoryStore.learn("Other workspace must stay private", :fact,
          short_term: false,
          workspace_id: "other-workspace",
          memory_scope: :workspace,
          privacy_mode: :standard
        )

      {:ok, global} =
        Handbean.Memory.MemoryStore.learn("Shared global preference", :preference,
          short_term: false,
          memory_scope: :global,
          privacy_mode: :standard
        )

      expired_at =
        DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

      {:ok, expired} =
        Handbean.Repo.insert(%Handbean.Memory.Engram{
          content: "Expired workspace context",
          kind: :context,
          short_term: true,
          expires_at: expired_at,
          metadata: %{scope: "workspace", workspace_id: workspace_id}
        })

      path =
        "/settings?tab=workspace_memory&workspace_id=#{workspace_id}&conversation_id=conv_memory"

      {:ok, view, html} = live(conn, path)
      assert html =~ "Workspace Memory"
      assert html =~ ~s(href="/w/#{workspace_id}/c/conv_memory")

      memory = find_live_child(view, "settings-workspace-memory")
      assert has_element?(memory, "#workspace-memory-toggle[aria-checked=true]")

      render_click(element(memory, "#workspace-memory-toggle"))
      assert has_element?(memory, "#workspace-memory-toggle[aria-checked=false]")
      refute Handbean.WorkspaceSettings.builtin_memory_enabled(workspace["path"])

      assert has_element?(memory, "#memory-engram-#{long_term.id}")
      assert has_element?(memory, "#memory-engram-#{short_term.id}")
      refute render(memory) =~ "Other workspace must stay private"
      refute has_element?(memory, "#memory-engram-#{global.id}")

      render_click(element(memory, "#memory-kind-rule"))
      assert has_element?(memory, "#memory-engram-#{long_term.id}")
      refute has_element?(memory, "#memory-engram-#{short_term.id}")

      render_click(element(memory, "#memory-kind-all"))
      render_click(element(memory, "#memory-lifecycle-short_term"))
      assert has_element?(memory, "#memory-engram-#{short_term.id}")
      refute has_element?(memory, "#memory-engram-#{long_term.id}")

      render_change(element(memory, "#memory-filter-form"), %{
        "filters" => %{"query" => "##{long_term.id}", "scope" => "workspace"}
      })

      refute has_element?(memory, "#memory-engram-#{long_term.id}")
      render_click(element(memory, "#memory-lifecycle-active"))
      assert has_element?(memory, "#memory-engram-#{long_term.id}")

      render_change(element(memory, "#memory-filter-form"), %{
        "filters" => %{"query" => "Shared global", "scope" => "both"}
      })

      assert has_element?(memory, "#memory-engram-#{global.id}")
      refute render(memory) =~ "Other workspace must stay private"

      render_change(element(memory, "#memory-filter-form"), %{
        "filters" => %{"query" => "", "scope" => "workspace"}
      })

      render_click(element(memory, "#memory-lifecycle-expired"))
      assert has_element?(memory, "#memory-engram-#{expired.id}")
      assert render(memory) =~ "Expired workspace context"
    end

    test "promotes a visible memory and preserves the active filters", %{conn: conn} do
      {:ok, workspace} = Handbean.WorkspaceStore.ensure_default!()
      workspace_id = workspace["id"]

      {:ok, memory} =
        Handbean.Memory.MemoryStore.learn("Promote this exact memory", :fact,
          short_term: true,
          workspace_id: workspace_id,
          memory_scope: :workspace,
          privacy_mode: :standard,
          metadata: %{scope: "workspace", workspace_id: workspace_id, source: "manual"}
        )

      {:ok, view, _html} =
        live(conn, "/settings?tab=workspace_memory&workspace_id=#{workspace_id}")

      child = find_live_child(view, "settings-workspace-memory")

      render_change(element(child, "#memory-filter-form"), %{
        "filters" => %{"query" => "##{memory.id}", "scope" => "workspace"}
      })

      render_click(element(child, "#memory-lifecycle-short_term"))
      assert has_element?(child, "#memory-engram-#{memory.id}")
      assert has_element?(child, "#memory-engram-#{memory.id} .memory-source", "manual")
      assert has_element?(child, "#memory-engram-#{memory.id} .memory-scope", "工作区范围")

      render_click(element(child, "#memory-promote-#{memory.id}"))

      refute has_element?(child, "#memory-engram-#{memory.id}")
      assert has_element?(child, ~s|#memory-search[value="##{memory.id}"]|)
      assert has_element?(child, "#memory-lifecycle-short_term.active")

      assert [%{id: id, short_term: false}] =
               Handbean.Memory.MemoryStore.list_engrams(
                 workspace_id: workspace_id,
                 scope: :workspace,
                 lifecycle: :long_term,
                 query: "##{memory.id}"
               )

      assert id == memory.id
    end

    test "edits memory content and kind through the scoped store", %{conn: conn} do
      {:ok, workspace} = Handbean.WorkspaceStore.ensure_default!()
      workspace_id = workspace["id"]

      {:ok, memory} =
        Handbean.Memory.MemoryStore.learn("Content before editing", :fact,
          short_term: false,
          workspace_id: workspace_id,
          memory_scope: :workspace,
          privacy_mode: :standard,
          metadata: %{scope: "workspace", workspace_id: workspace_id, source: "reflection"}
        )

      {:ok, view, _html} =
        live(conn, "/settings?tab=workspace_memory&workspace_id=#{workspace_id}")

      child = find_live_child(view, "settings-workspace-memory")
      render_click(element(child, "#memory-edit-#{memory.id}"))
      assert has_element?(child, "#memory-edit-form-#{memory.id}")

      child
      |> form("#memory-edit-form-#{memory.id}", %{
        "memory" => %{"content" => "Content after editing", "kind" => "preference"}
      })
      |> render_submit()

      assert has_element?(child, "#memory-engram-#{memory.id}", "Content after editing")
      assert has_element?(child, "#memory-engram-#{memory.id} .memory-kind", "偏好")

      assert [%{content: "Content after editing", kind: :preference}] =
               Handbean.Memory.MemoryStore.list_engrams(
                 workspace_id: workspace_id,
                 scope: :workspace,
                 lifecycle: :active,
                 query: "##{memory.id}"
               )
    end

    test "requires confirmation and deletes memory through the scoped store", %{conn: conn} do
      {:ok, workspace} = Handbean.WorkspaceStore.ensure_default!()
      workspace_id = workspace["id"]

      {:ok, memory} =
        Handbean.Memory.MemoryStore.learn("Delete this exact memory", :rule,
          short_term: false,
          workspace_id: workspace_id,
          memory_scope: :workspace,
          privacy_mode: :standard,
          metadata: %{scope: "workspace", workspace_id: workspace_id, source: "manual"}
        )

      {:ok, view, _html} =
        live(conn, "/settings?tab=workspace_memory&workspace_id=#{workspace_id}")

      child = find_live_child(view, "settings-workspace-memory")
      render_click(element(child, "#memory-delete-#{memory.id}"))

      assert has_element?(child, "#memory-delete-confirm-#{memory.id}")
      assert has_element?(child, "#memory-engram-#{memory.id}")

      render_click(element(child, "#memory-delete-confirm-#{memory.id} button[phx-click=delete]"))

      refute has_element?(child, "#memory-engram-#{memory.id}")

      assert [] ==
               Handbean.Memory.MemoryStore.list_engrams(
                 workspace_id: workspace_id,
                 scope: :workspace,
                 lifecycle: :all,
                 query: "##{memory.id}"
               )
    end

    test "refuses a forged mutation from another workspace and shows an error", %{conn: conn} do
      {:ok, workspace} = Handbean.WorkspaceStore.ensure_default!()
      workspace_id = workspace["id"]
      other_workspace_id = "other-workspace"

      {:ok, other_memory} =
        Handbean.Memory.MemoryStore.learn("Other workspace mutation target", :fact,
          short_term: true,
          workspace_id: other_workspace_id,
          memory_scope: :workspace,
          privacy_mode: :standard,
          metadata: %{
            scope: "workspace",
            workspace_id: other_workspace_id,
            source: "manual"
          }
        )

      {:ok, view, _html} =
        live(conn, "/settings?tab=workspace_memory&workspace_id=#{workspace_id}")

      child = find_live_child(view, "settings-workspace-memory")
      refute has_element?(child, "#memory-engram-#{other_memory.id}")

      render_click(child, "promote", %{"id" => Integer.to_string(other_memory.id)})

      assert has_element?(child, "#memory-mutation-error[role=alert]")

      assert [%{id: id, short_term: true}] =
               Handbean.Memory.MemoryStore.list_engrams(
                 workspace_id: other_workspace_id,
                 scope: :workspace,
                 lifecycle: :short_term,
                 query: "##{other_memory.id}"
               )

      assert id == other_memory.id
    end

    test "Chinese memory browser shows localized kinds and workspace scope", %{conn: conn} do
      {:ok, workspace} = Handbean.WorkspaceStore.ensure_default!()

      {:ok, memory} =
        Handbean.Memory.MemoryStore.learn("Chinese memory display regression", :fact,
          short_term: false,
          workspace_id: workspace["id"],
          memory_scope: :workspace,
          privacy_mode: :standard
        )

      {:ok, view, _html} =
        live(conn, "/settings?tab=workspace_memory&locale=zh_CN")

      child = find_live_child(view, "settings-workspace-memory")
      assert has_element?(child, ".memory-context", "当前工作区：")
      assert has_element?(child, "#memory-scope option[value=workspace]", "当前工作区")
      refute render(child) =~ "当前工作区模型"

      for {kind, label} <- [
            preference: "偏好",
            rule: "规则",
            pattern: "模式",
            fact: "事实",
            context: "上下文"
          ] do
        assert has_element?(child, "#memory-kind-#{kind}", label)
        refute has_element?(child, "#memory-kind-#{kind}", "#{kind} ·")
      end

      assert has_element?(child, "#memory-engram-#{memory.id} .memory-kind", "事实")
      refute has_element?(child, "#memory-engram-#{memory.id} .memory-kind", "fact")
    end

    test "uses URL query param to set initial tab", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings?tab=available_models")

      assert html =~ "Available Models"
    end

    test "loads specific workspace based on query param", %{conn: conn} do
      # Create a new non-default workspace
      tmp_ws_dir =
        Path.join(System.tmp_dir!(), "handbean_test_ws_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_ws_dir)

      {:ok, ws} = Handbean.WorkspaceStore.add(tmp_ws_dir, name: "Custom Project")

      # Access settings with workspace_id and workspace_models tab
      {:ok, view, _html} = live(conn, "/settings?tab=workspace_models&workspace_id=#{ws["id"]}")
      html = render(view)
      assert html =~ "Custom Project"
      assert html =~ tmp_ws_dir

      # Clean up
      File.rm_rf!(tmp_ws_dir)
    end

    test "back link uses conversation_id and workspace_id if provided", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings?workspace_id=default&conversation_id=conv_123")
      assert html =~ ~s(href="/w/default/c/conv_123")
    end

    test "theme choice is saved and painted on the document", %{conn: conn} do
      {:ok, view, html} = live(conn, "/settings?tab=ui")

      assert html =~ ~s(id="ui-theme-light")
      assert html =~ ~s(data-theme)

      view |> element("#ui-theme-dark") |> render_click()

      assert Handbean.Settings.UI.theme() == "dark"
      assert render(view) =~ ~s(id="ui-theme-dark")
      assert_push_event(view, "set-theme", %{theme: "dark"})

      view |> element("#ui-theme-system") |> render_click()

      assert Handbean.Settings.UI.theme() == "system"
      assert_push_event(view, "set-theme", %{theme: "system"})
    end

    test "select_tab preserves workspace_id and conversation_id in the URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings?workspace_id=default&conversation_id=conv_123")

      view
      |> element(~s|button[phx-value-tab="workspace_models"]|)
      |> render_click()

      # We can check that the back link still has the correct href after patch
      html = render(view)
      assert html =~ ~s(href="/w/default/c/conv_123")
    end
  end
end
