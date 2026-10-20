defmodule HandbeanWeb.WorkspaceLive.ConversationRenderingTest do
  use HandbeanWeb.WorkspaceLiveCase

  describe "model switching" do
    test "model picker shows current model on mount", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "id=\"model-picker\""
      assert html =~ "step-router-v1"
    end

    test "run_start event updates current model state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "custom-oai-model"})})

      rendered = render(view)
      assert rendered =~ "custom-oai-model"
    end

    test "model display persists across new_session", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      choose_new_conversation_project(view, "default")

      rendered = render(view)
      assert rendered =~ "step-router-v1"
    end

    test "workspace label remains visible in the workspace panel", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, ".workspace-panel-header", "My Workspace")
    end
  end

  describe "conversation stream" do
    test "renders conversations under workspace groups", %{conn: conn} do
      {:ok, view, html} = live(conn, "/")

      assert html =~ "workspace-group"
      assert html =~ "conversations-list"

      choose_new_conversation_project(view, "default")

      assert render(view) =~ "conversation-row"
    end

    test "conversation items omit workspace badges inside grouped workspaces", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      refute html =~ "workspace-badge"
    end

    test "workspace panel shows the active workspace", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, ".workspace-panel-header", "My Workspace")
    end

    test "new_conversation_in_workspace renders inside grouped workspace list", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      choose_new_conversation_project(view, "default")

      html = render(view)
      assert html =~ "conversations-list"
      assert html =~ "conversation-row"
    end

    test "right workspace panel uses a single floating toggle instead of expand bar", %{
      conn: conn
    } do
      {:ok, view, html} = live(conn, "/")

      assert html =~ ~s(id="workspace-panel-collapse")
      refute html =~ ~s(id="workspace-expand-bar")

      view
      |> element("[data-workspace-panel-toggle]")
      |> render_click()

      html = render(view)
      assert html =~ ~s(id="workspace-panel-expand")
      assert html =~ "collapsed"
      refute html =~ ~s(id="workspace-expand-bar")
    end

    test "mobile workspace sheet has new conversation entry without duplicate workspace row", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, "#workspace-sheet[aria-hidden='true'][inert]")

      view
      |> element("button[phx-click='open_sheet'][phx-value-type='workspace']")
      |> render_click()

      html = render(view)
      assert html =~ ~s(id="workspace-sheet")
      assert has_element?(view, "#workspace-sheet.open[aria-hidden='false']:not([inert])")
      assert html =~ "sheet-new-conv-btn"
      refute html =~ "sheet-ws-row"
      assert has_element?(view, "#workspace-sheet #mobile-schedule-nav")

      view |> element("#mobile-schedule-nav") |> render_click()
      assert has_element?(view, "#schedule-center")
      refute has_element?(view, "#ai-input-area")
      refute has_element?(view, "#workspace-sheet.open")

      view |> element("#mobile-schedule-back") |> render_click()

      view
      |> element("button[phx-click='open_sheet'][phx-value-type='workspace']")
      |> render_click()

      view
      |> element(
        "#workspace-sheet button[phx-click='mobile_new_conversation_in_workspace'][phx-value-ws_id='default']"
      )
      |> render_click()

      html = render(view)
      assert html =~ "conversation-row"
      refute html =~ ~s(id="workspace-sheet" class="bottom-sheet open")
    end

    test "archive toggle shows archived conversations in stream", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      html = render(view)
      assert html =~ "Archived"
      refute html =~ "Trash"

      assert has_element?(
               view,
               "button.workspace-header[phx-click='toggle_archive'][aria-expanded='false']"
             )

      view |> element("button.workspace-header[phx-click='toggle_archive']") |> render_click()

      assert has_element?(
               view,
               "button.workspace-header[phx-click='toggle_archive'][aria-expanded='true']"
             )
    end

    test "conversation stream scrolls past workspaces while preserving scroll position", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/")

      html = render(view)
      assert html =~ "workspace-group"
      assert html =~ "conversations-list"
    end
  end

  describe "strip_think_tags" do
    test "strips think tags from plain text" do
      {thinking, clean, buffer} =
        HandbeanWeb.WorkspaceLive.strip_think_tags("", "<think>reasoning</think> answer")

      assert thinking == "reasoning"
      assert clean == " answer"
      assert buffer == ""
    end

    test "strips thinking tags variant" do
      {thinking, clean, _} =
        HandbeanWeb.WorkspaceLive.strip_think_tags("", "<thinking>deep thought</thinking> done")

      assert thinking == "deep thought"
      assert clean == " done"
    end

    test "handles text without think tags" do
      {thinking, clean, buffer} =
        HandbeanWeb.WorkspaceLive.strip_think_tags("", "plain text no tags")

      assert thinking == ""
      assert clean == "plain text no tags"
      assert buffer == ""
    end

    test "accumulates partial tags across chunk boundaries" do
      # First chunk: partial opening tag
      {t1, c1, buf1} = HandbeanWeb.WorkspaceLive.strip_think_tags("", "<thi")
      assert t1 == ""
      assert c1 == ""

      # Second chunk: complete the tag and some thinking text
      {t2, c2, buf2} = HandbeanWeb.WorkspaceLive.strip_think_tags(buf1, "nk>thinking text")
      assert t2 == "thinking text"
      assert c2 == ""
      # Buffer encodes inside state; empty partial = still inside think block
      assert buf2 == "<in>"
    end

    test "accumulates partial closing tag across chunks" do
      {t1, c1, buf1} = HandbeanWeb.WorkspaceLive.strip_think_tags("", "<think>inner</thi")
      assert t1 == "inner"
      assert c1 == ""

      # Combined: </thi + nk> = </think> closes block, "after" is outside, "/think> visible" is trailing
      {t2, c2, buf2} =
        HandbeanWeb.WorkspaceLive.strip_think_tags(buf1, "nk>after</think> visible")

      assert t2 == ""
      assert c2 == "after</think> visible"
      assert buf2 == ""
    end

    test "handles multiple think blocks" do
      {thinking, clean, _} =
        HandbeanWeb.WorkspaceLive.strip_think_tags(
          "",
          "<think>first</think> middle <think>second</think> end"
        )

      assert thinking == "firstsecond"
      assert clean == " middle  end"
    end

    test "handles empty input" do
      {t, c, b} = HandbeanWeb.WorkspaceLive.strip_think_tags("", "")
      assert t == ""
      assert c == ""
      assert b == ""
    end

    test "think tag opens but never closes across many chunks" do
      {t1, c1, buf1} = HandbeanWeb.WorkspaceLive.strip_think_tags("", "prefix <think>reason")
      assert t1 == "reason"
      assert c1 == "prefix "

      {t2, c2, buf2} = HandbeanWeb.WorkspaceLive.strip_think_tags(buf1, "ing continues")
      assert t2 == "ing continues"
      assert c2 == ""

      # Still no close tag — buffer should be empty, state stays :inside
      {t3, c3, _} = HandbeanWeb.WorkspaceLive.strip_think_tags(buf2, " and more")
      assert t3 == " and more"
      assert c3 == ""
    end
  end

  describe "turn folding" do
    test "compute_turns groups entries into a turn", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "test"})})
      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "AI response"})})
      rendered = render(view)

      assert rendered =~ "AI response"
      assert rendered =~ "turn-group"
    end

    test "turn header shows for multi-entry turns", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "test"})})
      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "first"})})
      send(view.pid, {:agent_event, agent_event(:run_end, %{status: "completed", turns: 1}, 2)})

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "test"}, 3)})
      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "second"}, 4)})

      rendered = render(view)
      assert rendered =~ "first"
      assert rendered =~ "second"
      assert rendered =~ "turn-header"
    end

    test "tool calls and assistant belong to same turn", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "test"})})

      send(
        view.pid,
        {:agent_event, agent_event(:tool_start, %{tool: "read", input: %{file_path: "test.rb"}})}
      )

      send(
        view.pid,
        {:agent_event, agent_event(:tool_end, %{tool: "read", duration_ms: 50}, 2)}
      )

      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "done"}, 3)})

      rendered = render(view)
      assert rendered =~ "Explored 1 file"
      assert rendered =~ "done"
    end

    test "turn header includes truncated summary", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "test"})})
      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "hello world"})})
      send(view.pid, {:agent_event, agent_event(:run_end, %{status: "completed", turns: 1}, 2)})

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "test"}, 3)})
      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "bonus"}, 4)})

      rendered = render(view)
      assert rendered =~ "turn-summary"
    end

    test "system error messages belong to their turn", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "test"})})
      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "reply"})})

      send(
        view.pid,
        {:agent_event, agent_event(:run_end, %{status: "error", turns: 0, error: "timeout"}, 2)}
      )

      rendered = render(view)
      assert rendered =~ "reply"
      assert rendered =~ "timeout"
    end
  end

  describe "tool call folding" do
    test "assistant text after tool call starts a new message segment", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "test"})})
      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "Before tool."})})

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_start, %{tool: "read", input: %{file_path: "README.md"}}, 2)}
      )

      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "After tool."}, 3)})

      rendered = render(view)
      before_pos = :binary.match(rendered, "Before tool.") |> elem(0)
      tool_pos = :binary.match(rendered, "README.md") |> elem(0)
      after_pos = :binary.match(rendered, "After tool.") |> elem(0)

      assert before_pos < tool_pos
      assert tool_pos < after_pos
    end

    test "tool call finalizes previous assistant stream item", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "test"})})
      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "Before tool."})})

      assert render(view) =~ ~s(data-streaming="true")

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_start, %{tool: "read", input: %{file_path: "README.md"}}, 2)}
      )

      rendered = render(view)
      assert rendered =~ ~s(data-final="true")
      assert rendered =~ ~s(data-streaming="false")
    end

    test "active tool work stays open and collapses once the run ends", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "test"})})

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_start, %{
           tool_use_id: "tu_1",
           tool: "read",
           input: %{file_path: "a.ex"}
         })}
      )

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_end, %{tool_use_id: "tu_1", tool: "read", duration_ms: 30}, 2)}
      )

      send(
        view.pid,
        {:agent_event,
         agent_event(
           :tool_start,
           %{tool_use_id: "tu_2", tool: "bash", input: %{command: "ls"}},
           3
         )}
      )

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_end, %{tool_use_id: "tu_2", tool: "bash", duration_ms: 20}, 4)}
      )

      rendered = render(view)
      assert rendered =~ "tool-work-open"
      refute rendered =~ "tool-work-summary"
      refute rendered =~ "tool-work-collapsed"

      send(
        view.pid,
        {:agent_event, agent_event(:run_end, %{status: "completed"}, 5)}
      )

      rendered = render(view)
      assert rendered =~ "tool-work-collapsed"
      assert rendered =~ "tool-work-summary"
      assert rendered =~ "Explored 1 file, 1 command"
      refute rendered =~ "Hide Work"
    end

    test "completed tools stay compact while a later tool in the streak is running", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "test"})})

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_start, %{
           tool_use_id: "tu_read",
           tool: "read",
           input: %{file_path: "lib/app.ex"}
         })}
      )

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_end, %{tool_use_id: "tu_read", tool: "read", duration_ms: 10}, 2)}
      )

      send(
        view.pid,
        {:agent_event,
         agent_event(
           :tool_start,
           %{tool_use_id: "tu_bash", tool: "bash", input: %{command: "mix test"}},
           3
         )}
      )

      assert has_element?(view, "#tool-work-line-tool-tu_read.tool-work-line", "lib/app.ex")
      assert has_element?(view, "#tool-work-line-tool-tu_bash.tool-work-line", "mix test")
      refute has_element?(view, "#tool-tu_read .tool-status-line")
      refute has_element?(view, "#tool-tu_bash .tool-status-line")
    end

    test "single completed tool call collapses without a group wrapper", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "test"})})

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_start, %{tool: "read", input: %{file_path: "single.ex"}})}
      )

      send(
        view.pid,
        {:agent_event, agent_event(:tool_end, %{tool: "read", duration_ms: 10}, 2)}
      )

      send(
        view.pid,
        {:agent_event, agent_event(:run_end, %{status: "completed"}, 3)}
      )

      rendered = render(view)
      assert rendered =~ "Explored 1 file"
      assert rendered =~ "tool-work-collapsed"
      refute rendered =~ "tool-group"
    end

    test "completed tool work can be expanded and hidden again", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "test"})})

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_start, %{
           tool_use_id: "tu_a",
           tool: "read",
           input: %{file_path: "x.ex"}
         })}
      )

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_end, %{tool_use_id: "tu_a", tool: "read", duration_ms: 10}, 2)}
      )

      send(
        view.pid,
        {:agent_event,
         agent_event(
           :tool_start,
           %{tool_use_id: "tu_b", tool: "write", input: %{content: "abc"}},
           3
         )}
      )

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_end, %{tool_use_id: "tu_b", tool: "write", duration_ms: 5}, 4)}
      )

      send(
        view.pid,
        {:agent_event, agent_event(:run_end, %{status: "completed"}, 5)}
      )

      rendered = render(view)
      assert rendered =~ "Edited 1 file, Explored 1 file"
      refute rendered =~ "Hide Work"

      view
      |> element("#tool-work-summary-tool-tu_a")
      |> render_click()

      expanded = render(view)
      refute expanded =~ "Hide Work"
      assert expanded =~ "tool-work-line-tool-tu_a"
      assert expanded =~ "indent-2"
      assert has_element?(view, "#tool-work-line-tool-tu_a .tool-work-verb", "read")
      assert expanded =~ "x.ex"
      assert expanded =~ "indent-1"
      refute expanded =~ "tool-work-collapsed"
      refute expanded =~ "tool-status-line"

      view
      |> element("#tool-work-summary-tool-tu_a")
      |> render_click()

      collapsed = render(view)
      assert collapsed =~ "Edited 1 file, Explored 1 file"
      refute collapsed =~ "Hide Work"
    end

    test "collapsed tool work defers later file change cards until expanded", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "test"})})

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_start, %{
           tool_use_id: "tu_lead",
           tool: "read",
           input: %{file_path: "x.ex"}
         })}
      )

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_end, %{tool_use_id: "tu_lead", tool: "read", duration_ms: 10}, 2)}
      )

      send(
        view.pid,
        {:agent_event,
         agent_event(
           :tool_start,
           %{tool_use_id: "tu_change", tool: "edit", input: %{file_path: "y.ex"}},
           3
         )}
      )

      send(
        view.pid,
        {:agent_event,
         agent_event(
           :tool_end,
           %{
             tool_use_id: "tu_change",
             tool: "edit",
             duration_ms: 5,
             details: %{
               file_path: "y.ex",
               diff_lines: [%{"type" => "ins", "text" => "new line"}]
             }
           },
           4
         )}
      )

      send(
        view.pid,
        {:agent_event, agent_event(:run_end, %{status: "completed"}, 5)}
      )

      refute has_element?(view, "#chat-file-change-tool-tu_change")

      view
      |> element("#tool-work-summary-tool-tu_lead")
      |> render_click()

      assert has_element?(view, "#chat-file-change-tool-tu_change")
    end
  end
end
