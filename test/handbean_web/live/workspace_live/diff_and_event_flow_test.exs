defmodule HandbeanWeb.WorkspaceLive.DiffAndEventFlowTest do
  use HandbeanWeb.WorkspaceLiveCase

  describe "diff view" do
    test "diff_prefix returns line markers" do
      assert HandbeanWeb.WorkspaceLive.diff_prefix("ins") == "+"
      assert HandbeanWeb.WorkspaceLive.diff_prefix("del") == "-"
      assert HandbeanWeb.WorkspaceLive.diff_prefix("eq") == " "
      assert HandbeanWeb.WorkspaceLive.diff_prefix("skip") == "⋯"
    end

    test "view_diff renders structured escaped diff lines by timeline entry id", %{conn: conn} do
      ws = Handbean.Workspace.ensure_root!()
      file_path = Path.join(ws, "diff_target.ex")
      File.write!(file_path, "safe")

      {:ok, view, _html} = live(conn, "/")

      try do
        send(
          view.pid,
          {:agent_event,
           agent_event(:tool_start, %{
             tool_use_id: "tu_edit_1",
             tool: "edit",
             input: %{file_path: file_path}
           })}
        )

        send(
          view.pid,
          {:agent_event,
           agent_event(
             :tool_end,
             %{
               tool_use_id: "tu_edit_1",
               tool: "edit",
               duration_ms: 42,
               details: %{
                 file_path: file_path,
                 diff_lines: [
                   %{"type" => "del", "text" => "<script>alert('xss')</script>"},
                   %{"type" => "ins", "text" => "safe"}
                 ]
               }
             },
             2
           )}
        )

        view |> element("#chat-file-change-tool-tu_edit_1-toggle") |> render_click()

        rendered = render(view)
        assert rendered =~ "id=\"chat-file-change-tool-tu_edit_1-diff\""
        assert rendered =~ "&lt;script&gt;alert(&#39;xss&#39;)&lt;/script&gt;"
        refute rendered =~ "<script>"
        assert has_element?(view, "#chat-file-change-tool-tu_edit_1", "edit")
        assert rendered =~ "+1"
        assert rendered =~ "diff-lineno"

        view
        |> element("button[phx-click='select_right_panel_view'][phx-value-view='changes']")
        |> render_click()

        changes = render(view)
        assert changes =~ "id=\"changes-file-net-"
        refute changes =~ "id=\"changes-file-tool-tu_edit_1\""

        view
        |> element("#workspace-changes [id^='changes-file-net-'][id$='-toggle']")
        |> render_click()

        opened = render(view)
        assert opened =~ "id=\"changes-file-net-"
        assert opened =~ "-diff\""
        assert opened =~ "safe"
      after
        File.rm(file_path)
      end
    end

    test "visible changes panel refreshes for file effects during a run", %{conn: conn} do
      ws = Handbean.Workspace.ensure_root!()
      file_path = Path.join(ws, "live_changes.ex")
      before = "value = 1\n"
      after_text = "value = 2\n"
      File.write!(file_path, after_text)
      change = Handbean.ChangeSnapshot.build_edit_snapshot(file_path, before, after_text)

      {:ok, view, _html} = live(conn, "/")

      try do
        view
        |> element("button[phx-click='select_right_panel_view'][phx-value-view='changes']")
        |> render_click()

        assert has_element?(view, "#workspace-changes .workspace-changes-empty")

        send(view.pid, {:agent_event, agent_event(:run_start, %{model: "test"})})

        send(
          view.pid,
          {:agent_event,
           agent_event(
             :tool_start,
             %{
               tool_use_id: "tu_live_changes",
               tool: "edit",
               input: %{file_path: file_path}
             },
             2
           )}
        )

        refute has_element?(view, "#workspace-changes [id^='changes-file-net-']")

        send(
          view.pid,
          {:agent_event,
           agent_event(
             :tool_end,
             %{
               tool_use_id: "tu_live_changes",
               tool: "edit",
               duration_ms: 42,
               details:
                 %{
                   file_path: file_path,
                   diff_lines: change.diff_lines
                 }
                 |> Map.merge(change_event_details(change))
             },
             3
           )}
        )

        assert has_element?(view, "#workspace-changes [id^='changes-file-net-']")
        refute has_element?(view, "#workspace-changes .workspace-changes-empty")

        external = "value = 3\n"
        File.write!(file_path, external)
        reset = Handbean.ChangeSnapshot.build_write_snapshot(file_path, external, external)

        send(
          view.pid,
          {:agent_event,
           agent_event(
             :tool_start,
             %{
               tool_use_id: "tu_live_changes_reset",
               tool: "write",
               input: %{file_path: file_path}
             },
             4
           )}
        )

        assert has_element?(view, "#workspace-changes [id^='changes-file-net-']")

        send(
          view.pid,
          {:agent_event,
           agent_event(
             :tool_end,
             %{
               tool_use_id: "tu_live_changes_reset",
               tool: "write",
               duration_ms: 10,
               details:
                 %{
                   file_path: file_path,
                   diff_lines: reset.diff_lines
                 }
                 |> Map.merge(change_event_details(reset))
             },
             5
           )}
        )

        refute has_element?(view, "#workspace-changes [id^='changes-file-net-']")
        assert has_element?(view, "#workspace-changes .workspace-changes-empty")
      after
        File.rm(file_path)
      end
    end

    test "Show diff button hidden when diff_lines is empty", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_start, %{
           tool_use_id: "tu_edit_empty",
           tool: "edit",
           input: %{file_path: "some.ex"}
         })}
      )

      send(
        view.pid,
        {:agent_event,
         agent_event(
           :tool_end,
           %{
             tool_use_id: "tu_edit_empty",
             tool: "edit",
             duration_ms: 10,
             details: %{diff_lines: []}
           },
           2
         )}
      )

      rendered = render(view)
      refute has_element?(view, "#chat-file-change-tool-tu_edit_empty")
      refute rendered =~ "file-change-card"
    end

    test "close_diff clears diff state and re-opening works", %{conn: conn} do
      ws = Handbean.Workspace.ensure_root!()
      file_path = Path.join(ws, "close_test.ex")
      File.write!(file_path, "content")

      {:ok, view, _html} = live(conn, "/")

      try do
        send(
          view.pid,
          {:agent_event,
           agent_event(:tool_start, %{
             tool_use_id: "tu_close_1",
             tool: "edit",
             input: %{file_path: file_path}
           })}
        )

        send(
          view.pid,
          {:agent_event,
           agent_event(
             :tool_end,
             %{
               tool_use_id: "tu_close_1",
               tool: "edit",
               duration_ms: 42,
               details: %{
                 file_path: file_path,
                 diff_lines: [
                   %{"type" => "eq", "text" => "content"},
                   %{"type" => "ins", "text" => "new"}
                 ]
               }
             },
             2
           )}
        )

        view |> element("#chat-file-change-tool-tu_close_1-toggle") |> render_click()
        rendered = render(view)
        assert rendered =~ "id=\"chat-file-change-tool-tu_close_1-diff\""
        assert rendered =~ "new"

        view |> element("#chat-file-change-tool-tu_close_1-toggle") |> render_click()
        rendered = render(view)
        refute rendered =~ "id=\"chat-file-change-tool-tu_close_1-diff\""

        view |> element("#chat-file-change-tool-tu_close_1-toggle") |> render_click()
        rendered = render(view)
        assert rendered =~ "id=\"chat-file-change-tool-tu_close_1-diff\""
        assert rendered =~ "new"
      after
        File.rm(file_path)
      end
    end

    test "diff view renders skip lines safely with correct class", %{conn: conn} do
      ws = Handbean.Workspace.ensure_root!()
      file_path = Path.join(ws, "skip_test.ex")
      File.write!(file_path, "first")

      {:ok, view, _html} = live(conn, "/")

      try do
        send(
          view.pid,
          {:agent_event,
           agent_event(:tool_start, %{
             tool_use_id: "tu_skip_1",
             tool: "edit",
             input: %{file_path: file_path}
           })}
        )

        send(
          view.pid,
          {:agent_event,
           agent_event(
             :tool_end,
             %{
               tool_use_id: "tu_skip_1",
               tool: "edit",
               duration_ms: 42,
               details: %{
                 file_path: file_path,
                 diff_lines: [
                   %{"type" => "skip", "text" => "... 120 unchanged lines ..."},
                   %{"type" => "del", "text" => "old"},
                   %{"type" => "ins", "text" => "new"}
                 ]
               }
             },
             2
           )}
        )

        view |> element("#chat-file-change-tool-tu_skip_1-toggle") |> render_click()
        rendered = render(view)

        # Skip line renders
        assert rendered =~ "diff-skip"
        # Text is safely escaped (contains dots, not raw HTML)
        assert rendered =~ "120 unchanged lines"
        # Skip prefix is ⋯
        assert rendered =~ "⋯"
      after
        File.rm(file_path)
      end
    end

    test "reverts a recorded edit change from diff view", %{conn: conn} do
      ws = Handbean.Workspace.ensure_root!()
      file_path = Path.join(ws, "revert_edit_test.ex")
      before = "value = 1\n"
      after_text = "value = 2\n"
      File.write!(file_path, after_text)

      change = Handbean.ChangeSnapshot.build_edit_snapshot(file_path, before, after_text)

      {:ok, view, _html} = live(conn, "/")

      try do
        send(
          view.pid,
          {:agent_event,
           agent_event(:tool_start, %{
             tool_use_id: "tu_revert_1",
             tool: "edit",
             input: %{file_path: file_path}
           })}
        )

        send(
          view.pid,
          {:agent_event,
           agent_event(
             :tool_end,
             %{
               tool_use_id: "tu_revert_1",
               tool: "edit",
               duration_ms: 42,
               details:
                 %{
                   file_path: file_path,
                   diff_lines: change.diff_lines
                 }
                 |> Map.merge(change_event_details(change))
             },
             2
           )}
        )

        view |> element("#chat-file-change-tool-tu_revert_1-toggle") |> render_click()
        assert render(view) =~ "Revert"

        view |> element("#chat-file-change-tool-tu_revert_1-revert") |> render_click()
        assert render(view) =~ "Confirm revert"

        view
        |> element("#chat-file-change-tool-tu_revert_1-confirm button", "Confirm revert")
        |> render_click()

        rendered = render(view)

        assert File.read!(file_path) == before
        assert rendered =~ "Reverted file to the recorded before state"
        assert rendered =~ "reverted"
      after
        File.rm(file_path)
      end
    end

    test "changes panel revert restores the session baseline, not the latest call", %{conn: conn} do
      ws = Handbean.Workspace.ensure_root!()
      file_path = Path.join(ws, "revert_net_test.ex")
      first = "value = 1\n"
      middle = "value = 2\n"
      latest = "value = 3\n"
      File.write!(file_path, latest)

      first_change = Handbean.ChangeSnapshot.build_edit_snapshot(file_path, first, middle)
      second_change = Handbean.ChangeSnapshot.build_edit_snapshot(file_path, middle, latest)

      {:ok, view, _html} = live(conn, "/")

      try do
        send_recorded_edit(view, "tu_net_1", file_path, first_change)
        send_recorded_edit(view, "tu_net_2", file_path, second_change)

        view
        |> element("button[phx-click='select_right_panel_view'][phx-value-view='changes']")
        |> render_click()

        rendered = render(view)
        assert rendered =~ "id=\"changes-file-net-"
        refute rendered =~ "id=\"changes-file-tool-tu_net_2\""

        view
        |> element("#workspace-changes [id^='changes-file-net-'][id$='-toggle']")
        |> render_click()

        view
        |> element("#workspace-changes [id^='changes-file-net-'][id$='-revert']")
        |> render_click()

        view
        |> element("#workspace-changes button", "Confirm revert")
        |> render_click()

        assert File.read!(file_path) == first
        assert render(view) =~ "Reverted file to the recorded before state"
      after
        File.rm(file_path)
      end
    end

    test "blocks revert when file changed after diff", %{conn: conn} do
      ws = Handbean.Workspace.ensure_root!()
      file_path = Path.join(ws, "revert_conflict_test.ex")
      before = "value = 1\n"
      after_text = "value = 2\n"
      File.write!(file_path, after_text)

      change = Handbean.ChangeSnapshot.build_edit_snapshot(file_path, before, after_text)

      {:ok, view, _html} = live(conn, "/")

      try do
        send(
          view.pid,
          {:agent_event,
           agent_event(:tool_start, %{
             tool_use_id: "tu_conflict_1",
             tool: "edit",
             input: %{file_path: file_path}
           })}
        )

        send(
          view.pid,
          {:agent_event,
           agent_event(
             :tool_end,
             %{
               tool_use_id: "tu_conflict_1",
               tool: "edit",
               duration_ms: 42,
               details:
                 %{
                   file_path: file_path,
                   diff_lines: change.diff_lines
                 }
                 |> Map.merge(change_event_details(change))
             },
             2
           )}
        )

        view |> element("#chat-file-change-tool-tu_conflict_1-toggle") |> render_click()
        File.write!(file_path, "user changed\n")
        view |> element("#chat-file-change-tool-tu_conflict_1-revert") |> render_click()

        view
        |> element("#chat-file-change-tool-tu_conflict_1-confirm button", "Confirm revert")
        |> render_click()

        rendered = render(view)
        assert File.read!(file_path) == "user changed\n"
        assert rendered =~ "file changed since this diff"
        assert rendered =~ "conflict"
      after
        File.rm(file_path)
      end
    end
  end

  describe "status helpers" do
    test "render_tool_status returns correct labels" do
      assert HandbeanWeb.WorkspaceLive.render_tool_status(:running) == "running"
      assert HandbeanWeb.WorkspaceLive.render_tool_status(:done) == "done"
      assert HandbeanWeb.WorkspaceLive.render_tool_status(:error) == "error"
    end

    test "format_duration returns formatted time" do
      assert HandbeanWeb.WorkspaceLive.format_duration(nil) == nil
      assert HandbeanWeb.WorkspaceLive.format_duration(500) == "500ms"
      assert HandbeanWeb.WorkspaceLive.format_duration(1500) =~ "1.5s"
    end
  end

  describe "agent event dispatch compatibility" do
    test "accepts AgentEvent struct directly (bare struct via send)", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, agent_event(:run_start, %{model: "direct-model"}))

      rendered = render(view)
      assert rendered =~ "direct-model"
      assert rendered =~ "running"
    end

    test "accepts {:agent_event, %AgentEvent{}} tuple form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "tuple-model"})})

      rendered = render(view)
      assert rendered =~ "tuple-model"
      assert rendered =~ "running"
    end

    test "accepts map-like agent_event (backward compat)", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, %{kind: :run_start, payload: %{model: "map-model"}}})

      rendered = render(view)
      assert rendered =~ "map-model"
      assert rendered =~ "running"
    end

    test "tool_start with legacy :name key still works", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        {:agent_event,
         %{kind: :tool_start, payload: %{name: "read", input: %{file_path: "x.txt"}}}}
      )

      assert has_element?(view, "#tool-event-read")
      assert has_element?(view, "#tool-event-read", "x.txt")
    end

    test "tool_end with legacy :name key still works", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        {:agent_event, %{kind: :tool_start, payload: %{name: "bash", input: %{command: "ls"}}}}
      )

      send(
        view.pid,
        {:agent_event, %{kind: :tool_end, payload: %{name: "bash", duration_ms: 300}}}
      )

      rendered = render(view)
      assert rendered =~ "Ran 1 command"
      assert rendered =~ "tool-work-collapsed"
    end
  end

  describe "full event flow" do
    test "full run_start → tool_start → tool_end → message_delta → run_end cycle", %{conn: conn} do
      with_log(fn ->
        {:ok, view, _html} = live(conn, "/")
        sid = create_default_conversation(view)
        {:ok, _session} = Handbean.PubSub.Session.start_or_get(session_id: sid)
        {:ok, queue} = Handbean.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
        :ok = Handbean.PubSub.Session.attach_run(sid, self(), queue)
        topic = "session:#{sid}"

        # 1. User submits message
        send(
          view.pid,
          {:agent_event, agent_event(:run_start, %{model: "step-router-v1"}, 1, topic)}
        )

        view |> element("form") |> render_submit(%{"message" => "Read the config"})
        assert render(view) =~ "Read the config"

        # 2. Agent starts
        send(
          view.pid,
          {:agent_event, agent_event(:run_start, %{model: "step-router-v1"}, 1, topic)}
        )

        assert render(view) =~ "running"

        # 3. Tool starts
        send(
          view.pid,
          {:agent_event,
           agent_event(
             :tool_start,
             %{tool: "read", input: %{file_path: "config/runtime.exs"}},
             2,
             topic
           )}
        )

        assert has_element?(view, "#tool-event-read", "runtime.exs")

        # 4. Tool ends
        send(
          view.pid,
          {:agent_event, agent_event(:tool_end, %{tool: "read", duration_ms: 150}, 3, topic)}
        )

        rendered = render(view)
        assert rendered =~ "runtime.exs"
        assert rendered =~ "tool-work-open"
        refute rendered =~ "tool-work-summary"

        # 5. Assistant streams response
        send(
          view.pid,
          {:agent_event, agent_event(:message_delta, %{chunk: "The config contains"}, 4, topic)}
        )

        send(
          view.pid,
          {:agent_event, agent_event(:message_delta, %{chunk: " useful settings."}, 5, topic)}
        )

        rendered = render(view)
        assert rendered =~ "The config contains useful settings."
        assert rendered =~ "Explored 1 file"
        assert rendered =~ "tool-work-collapsed"

        # 6. Run ends
        send(
          view.pid,
          {:agent_event, agent_event(:run_end, %{status: "completed", turns: 2}, 6, topic)}
        )

        rendered = render(view)
        assert rendered =~ "completed"
        assert rendered =~ "Turns:"
        assert rendered =~ "2"
        refute has_element?(view, "#agent-working")
      end)
    end
  end

  describe "openai provider config" do
    test "openai_provider_config returns defaults when no env configured", %{conn: conn} do
      # Ensure no config is set
      Application.delete_env(:handbean, :openai)

      {:ok, _view, html} = live(conn, "/")

      # Status bar should show default OpenAI model
      assert html =~ "step-router-v1"
    end

    test "run_end with error status is handled without crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "step-router-v1"})})

      send(
        view.pid,
        {:agent_event,
         agent_event(
           :run_end,
           %{
             status: "error",
             turns: 0,
             error: "OPENAI_API_KEY not configured"
           },
           2
         )}
      )

      rendered = render(view)
      assert rendered =~ "Run error: OPENAI_API_KEY not configured"
      assert has_element?(view, "#status-bar")
    end
  end

  describe "new_session" do
    test "new_session button creates a new session and clears messages", %{conn: conn} do
      with_log(fn ->
        {:ok, view, _html} = live(conn, "/")

        # Send a message first
        view |> element("form") |> render_submit(%{"message" => "Hello"})
        assert render(view) =~ "Hello"

        # Create from the global new-conversation project picker.
        choose_new_conversation_project(view, "default")

        rendered = render(view)
        assert has_element?(view, "#no-messages")
        refute has_element?(view, "#timeline-stream .msg-user", "Hello")
        assert rendered =~ "No messages yet"
        assert rendered =~ "idle"
        assert rendered =~ "step-router-v1"
      end)
    end

    test "new_session preserves OpenAI model in status bar", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      choose_new_conversation_project(view, "default")

      rendered = render(view)
      assert rendered =~ "step-router-v1"
    end
  end
end
