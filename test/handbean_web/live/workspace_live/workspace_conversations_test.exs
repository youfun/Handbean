defmodule HandbeanWeb.WorkspaceLive.WorkspaceConversationsTest do
  use HandbeanWeb.WorkspaceLiveCase

  defmodule BlockingModelProvider do
    @behaviour Handbean.Agent.Provider

    @impl true
    def complete(_messages, _tools, config) do
      send(config.notify, {:model_submission_blocked, self()})

      receive do
        :release ->
          {:ok,
           %{
             stop_reason: :end_turn,
             messages: [Handbean.Agent.Message.assistant("done")],
             usage: %{input_tokens: 1, output_tokens: 1},
             response_metadata: %{}
           }}
      after
        5_000 -> raise "model submission fixture timed out"
      end
    end

    @impl true
    def stream(messages, tools, config, _on_chunk), do: complete(messages, tools, config)
  end

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

    test "delegated conversations display their pinned model instead of a stale selection", %{
      conn: conn
    } do
      configure_test_models!()

      {:ok, parent} =
        Handbean.ConversationStore.create("default",
          title: "Delegation parent",
          selected_model: "stepfun/step-router-v1"
        )

      {:ok, child} =
        Handbean.ConversationStore.create("default",
          title: "Pinned child",
          parent_conversation_id: parent["id"],
          selected_model: "stepfun/step-router-v1",
          collaboration: %{
            "read_only" => true,
            "provider" => "sui2api",
            "model" => "gpt-5.5"
          }
        )

      {:ok, view, _html} = live(conn, "/")
      render_async(view, 5_000)

      view
      |> element(
        ".conversation-item[phx-click='select_conversation'][phx-value-id='#{child["id"]}']"
      )
      |> render_click()

      assert has_element?(view, "#model-picker option[value='sui2api/gpt-5.5'][selected]")
    end

    test "new conversations without a default inherit the model and retain independent selections",
         %{
           conn: conn
         } do
      models_path =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_per_conversation_models_#{System.unique_integer([:positive])}.json"
        )

      write_test_models_config(models_path)
      System.put_env("HANDBEAN_MODELS_FILE", models_path)

      on_exit(fn ->
        System.delete_env("HANDBEAN_MODELS_FILE")
        if File.exists?(models_path), do: File.rm!(models_path)
      end)

      {:ok, view, _html} = live(conn, "/")
      first_conversation_id = create_default_conversation(view)

      render_change(view, "select_model", %{"model" => "sui2api/gpt-5.5"})

      assert has_element?(view, "#model-picker option[value='sui2api/gpt-5.5'][selected]")

      choose_new_conversation_project(view, "default")

      second_html = render(view)
      second_conversation_id = session_id_from_html(second_html)
      assert second_conversation_id != first_conversation_id
      assert has_element?(view, "#model-picker option[value='sui2api/gpt-5.5'][selected]")

      assert {:ok, %{"selected_model" => "sui2api/gpt-5.5"}} =
               Handbean.ConversationStore.get(second_conversation_id)

      render_change(view, "select_model", %{"model" => "stepfun/step-router-v1"})

      assert has_element?(view, "#model-picker option[value='stepfun/step-router-v1'][selected]")

      assert {:ok, %{"selected_model" => "stepfun/step-router-v1"}} =
               Handbean.ConversationStore.get(second_conversation_id)

      assert {:ok, %{"selected_model" => "sui2api/gpt-5.5"}} =
               Handbean.ConversationStore.get(first_conversation_id)

      view
      |> element(
        ".conversation-item[phx-click='select_conversation'][phx-value-id='#{first_conversation_id}']"
      )
      |> render_click()

      assert has_element?(view, "#model-picker option[value='sui2api/gpt-5.5'][selected]")

      view
      |> element(
        ".conversation-item[phx-click='select_conversation'][phx-value-id='#{second_conversation_id}']"
      )
      |> render_click()

      assert has_element?(view, "#model-picker option[value='stepfun/step-router-v1'][selected]")
    end

    test "rejects a forged model selection without changing conversation metadata", %{conn: conn} do
      configure_test_models!()
      {:ok, view, _html} = live(conn, "/")
      conversation_id = create_default_conversation(view)

      assert {:ok, before} = Handbean.ConversationStore.get_metadata(conversation_id)
      render_change(view, "select_model", %{"model" => "forged/missing-model"})

      assert has_element?(view, ".composer-error", "Selected model is unavailable")
      assert {:ok, after_selection} = Handbean.ConversationStore.get_metadata(conversation_id)
      assert after_selection["selected_model"] == before["selected_model"]
    end

    test "rejects a model removed from configuration after mount", %{conn: conn} do
      models_path = configure_test_models!()
      {:ok, view, _html} = live(conn, "/")
      conversation_id = create_default_conversation(view)
      assert {:ok, before} = Handbean.ConversationStore.get_metadata(conversation_id)

      config = models_path |> File.read!() |> Handbean.JSON.decode!()
      config = update_in(config, ["providers"], &Map.delete(&1, "sui2api"))
      File.write!(models_path, Handbean.JSON.encode!(config))

      render_change(view, "select_model", %{"model" => "sui2api/gpt-5.5"})

      assert has_element?(view, ".composer-error", "Model switch failed")
      assert {:ok, after_selection} = Handbean.ConversationStore.get_metadata(conversation_id)
      assert after_selection["selected_model"] == before["selected_model"]
    end

    test "durable model startup replaces stale caller provider config and fails when removed", %{
      ws_dir: ws_dir
    } do
      models_path = configure_test_models!()

      assert {:ok, conversation} =
               Handbean.ConversationStore.create("default",
                 selected_model: "sui2api/gpt-5.5",
                 selected_reasoning_level: nil
               )

      stale_opts = [
        workspace_path: ws_dir,
        working_directory: ws_dir,
        selected_model: "sui2api/gpt-5.5",
        model: "gpt-5.5",
        provider: BlockingModelProvider,
        provider_config: %{stale_marker: true},
        tools: [],
        source: :web
      ]

      run_opts =
        Handbean.Agent.Coordinator.RunOptions.build(conversation["id"], stale_opts)

      refute Keyword.has_key?(run_opts, :provider)
      refute run_opts[:provider_config][:stale_marker]
      assert run_opts[:provider_config][:model] == "gpt-5.5"
      assert :ok = Handbean.Agent.Coordinator.RunOptions.validate(run_opts)

      config = models_path |> File.read!() |> Handbean.JSON.decode!()
      config = update_in(config, ["providers"], &Map.delete(&1, "sui2api"))
      File.write!(models_path, Handbean.JSON.encode!(config))

      removed_opts =
        Handbean.Agent.Coordinator.RunOptions.build(conversation["id"], stale_opts)

      refute Keyword.has_key?(removed_opts, :provider)
      assert {:error, error} = Handbean.Agent.Coordinator.RunOptions.validate(removed_opts)
      assert error =~ "not allowed"
    end

    test "selected model requests the active Runner switch before persistence", %{
      conn: conn,
      ws_dir: ws_dir
    } do
      configure_test_models!()

      {:ok, conversation} =
        Handbean.ConversationStore.create("default", title: "Active model submission")

      assert {:ok, _} =
               Handbean.Permissions.ConversationMode.update(conversation["id"], :yolo,
                 source: :test
               )

      assert {:ok, %{run_pid: runner}} =
               Handbean.Agent.Coordinator.start_run(conversation["id"], "start",
                 workspace_path: ws_dir,
                 working_directory: ws_dir,
                 selected_model: "stepfun/step-router-v1",
                 model: "step-router-v1",
                 reasoning_level: "medium",
                 provider: BlockingModelProvider,
                 provider_config: %{notify: self()},
                 tools: [],
                 permission_mode: :yolo,
                 source: :web,
                 streaming: false,
                 max_turns: 1
               )

      assert_receive {:model_submission_blocked, task}, 2_000
      {:ok, view, _html} = live(conn, "/w/default/c/#{conversation["id"]}")
      {:ok, stale_view, _html} = live(conn, "/w/default/c/#{conversation["id"]}")

      render_change(view, "select_model", %{"model" => "sui2api/gpt-5.5"})

      assert {:ok, %{pending_model_switch: %{model_ref: "sui2api/gpt-5.5", revision: revision}}} =
               Handbean.Agent.Runner.status(conversation["id"])

      render_change(view, "select_model", %{"model" => "sui2api/gpt-5.5"})

      assert {:ok, %{pending_model_switch: %{revision: ^revision}}} =
               Handbean.Agent.Runner.status(conversation["id"])

      stale_view
      |> element("#composer")
      |> render_change(%{
        "_target" => ["message"],
        "message" => "stale draft",
        "model" => "stepfun/step-router-v1",
        "reasoning" => "medium"
      })

      stale_view
      |> form("#composer", %{
        "message" => "",
        "model" => "stepfun/step-router-v1"
      })
      |> render_submit()

      assert {:ok, %{pending_model_switch: %{model_ref: "sui2api/gpt-5.5", revision: ^revision}}} =
               Handbean.Agent.Runner.status(conversation["id"])

      assert {:ok, %{"selected_model" => "sui2api/gpt-5.5"}} =
               Handbean.ConversationStore.get_metadata(conversation["id"])

      view
      |> form("#composer", %{
        "message" => "/model stepfun/step-router-v1",
        "model" => "sui2api/gpt-5.5"
      })
      |> render_submit()

      assert {:ok, %{pending_model_switch: %{model_ref: "stepfun/step-router-v1"}}} =
               Handbean.Agent.Runner.status(conversation["id"])

      assert {:ok, %{"selected_model" => "stepfun/step-router-v1"}} =
               Handbean.ConversationStore.get_metadata(conversation["id"])

      monitor = Process.monitor(runner)
      send(task, :release)
      _ = Handbean.Agent.Runner.cancel(conversation["id"])
      assert_receive {:DOWN, ^monitor, :process, ^runner, _reason}, 2_000
    end

    test "sending in a newly added workspace creates the first conversation", %{conn: conn} do
      project_dir =
        Path.join(
          System.tmp_dir!(),
          "sigil_send_added_project_#{System.unique_integer([:positive])}"
        )

      models_path =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_send_added_models_#{System.unique_integer([:positive])}.json"
        )

      File.mkdir_p!(project_dir)
      write_test_models_config(models_path)
      System.put_env("HANDBEAN_MODELS_FILE", models_path)

      try do
        {:ok, view, _html} = live(conn, "/")

        view |> element("#activity-bar button[phx-click='open_add_project']") |> render_click()
        view |> render_keyup("update_add_path", %{"value" => project_dir})
        view |> render_keyup("update_add_name", %{"value" => "Send Project"})
        view |> element("button[phx-click='confirm_add_project']") |> render_click()

        initial_id = render(view) |> session_id_from_html()

        view
        |> element("#composer")
        |> render_submit(%{"message" => "你好", "model" => "sui2api/gpt-5.5"})

        rendered = render(view)
        refute rendered =~ "sid:none"
        assert rendered =~ "你好"

        {:ok, added_ws} = Handbean.WorkspaceStore.get_by_path(project_dir)
        assert [conversation] = Handbean.ConversationStore.list_for_workspace(added_ws["id"])
        assert conversation["id"] == initial_id

        runner_pid =
          case Registry.lookup(Handbean.AgentRunRegistry, conversation["id"]) do
            [{pid, _value}] -> pid
            [] -> nil
          end

        runner_ref = if is_pid(runner_pid), do: Process.monitor(runner_pid)
        _ = Handbean.Agent.Runner.cancel(conversation["id"])

        if runner_ref,
          do: assert_receive({:DOWN, ^runner_ref, :process, ^runner_pid, _reason}, 1_000)

        case Registry.lookup(Handbean.AgentRunRegistry, conversation["id"]) do
          [{pid, _value}] ->
            ref = Process.monitor(pid)
            assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000

          [] ->
            :ok
        end
      after
        stop_test_runtime!(Process.get(:workspace_live_test_tracker))
        System.delete_env("HANDBEAN_MODELS_FILE")
        if File.exists?(models_path), do: File.rm!(models_path)
        File.rm_rf!(project_dir)
      end
    end

    test "select_workspace creates an active conversation when only archived conversations exist",
         %{
           conn: conn
         } do
      project_dir =
        Path.join(
          System.tmp_dir!(),
          "sigil_archived_project_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(project_dir)

      try do
        {:ok, view, _html} = live(conn, "/")

        view |> element("#activity-bar button[phx-click='open_add_project']") |> render_click()
        view |> render_keyup("update_add_path", %{"value" => project_dir})
        view |> render_keyup("update_add_name", %{"value" => "Archived Project"})
        view |> element("button[phx-click='confirm_add_project']") |> render_click()

        {:ok, added_ws} = Handbean.WorkspaceStore.get_by_path(project_dir)
        assert [initial] = Handbean.ConversationStore.list_for_workspace(added_ws["id"])
        {:ok, _archived} = Handbean.ConversationStore.archive(initial["id"])

        choose_new_conversation_project(view, added_ws["id"])

        rendered = render(view)
        assert rendered =~ "Archived Project"
        refute rendered =~ "sid:none"

        active =
          added_ws["id"]
          |> Handbean.ConversationStore.list_for_workspace(include_archived?: false)

        assert length(active) == 1

        archived =
          added_ws["id"]
          |> Handbean.ConversationStore.list_for_workspace(include_archived?: true)
          |> Enum.filter(&Map.get(&1, "archived_at"))

        assert length(archived) == 1
      after
        File.rm_rf!(project_dir)
      end
    end

    test "parent thread toggle persists across remounts without selecting the parent", %{
      conn: conn
    } do
      {:ok, workspace} = Handbean.WorkspaceStore.ensure_default!()

      {:ok, parent} =
        Handbean.ConversationStore.create(workspace["id"],
          id: "thread-collapse-parent",
          title: "Collapsible parent"
        )

      {:ok, child} =
        Handbean.ConversationStore.create(workspace["id"],
          id: "thread-collapse-child",
          title: "Nested child",
          parent_conversation_id: parent["id"]
        )

      {:ok, other_parent} =
        Handbean.ConversationStore.create(workspace["id"],
          id: "thread-collapse-other-parent",
          title: "Other collapsible parent"
        )

      {:ok, other_child} =
        Handbean.ConversationStore.create(workspace["id"],
          id: "thread-collapse-other-child",
          title: "Other nested child",
          parent_conversation_id: other_parent["id"]
        )

      {:ok, view, _html} = live(conn, "/")
      render_async(view, 5_000)

      {:ok, stale_view, _html} = live(conn, "/")
      render_async(stale_view, 5_000)

      assert has_element?(view, "#conversation-#{child["id"]}")
      assert has_element?(view, "#thread-toggle-#{parent["id"]}[aria-expanded='true']")

      selected_before = view |> render() |> session_id_from_html()
      view |> element("#thread-toggle-#{parent["id"]}") |> render_click()

      refute has_element?(view, "#conversation-#{child["id"]}")
      assert has_element?(view, "#thread-toggle-#{parent["id"]}[aria-expanded='false']")
      assert view |> render() |> session_id_from_html() == selected_before

      stale_view |> element("#thread-toggle-#{other_parent["id"]}") |> render_click()

      {:ok, restored, _html} = live(conn, "/")
      render_async(restored, 5_000)

      refute has_element?(restored, "#conversation-#{child["id"]}")
      refute has_element?(restored, "#conversation-#{other_child["id"]}")

      assert has_element?(
               restored,
               "#thread-toggle-#{parent["id"]}[aria-expanded='false']"
             )

      assert has_element?(
               restored,
               "#thread-toggle-#{other_parent["id"]}[aria-expanded='false']"
             )

      restored |> element("#thread-toggle-#{parent["id"]}") |> render_click()

      assert has_element?(restored, "#conversation-#{child["id"]}")
      refute has_element?(restored, "#conversation-#{other_child["id"]}")

      assert has_element?(
               restored,
               "#thread-toggle-#{parent["id"]}[aria-expanded='true']"
             )

      {:ok, reopened, _html} = live(conn, "/")
      render_async(reopened, 5_000)

      assert has_element?(reopened, "#conversation-#{child["id"]}")
      refute has_element?(reopened, "#conversation-#{other_child["id"]}")
      assert has_element?(reopened, "#thread-toggle-#{parent["id"]}[aria-expanded='true']")

      assert has_element?(
               reopened,
               "#thread-toggle-#{other_parent["id"]}[aria-expanded='false']"
             )
    end

    test "workspace group shows conversation count and collapses", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      {:ok, workspace} = Handbean.WorkspaceStore.ensure_default!()
      ws_id = workspace["id"]

      html = render(view)
      assert html =~ ~r/id="workspace-count-#{ws_id}"[^>]*>\s*\d+\s*</
      assert html =~ ~r/id="free-workspace-count"[^>]*>\s*\d+\s*</
      assert html =~ ~r/id="mobile-workspace-count"[^>]*>\s*\d+\s*</
      assert has_element?(view, "#workspace-toggle-#{ws_id}[aria-expanded='true']")
      assert has_element?(view, "#workspace-conversations-#{ws_id}")
      assert has_element?(view, "#sheet-workspace-count-#{ws_id}")
      assert has_element?(view, "#sheet-free-count")
      assert has_element?(view, "#sheet-free-toggle[aria-expanded='true']")
      assert has_element?(view, "#sheet-free-conversations")
      assert has_element?(view, "#free-workspace-toggle[aria-expanded='true']")
      assert has_element?(view, "#free-conversations")

      view
      |> element(".workspace-header[phx-click='toggle_workspace_group'][phx-value-id='#{ws_id}']")
      |> render_click()

      refute has_element?(view, "#workspace-conversations-#{ws_id}")
      assert has_element?(view, "#workspace-toggle-#{ws_id}[aria-expanded='false']")

      view
      |> element(".workspace-header[phx-click='toggle_workspace_group'][phx-value-id='#{ws_id}']")
      |> render_click()

      assert has_element?(view, "#workspace-conversations-#{ws_id}")

      view |> element("#workspace-toggle-#{ws_id}") |> render_click()

      refute has_element?(view, "#workspace-conversations-#{ws_id}")
      assert has_element?(view, "#workspace-count-#{ws_id}")
      assert has_element?(view, "#workspace-toggle-#{ws_id}[aria-expanded='false']")

      view |> element("#workspace-toggle-#{ws_id}") |> render_click()

      assert has_element?(view, "#workspace-conversations-#{ws_id}")
      assert has_element?(view, "#workspace-toggle-#{ws_id}[aria-expanded='true']")

      view |> element("#free-workspace-toggle") |> render_click()
      refute has_element?(view, "#free-conversations")
      refute has_element?(view, "#sheet-free-conversations")
      assert has_element?(view, "#free-workspace-count")
      assert has_element?(view, "#sheet-free-count")
      assert has_element?(view, "#sheet-free-toggle[aria-expanded='false']")
    end

    test "reopening / restores the last conversation and collapsed groups", %{conn: conn} do
      {:ok, workspace} = Handbean.WorkspaceStore.ensure_default!()
      ws_id = workspace["id"]

      {:ok, older} =
        Handbean.ConversationStore.create(ws_id,
          id: "conv-restore-older",
          title: "Older stay",
          timeline: [
            %{
              "id" => "msg-older",
              "content_type" => "user_msg",
              "role" => "user",
              "content" => "stay on the older chat"
            }
          ]
        )

      {:ok, newer} =
        Handbean.ConversationStore.create(ws_id,
          id: "conv-restore-newer",
          title: "Newer chat",
          timeline: [
            %{
              "id" => "msg-newer",
              "content_type" => "user_msg",
              "role" => "user",
              "content" => "this is the newer chat"
            }
          ]
        )

      {:ok, _} =
        Handbean.ConversationStore.update_meta(older["id"],
          touch: false,
          updated_at: "2000-01-01T00:00:00Z"
        )

      {:ok, _} =
        Handbean.ConversationStore.update_meta(newer["id"],
          touch: false,
          updated_at: "2099-01-01T00:00:00Z"
        )

      {:ok, view, _html} = live(conn, "/")
      html = render_async(view, 5_000)
      assert html =~ "sid:#{newer["id"]}"

      view
      |> element(
        ".conversation-item[phx-click='select_conversation'][phx-value-id='#{older["id"]}']"
      )
      |> render_click()

      view |> element("#free-workspace-toggle") |> render_click()

      {:ok, restored, _html} = live(conn, "/")
      html = render_async(restored, 5_000)
      assert html =~ "sid:#{older["id"]}"
      assert html =~ "stay on the older chat"
      refute html =~ "sid:#{newer["id"]}"
      assert has_element?(restored, "#free-workspace-toggle[aria-expanded='false']")
      refute has_element?(restored, "#free-conversations")

      assert Handbean.Settings.UI.save_last_location(%{
               scope: :workspace,
               workspace_id: ws_id,
               conversation_id: "missing-conversation"
             }) == :ok

      {:ok, _fallback, html} = live(conn, "/")
      refute html =~ "sid:missing-conversation"
    end

    test "reopening / restores a free conversation", %{conn: conn} do
      {:ok, conv} =
        Handbean.ConversationStore.create_free(
          id: "conv-restore-free",
          title: "Free stay",
          timeline: [
            %{
              "id" => "msg-free",
              "content_type" => "user_msg",
              "role" => "user",
              "content" => "stay in free chat"
            }
          ]
        )

      {:ok, view, _html} = live(conn, "/")

      view
      |> element(
        ".conversation-item[phx-click='select_free_conversation'][phx-value-id='#{conv["id"]}']"
      )
      |> render_click()

      {:ok, _restored, html} = live(conn, "/")
      assert html =~ "sid:#{conv["id"]}"
      assert html =~ "stay in free chat"
    end

    test "mount renders the active workspace panel", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, ".workspace-panel-header", "My Workspace")
    end

    test "tool_end with file_path adds editor tab with relative name", %{
      conn: conn,
      ws_dir: ws_dir
    } do
      # Create a file in the workspace
      file_path = Path.join(ws_dir, "hello.exs")
      File.write!(file_path, "IO.puts(\"hello world\")")

      {:ok, view, _html} = live(conn, "/")
      _ = create_default_conversation(view)

      # Send tool_end with file_path pointing to workspace file
      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_end, %{
           tool: "write",
           duration_ms: 100,
           file_path: file_path,
           details: %{diff_lines: [%{"type" => "ins", "text" => "IO.puts(\"hello world\")"}]}
         })}
      )

      rendered = render(view)
      # The tab should show the relative path (just the filename)
      assert rendered =~ "hello.exs"
    end

    test "tool_end with file_path auto-selects file if no active_file", %{
      conn: conn,
      ws_dir: ws_dir
    } do
      file_path = Path.join(ws_dir, "auto.exs")
      File.write!(file_path, "x = 1")

      {:ok, view, _html} = live(conn, "/")
      _ = create_default_conversation(view)

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_end, %{
           tool: "write",
           duration_ms: 120,
           file_path: file_path,
           details: %{diff_lines: [%{"type" => "ins", "text" => "x = 1"}]}
         })}
      )

      rendered = render(view)
      # Should show file content since auto-selected
      assert rendered =~ "x = 1"
    end

    test "tool_end with outside workspace path is ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Send tool_end with a path outside the workspace
      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_end, %{
           tool: "read",
           duration_ms: 50,
           file_path: "/etc/passwd"
         })}
      )

      rendered = render(view)
      # Should NOT show the sensitive file
      refute rendered =~ "passwd"
      # The workspace tree remains available and no preview is opened.
      assert has_element?(view, ".workspace-file-tree[role='tree']")
      refute has_element?(view, "#editor-content")
    end

    test "select_file outside workspace does not read system file" do
      result = HandbeanWeb.WorkspaceLive.render_file_preview("/etc/passwd")
      assert result =~ "Access denied"
    end

    test "render_file_preview shows content for workspace file", %{ws_dir: ws_dir} do
      file_path = Path.join(ws_dir, "preview.exs")
      File.write!(file_path, "defmodule Foo do\n  def bar, do: :ok\nend")

      result = HandbeanWeb.WorkspaceLive.render_file_preview(file_path)
      assert result =~ "defmodule Foo do"
      assert result =~ ":ok"
    end

    test "render_file_preview/2 shows content when file is in non-global custom workspace" do
      # Create a file in a directory that is NOT the global workspace
      custom_dir =
        Path.join(System.tmp_dir!(), "sigil_custom_project_#{System.unique_integer([:positive])}")

      File.mkdir_p!(custom_dir)

      file_path = Path.join(custom_dir, "custom.exs")
      File.write!(file_path, "defmodule Custom do\n  def run, do: :custom\nend")

      try do
        # render_file_preview/1 uses the global workspace root and should fail
        result1 = HandbeanWeb.WorkspaceLive.render_file_preview(file_path)
        assert result1 =~ "Access denied"

        # render_file_preview/2 with custom workspace_root should work
        result2 = HandbeanWeb.WorkspaceLive.render_file_preview(file_path, custom_dir)
        assert result2 =~ "defmodule Custom do"
        assert result2 =~ ":custom"
      after
        File.rm_rf!(custom_dir)
      end
    end

    test "tool_end with details from executor creates editor tab", %{conn: conn, ws_dir: ws_dir} do
      file_path = Path.join(ws_dir, "from_details.exs")
      File.write!(file_path, "# from details")

      {:ok, view, _html} = live(conn, "/")
      _ = create_default_conversation(view)

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_end, %{
           tool: "write",
           duration_ms: 90,
           details: %{
             file_path: file_path,
             bytes: 14,
             lines: 1,
             diff_lines: [%{"type" => "ins", "text" => "# from details"}]
           },
           file_path: file_path
         })}
      )

      rendered = render(view)
      assert rendered =~ "from_details.exs"
    end

    test "auto-selects newly created file", %{conn: conn, ws_dir: ws_dir} do
      file_path = Path.join(ws_dir, "hello.exs")
      File.write!(file_path, "IO.puts(\"hello world\")")

      {:ok, view, _html} = live(conn, "/")
      _ = create_default_conversation(view)

      # Simulate Agent writing hello.exs via write tool
      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_end, %{
           tool: "write",
           duration_ms: 100,
           file_path: file_path,
           details: %{
             file_path: file_path,
             bytes: 21,
             lines: 1,
             diff_lines: [%{"type" => "ins", "text" => "IO.puts(\"hello world\")"}]
           }
         })}
      )

      rendered = render(view)
      assert rendered =~ "hello.exs"
      assert rendered =~ "hello world"
    end
  end
end
