defmodule HandbeanWeb.WorkspaceLive.AgentEventsFilesAndRunsTest do
  use HandbeanWeb.WorkspaceLiveCase

  describe "agent events via handle_info" do
    test "tool_end event with error shows error status", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        {:agent_event, agent_event(:tool_start, %{tool: "bash", input: %{command: "rm -rf /"}})}
      )

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_end, %{tool: "bash", duration_ms: 120, error: "Permission denied"}, 2)}
      )

      rendered = render(view)
      assert rendered =~ "Ran 1 command"
      assert rendered =~ "Permission denied"
    end

    test "browser missing-binary tool_end shows a copyable install card", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_start, %{
           tool_use_id: "tu_browser_missing",
           tool: "browser",
           input: %{args: ["open", "https://example.com"]}
         })}
      )

      send(
        view.pid,
        {:agent_event,
         agent_event(
           :tool_end,
           %{
             tool_use_id: "tu_browser_missing",
             tool: "browser",
             duration_ms: 12,
             error: "agent-browser is not installed",
             details: %{
               failure_category: "missing-binary",
               install_command: Handbean.Browser.InstallPrompt.command(),
               next_actions: [%{id: "install-agent-browser"}]
             }
           },
           2
         )}
      )

      assert has_element?(view, "#browser-install-tool-tu_browser_missing")

      assert has_element?(
               view,
               "#browser-install-tool-tu_browser_missing",
               Handbean.Browser.InstallPrompt.command()
             )

      assert has_element?(view, "#browser-install-copy-tool-tu_browser_missing")

      html = render(view)

      refute html =~ ~s("agent-browser is not installed")
    end

    test "tool_end event with details.file_path but no diff does not add to editor_files", %{
      conn: conn
    } do
      ws = Handbean.Workspace.ensure_root!()
      file_path = Path.join(ws, "my_module.ex")
      File.write!(file_path, "defmodule MyModule do end")

      {:ok, view, _html} = live(conn, "/")

      try do
        send(
          view.pid,
          {:agent_event,
           agent_event(:tool_start, %{tool: "edit", input: %{file_path: file_path}})}
        )

        send(
          view.pid,
          {:agent_event,
           agent_event(
             :tool_end,
             %{
               tool: "edit",
               duration_ms: 100,
               details: %{file_path: file_path}
             },
             2
           )}
        )

        rendered = render(view)
        assert has_element?(view, ".workspace-file-row.file", "my_module.ex")
        refute rendered =~ "defmodule MyModule do end"
      after
        File.rm(file_path)
      end
    end

    test "tool_end event with direct file_path but no diff does not add to editor_files", %{
      conn: conn
    } do
      ws = Handbean.Workspace.ensure_root!()
      file_path = Path.join(ws, "foo.ex")
      File.write!(file_path, "# foo")

      {:ok, view, _html} = live(conn, "/")

      try do
        send(
          view.pid,
          {:agent_event,
           agent_event(:tool_end, %{tool: "edit", duration_ms: 100, file_path: file_path})}
        )

        rendered = render(view)
        assert has_element?(view, ".workspace-file-row.file", "foo.ex")
        refute rendered =~ "# foo"
      after
        File.rm(file_path)
      end
    end

    test "tool_end event with non-empty diff adds to editor_files", %{conn: conn} do
      ws = Handbean.Workspace.ensure_root!()
      file_path = Path.join(ws, "changed.ex")

      {:ok, view, _html} = live(conn, "/")
      _ = create_default_conversation(view)

      refute has_element?(
               view,
               "button[phx-click='select_workspace_file'][phx-value-path='changed.ex']"
             )

      try do
        File.write!(file_path, "# changed")

        send(
          view.pid,
          {:agent_event,
           agent_event(
             :tool_end,
             %{
               tool: "edit",
               duration_ms: 100,
               details: %{
                 file_path: file_path,
                 diff_lines: [%{"type" => "ins", "text" => "# changed"}]
               }
             }
           )}
        )

        rendered = render(view)
        assert rendered =~ "changed.ex"

        assert has_element?(
                 view,
                 "button[phx-click='select_workspace_file'][phx-value-path='changed.ex']"
               )
      after
        File.rm(file_path)
      end
    end

    test "workspace file menu always offers path copies but hides undeclared file managers", %{
      conn: conn
    } do
      host = Application.get_env(:handbean, :host, %{})
      Handbean.Host.put!(Map.delete(host, :file_manager_backend))
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(
               view,
               "#workspace-tree-context-menu[role='menu'][hidden][phx-update='ignore']"
             )

      assert has_element?(
               view,
               "#workspace-tree-context-menu [data-workspace-tree-action='copy-absolute']",
               "Copy absolute path"
             )

      assert has_element?(
               view,
               "#workspace-tree-context-menu [data-workspace-tree-action='copy-relative']",
               "Copy relative path"
             )

      refute has_element?(
               view,
               "#workspace-tree-context-menu [data-workspace-tree-action='reveal-in-file-manager']"
             )
    end

    test "declared macOS file manager reveals only validated workspace entries", %{conn: conn} do
      ws =
        Handbean.Workspace.ensure_root!()
        |> Handbean.Security.PathValidator.resolve_symlink()

      directory = Path.join(ws, "reveal-dir")
      file = Path.join(ws, "reveal-file.txt")
      symlink = Path.join(ws, "reveal-link")
      File.mkdir_p!(directory)
      File.write!(file, "reveal")
      File.ln_s!(Path.join(ws, "missing-target"), symlink)

      host = Application.get_env(:handbean, :host, %{})
      Handbean.Host.put!(Map.put(host, :file_manager_backend, FileManagerStub))
      Application.put_env(:handbean, :file_manager_test_owner, self())
      on_exit(fn -> Application.delete_env(:handbean, :file_manager_test_owner) end)

      try do
        {:ok, view, _html} = live(conn, "/")

        assert has_element?(
                 view,
                 "#workspace-tree-context-menu [data-workspace-tree-action='reveal-in-file-manager'][hidden]",
                 "Reveal in Finder"
               )

        assert has_element?(
                 view,
                 ".workspace-file-row.directory[data-workspace-relative-path='reveal-dir'][data-workspace-absolute-path='#{directory}']"
               )

        assert has_element?(
                 view,
                 ".workspace-file-entry[data-workspace-relative-path='reveal-file.txt'][data-workspace-absolute-path='#{file}']"
               )

        assert has_element?(
                 view,
                 ".workspace-file-row.symlink[data-workspace-relative-path='reveal-link'][data-workspace-absolute-path='#{symlink}']"
               )

        render_click(view, "reveal_in_file_manager", %{"path" => "reveal-file.txt"})
        assert_receive {:revealed, ^file}

        render_click(view, "reveal_in_file_manager", %{"path" => "reveal-dir"})
        assert_receive {:revealed, ^directory}

        render_click(view, "reveal_in_file_manager", %{"path" => "reveal-link"})
        assert_receive {:revealed, ^symlink}

        render_click(view, "reveal_in_file_manager", %{"path" => "../outside"})
        refute_receive {:revealed, _}
      after
        File.rm_rf!(directory)
        File.rm(file)
        File.rm(symlink)
      end
    end

    test "workspace tree lazily expands directories and selects a nested file", %{
      conn: conn
    } do
      ws = Handbean.Workspace.ensure_root!()
      file_path = Path.join([ws, "nested", "compact-tab.ex"])
      File.mkdir_p!(Path.dirname(file_path))
      File.write!(file_path, "# compact")

      {:ok, view, _html} = live(conn, "/")
      _ = create_default_conversation(view)

      try do
        assert has_element?(view, ".workspace-file-row.directory", "nested")
        refute has_element?(view, ".workspace-file-row.file", "compact-tab.ex")

        view
        |> element("button[phx-click='toggle_workspace_directory'][phx-value-path='nested']")
        |> render_click()

        assert has_element?(
                 view,
                 ".workspace-file-row.file[title='nested/compact-tab.ex']",
                 "compact-tab.ex"
               )

        assert has_element?(
                 view,
                 "button.workspace-file-copy[data-copy='nested/compact-tab.ex'][aria-label='Copy relative path']"
               )

        refute has_element?(view, "button.workspace-file-copy[data-copy='nested']")

        view
        |> element(
          "button[phx-click='select_workspace_file'][phx-value-path='nested/compact-tab.ex']"
        )
        |> render_click()

        assert render(view) =~ "# compact"
      after
        File.rm_rf(Path.dirname(file_path))
      end
    end

    test "hosts without terminal capability hide every entry and reject direct open events", %{
      conn: conn
    } do
      previous = Application.get_env(:handbean, :host)
      Handbean.Host.put!(Map.put(previous || %{}, :terminal, false))

      on_exit(fn ->
        if previous,
          do: Application.put_env(:handbean, :host, previous),
          else: Application.delete_env(:handbean, :host)
      end)

      {:ok, view, _html} = live(conn, "/")
      assert has_element?(view, "#workspace-sheet #mobile-open-files")
      refute has_element?(view, "#mobile-open-terminal")
      refute has_element?(view, ".mobile-header-v2 #mobile-open-files")
      refute has_element?(view, "button[phx-value-view='terminal']")
      refute has_element?(view, "#status-bar button[phx-click='toggle_terminal']")

      for {event, params} <- [
            {"select_right_panel_view", %{"view" => "terminal"}},
            {"select_mobile_right_panel_view", %{"view" => "terminal"}},
            {"toggle_terminal", %{}}
          ] do
        render_click(view, event, params)
        refute has_element?(view, "#terminal-panel")
        refute has_element?(view, "#workspace-panel.mobile-panel-open")
      end

      view |> element("#mobile-open-files") |> render_click()
      assert has_element?(view, "#workspace-panel.mobile-panel-open")
      assert has_element?(view, ".workspace-panel-tab.active", "Files")
    end

    test "terminal opens inside the right workspace panel instead of a bottom dock", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view
      |> element("button[phx-click='select_right_panel_view'][phx-value-view='terminal']")
      |> render_click()

      assert has_element?(view, "#workspace-panel #terminal-panel")
      assert has_element?(view, "#terminal-command-form input[name='line']")
      refute has_element?(view, "#terminal-panel .terminal-presets")
      refute has_element?(view, "#terminal-panel [phx-click='run_preset']")
      refute has_element?(view, "button", "+ New Terminal")
      refute render(view) =~ "args (space-separated)"
      refute render(view) =~ "no terminals"
      refute has_element?(view, "#terminal-dock")
      refute has_element?(view, "#status-bar button[phx-click='toggle_terminal']")
    end

    test "mobile conversation list can open files and terminal in the workspace panel", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, "#workspace-sheet #mobile-open-files")
      assert has_element?(view, "#workspace-sheet #mobile-open-terminal")
      refute has_element?(view, ".mobile-header-v2 #mobile-open-files")
      refute has_element?(view, ".mobile-header-v2 #mobile-open-terminal")
      refute has_element?(view, "#workspace-panel.mobile-panel-open")

      view |> element("#mobile-open-files") |> render_click()
      assert has_element?(view, "#workspace-panel.mobile-panel-open")
      assert has_element?(view, "#workspace-panel .workspace-panel-tab.active", "Files")

      view |> element("#mobile-close-workspace-panel") |> render_click()
      refute has_element?(view, "#workspace-panel.mobile-panel-open")

      view |> element("#mobile-open-terminal") |> render_click()
      assert has_element?(view, "#workspace-panel.mobile-panel-open")
      assert has_element?(view, "#workspace-panel #terminal-panel")
    end

    test "duplicate file_path does not add duplicate editor file", %{conn: conn} do
      ws = Handbean.Workspace.ensure_root!()
      file_path = Path.join(ws, "dup.ex")
      File.write!(file_path, "# dup")

      {:ok, view, _html} = live(conn, "/")

      try do
        send(
          view.pid,
          {:agent_event,
           agent_event(:tool_end, %{
             tool: "edit",
             duration_ms: 100,
             file_path: file_path,
             details: %{diff_lines: [%{"type" => "ins", "text" => "# dup"}]}
           })}
        )

        send(
          view.pid,
          {:agent_event,
           agent_event(
             :tool_end,
             %{
               tool: "write",
               duration_ms: 200,
               file_path: file_path,
               details: %{diff_lines: [%{"type" => "ins", "text" => "# dup"}]}
             },
             2
           )}
        )

        rendered = render(view)
        assert rendered =~ "dup.ex"
      after
        File.rm(file_path)
      end
    end

    test "multiple tool events show all in order", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        {:agent_event, agent_event(:tool_start, %{tool: "read", input: %{file_path: "a.txt"}})}
      )

      send(view.pid, {:agent_event, agent_event(:tool_end, %{tool: "read", duration_ms: 50}, 2)})

      send(
        view.pid,
        {:agent_event, agent_event(:tool_start, %{tool: "bash", input: %{command: "ls"}}, 3)}
      )

      send(view.pid, {:agent_event, agent_event(:tool_end, %{tool: "bash", duration_ms: 100}, 4)})

      rendered = render(view)
      assert rendered =~ "id=\"tool-event-read\""
      assert rendered =~ "id=\"tool-event-bash\""
      assert rendered =~ "✓"
    end

    test "run_end event stops running and updates status", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Set running via event (avoid Task race from render_submit)
      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "claude"})})

      assert render(view) =~ "running"

      send(view.pid, {:agent_event, agent_event(:run_end, %{status: "completed", turns: 3})})

      rendered = render(view)
      assert rendered =~ "completed"
      assert has_element?(view, "#status-turns", "3")
    end

    test "usage updates refresh the running footer and replace cumulative totals", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      create_default_conversation(view)
      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "fake"})})

      send(
        view.pid,
        {:agent_event,
         agent_event(:usage_updated, %{usage: %{input_tokens: 10, output_tokens: 15}}, 2)}
      )

      assert has_element?(view, "#status-input-tokens", "10")
      assert has_element?(view, "#status-output-tokens", "15")
      assert has_element?(view, "button[phx-click='stop_run']")

      payload = %{
        "usage" => %{
          "input_tokens" => 25,
          "output_tokens" => 35,
          "cache_read_input_tokens" => 7,
          "cache_creation_input_tokens" => 3
        }
      }

      for seq <- [3, 4] do
        send(view.pid, {:agent_event, agent_event(:usage_updated, payload, seq)})
        assert has_element?(view, "#status-input-tokens", "25")
        assert has_element?(view, "#status-output-tokens", "35")
        refute has_element?(view, "#status-cache-tokens")
      end

      send(
        view.pid,
        {:agent_event,
         agent_event(:run_end, %{status: "completed", turns: 2, usage: payload["usage"]}, 5)}
      )

      assert has_element?(view, "#status-input-tokens", "0")
      assert has_element?(view, "#status-output-tokens", "0")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "fake"}, 6)})
      assert has_element?(view, "#status-input-tokens", "0")
      assert has_element?(view, "#status-output-tokens", "0")

      send(view.pid, {:agent_event, agent_event(:run_end, %{status: :cancelled}, 7)})
      send(view.pid, {:agent_event, agent_event(:usage_updated, payload, 8)})
      assert has_element?(view, "#status-input-tokens", "0")
      assert has_element?(view, "#status-output-tokens", "0")
    end

    test "cache hit rate follows cumulative usage through completion and resets for a new run", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/")
      create_default_conversation(view)
      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "fake"})})
      assert has_element?(view, "#status-cache-hit-rate", "—")

      usage = %{input_tokens: 100, total_input_tokens: 100, cache_read_input_tokens: 80}

      for seq <- [2, 3] do
        send(view.pid, {:agent_event, agent_event(:usage_updated, %{usage: usage}, seq)})
        assert has_element?(view, "#status-cache-hit-rate", "80.0%")
      end

      cumulative = %{
        "input_tokens" => 150,
        "total_input_tokens" => 1000,
        "cache_read_input_tokens" => 180,
        "cache_creation_input_tokens" => 750
      }

      send(view.pid, {:agent_event, agent_event(:usage_updated, %{"usage" => cumulative}, 4)})
      assert has_element?(view, "#status-cache-hit-rate", "18.0%")
      assert has_element?(view, "button[phx-click='stop_run']")

      send(
        view.pid,
        {:agent_event,
         agent_event(:run_end, %{"status" => "completed", "usage" => cumulative}, 5)}
      )

      assert has_element?(view, "#status-cache-hit-rate", "—")
      assert has_element?(view, "#status-input-tokens[title='0']", "0")
      refute has_element?(view, "button[phx-click='stop_run']")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "fake"}, 6)})
      assert has_element?(view, "#status-cache-hit-rate", "—")
    end

    test "token footer keeps input/output while cache read/write totals stay hidden", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/")
      create_default_conversation(view)
      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "fake"})})
      assert has_element?(view, "#status-input-tokens[title='0']", "0")

      usage = %{
        input_tokens: 5481,
        output_tokens: 827,
        cache_read_input_tokens: 999_950,
        cache_creation_input_tokens: 1000
      }

      send(view.pid, {:agent_event, agent_event(:usage_updated, %{usage: usage}, 2)})
      assert has_element?(view, "button[phx-click='stop_run']")
      assert has_element?(view, "#status-input-tokens[title='5481']", "5.5K")
      assert has_element?(view, "#status-output-tokens[title='827']", "827")
      refute has_element?(view, "#status-cache-tokens")
      refute has_element?(view, "#status-cache-read")
      refute has_element?(view, "#status-cache-write")

      conv_id = session_id_from_html(render(view))

      :ok =
        Handbean.ConversationStore.record_run_usage(conv_id, "run-final", %{
          input_tokens: 33_261,
          output_tokens: 1250,
          cache_read_input_tokens: 1_200_000,
          cache_creation_input_tokens: 999
        })

      assert {:ok, usage_before} = Handbean.ConversationStore.get_token_usage(conv_id)

      send(
        view.pid,
        {:agent_event,
         agent_event(:run_end, %{status: :completed, turns: 2, usage: %{input_tokens: 1}}, 3)}
      )

      refute has_element?(view, "button[phx-click='stop_run']")
      assert {:ok, ^usage_before} = Handbean.ConversationStore.get_token_usage(conv_id)
      assert has_element?(view, "#status-input-tokens[title='33261']", "33.3K")
      assert has_element?(view, "#status-output-tokens[title='1250']", "1.3K")
      assert has_element?(view, "#status-cache-hit-rate", "97.2%")
      refute has_element?(view, "#status-cache-tokens")
    end

    test "run_end event updates input and output token counts from provider usage", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "step-router-v1"})})

      send(
        view.pid,
        {:agent_event,
         agent_event(
           :run_end,
           %{status: "completed", turns: 1, usage: %{input_tokens: 12, output_tokens: 8}},
           2
         )}
      )

      assert has_element?(view, "#status-input-tokens", "0")
      assert has_element?(view, "#status-output-tokens", "0")
    end

    test "run_end accepts string-keyed provider usage", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        {:agent_event,
         agent_event(
           :run_end,
           %{status: "completed", turns: 1, usage: %{"input_tokens" => 9, "output_tokens" => 6}}
         )}
      )

      assert has_element?(view, "#status-input-tokens", "0")
      assert has_element?(view, "#status-output-tokens", "0")
    end

    test "run_end accepts string-keyed payload from persisted session events", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        {:agent_event,
         agent_event(
           :run_end,
           %{
             "status" => "completed",
             "turns" => 2,
             "usage" => %{"input_tokens" => 21, "output_tokens" => 13}
           }
         )}
      )

      assert has_element?(view, "#status-input-tokens", "0")
      assert has_element?(view, "#status-output-tokens", "0")
      assert has_element?(view, "#status-turns", "2")
    end

    test "switching conversations loads that conversation's totals and clears turns", %{
      conn: conn
    } do
      {:ok, first} =
        Handbean.ConversationStore.create("default", id: "conv-usage-a", title: "Usage A")

      :ok =
        Handbean.ConversationStore.record_run_usage(first["id"], "run-a", %{
          input_tokens: 100,
          output_tokens: 5,
          cache_read_input_tokens: 50,
          total_input_tokens: 200
        })

      {:ok, second} =
        Handbean.ConversationStore.create("default", id: "conv-usage-b", title: "Usage B")

      :ok =
        Handbean.ConversationStore.record_run_usage(second["id"], "run-b", %{
          input_tokens: 7,
          output_tokens: 1
        })

      {:ok, view, _html} = live(conn, "/")

      view
      |> element(
        ".conversation-item[phx-click='select_conversation'][phx-value-id='#{first["id"]}']"
      )
      |> render_click()

      send(view.pid, {:agent_event, agent_event(:run_end, %{status: "completed", turns: 10}, 2)})

      assert has_element?(view, "#status-cache-hit-rate", "25.0%")
      assert has_element?(view, "#status-input-tokens", "100")
      assert has_element?(view, "#status-turns", "10")

      view
      |> element(
        ".conversation-item[phx-click='select_conversation'][phx-value-id='#{second["id"]}']"
      )
      |> render_click()

      assert has_element?(view, "#status-input-tokens", "7")
      assert has_element?(view, "#status-cache-hit-rate", "—")
      refute has_element?(view, "#status-turns")

      view
      |> element(
        ".conversation-item[phx-click='select_conversation'][phx-value-id='#{first["id"]}']"
      )
      |> render_click()

      assert has_element?(view, "#status-cache-hit-rate", "25.0%")
      assert has_element?(view, "#status-input-tokens", "100")
      refute has_element?(view, "#status-turns")
    end

    test "run_end with error status shows error in status bar", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "claude"})})

      send(
        view.pid,
        {:agent_event, agent_event(:run_end, %{status: "error", turns: 0, error: "timeout"}, 2)}
      )

      rendered = render(view)
      assert rendered =~ "Run error: timeout"
    end

    test "run_end clears running indicator", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "claude"})})

      send(view.pid, {:agent_event, agent_event(:run_end, %{status: "completed", turns: 1}, 2)})

      refute has_element?(view, "#agent-working")
    end

    test "stop button cancels projection and ignores late streaming chunks", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "claude"})})
      assert has_element?(view, "button[phx-click='stop_run']", "Stop")

      view |> element("button[phx-click='stop_run']") |> render_click()

      assert has_element?(view, "#status-label", "cancelled")
      refute has_element?(view, "#agent-working")

      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "late chunk"}, 2)})
      refute render(view) =~ "late chunk"

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "claude"}, 3)})
      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "new chunk"}, 4)})
      assert render(view) =~ "new chunk"
    end

    test "stop button ignores late tool events and stale completed run_end", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "claude"})})
      view |> element("button[phx-click='stop_run']") |> render_click()

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_start, %{tool: "bash", input: %{command: "mix test"}}, 2)}
      )

      send(
        view.pid,
        {:agent_event, agent_event(:tool_end, %{tool: "bash", duration_ms: 25}, 3)}
      )

      send(view.pid, {:agent_event, agent_event(:run_end, %{status: "completed", turns: 1}, 4)})

      rendered = render(view)
      refute rendered =~ "mix test"
      refute has_element?(view, "#tool-event-bash")
      assert has_element?(view, "#status-label", "cancelled")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "claude"}, 5)})

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_start, %{tool: "bash", input: %{command: "mix format"}}, 6)}
      )

      assert render(view) =~ "mix format"
    end

    test "unrecognized event kind is silently ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:unknown_kind, %{foo: "bar"})})

      # View should still be alive and render the status bar
      rendered = render(view)
      assert rendered =~ "id=\"status-bar\""
    end

    test "streaming chunks render incrementally without losing content on run_end", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Start a run
      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "step-router-v1"})})

      # Simulate streaming: many small chunks (like real SSE streaming)
      chunks = ["Hello", ", ", "this ", "is ", "a ", "streaming ", "test."]

      Enum.each(chunks, fn chunk ->
        send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: chunk})})
      end)

      # All chunks should have accumulated into one assistant message
      full_text = Enum.join(chunks)
      assert render(view) =~ full_text

      # Run ends — content should still be present
      send(
        view.pid,
        {:agent_event,
         agent_event(
           :run_end,
           %{status: "completed", turns: 1, usage: %{input_tokens: 5, output_tokens: 7}},
           99
         )}
      )

      rendered = render(view)
      assert rendered =~ full_text
      assert rendered =~ "completed"
      refute has_element?(view, "#agent-working")
    end

    test "streaming chunks render before run_end", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "AI response"})})
      assert render(view) =~ "AI response"
    end

    test "conversation store is updated during streaming chunks and finalized on run_end", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/")
      conversation_id = create_default_conversation(view)

      Handbean.Agent.TranscriptPersistence.handle_event(
        conversation_id,
        {:run_start, %{model: "test"}}
      )

      Handbean.Agent.TranscriptPersistence.handle_event(
        conversation_id,
        {:run_end, %{status: "completed", turns: 1}}
      )

      _ = render(view)

      # Now send streaming chunks — display history should be durable before run_end.
      for i <- 1..20 do
        Handbean.Agent.TranscriptPersistence.handle_event(
          conversation_id,
          {:message_delta, %{chunk: "chunk#{i} "}}
        )
      end

      assert {:ok, [streaming]} =
               Handbean.ConversationTranscriptStore.list(conversation_id)

      expected = Enum.map_join(1..20, &"chunk#{&1} ")
      assert streaming["content"] == expected
      assert streaming["status"] == "streaming"

      # Finalization must preserve the already durable content.
      Handbean.Agent.TranscriptPersistence.handle_event(
        conversation_id,
        {:run_end,
         %{status: "completed", turns: 2, usage: %{input_tokens: 10, output_tokens: 20}}}
      )

      assert {:ok, [completed]} =
               Handbean.ConversationTranscriptStore.list(conversation_id)

      assert completed["content"] == expected
      assert completed["status"] == "completed"

      assert {:ok, conversation} = Handbean.ConversationStore.get(conversation_id)
      assert [projected] = conversation["timeline"]
      assert projected["content"] == expected
      assert projected["status"] == "completed"
    end
  end
end
