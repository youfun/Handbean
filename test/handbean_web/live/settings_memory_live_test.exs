defmodule HandbeanWeb.SettingsMemoryLiveTest do
  use HandbeanWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    home_dir = isolate_sigil_home!()
    write_test_models_config(Path.join(home_dir, ".handbean/models.json"))
    :ok
  end

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
                "reasoningLevels" => ["low", "medium", "high"],
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

  describe "GET /settings?tab=workspace_memory" do
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

      assert has_element?(
               child,
               "#memory-engram-#{memory.id} .memory-source",
               "没有精确来源"
             )

      refute has_element?(child, "#memory-engram-#{memory.id} .memory-source", "manual")
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

    test "renders exact, source-less, and legacy provenance without metadata fallback", %{
      conn: conn
    } do
      {:ok, workspace} = Handbean.WorkspaceStore.ensure_default!()
      workspace_id = workspace["id"]
      conversation_id = "memory-ui-source-#{Ecto.UUID.generate()}"

      assert {:ok, _conversation} =
               Handbean.ConversationStore.create(workspace_id, id: conversation_id)

      assert {:ok, source_entry} =
               Handbean.ConversationTranscriptStore.append(conversation_id, %{
                 "id" => "memory-ui-entry",
                 "role" => "user",
                 "content" => "exact memory evidence"
               })

      citation = %{
        conversation_id: conversation_id,
        entry_id: source_entry["id"],
        sequence: source_entry["sequence"],
        revision: source_entry["revision"]
      }

      assert {:ok, sourced} =
               Handbean.Memory.MemoryStore.learn("Sourced UI memory", :fact,
                 workspace_id: workspace_id,
                 memory_scope: :workspace,
                 provenance: %{actor: :agent_tool, citations: [citation]}
               )

      assert {:ok, source_less} =
               Handbean.Memory.MemoryStore.learn("Source-less UI memory", :rule,
                 workspace_id: workspace_id,
                 memory_scope: :workspace,
                 metadata: %{"source" => "stale metadata"}
               )

      assert {:ok, legacy} =
               Handbean.Repo.insert(%Handbean.Memory.Engram{
                 content: "Imported legacy UI memory",
                 kind: :context,
                 short_term: false,
                 metadata: %{"scope" => "workspace", "workspace_id" => workspace_id}
               })

      assert {:ok, _event} =
               Handbean.Repo.insert(
                 Handbean.Memory.EngramEvent.changeset(%Handbean.Memory.EngramEvent{}, %{
                   engram_id: legacy.id,
                   engram_revision: legacy.revision,
                   kind: :imported,
                   actor: :legacy,
                   metadata: %{}
                 })
               )

      {:ok, view, _html} =
        live(conn, "/settings?tab=workspace_memory&workspace_id=#{workspace_id}&locale=zh_CN")

      child = find_live_child(view, "settings-workspace-memory")

      assert has_element?(
               child,
               "#memory-engram-#{sourced.id} .memory-link[href='/w/#{workspace_id}/c/#{conversation_id}#memory-ui-entry']",
               "Agent 工具 · 证据 · 可查看"
             )

      assert has_element?(
               child,
               "#memory-engram-#{source_less.id} .memory-source",
               "系统 · 操作记录 · 没有精确来源"
             )

      refute has_element?(child, "#memory-engram-#{source_less.id} .memory-source", "未知来源")

      assert has_element?(
               child,
               "#memory-engram-#{legacy.id} .memory-source",
               "旧版记录 · 旧版来源 · 旧版来源未精确定位"
             )
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

    test "English memory browser uses memory-specific filter translations", %{conn: conn} do
      {:ok, _workspace} = Handbean.WorkspaceStore.ensure_default!()
      {:ok, view, _html} = live(conn, "/settings?tab=workspace_memory&locale=en")
      child = find_live_child(view, "settings-workspace-memory")

      assert has_element?(child, "#memory-kind-all", "All")
      assert has_element?(child, "#memory-scope option[value=workspace]", "Current workspace")
      refute render(child) =~ "Disable all"
      refute render(child) =~ "Current workspace models"
    end
  end
end
