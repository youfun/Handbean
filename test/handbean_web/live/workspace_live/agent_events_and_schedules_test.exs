defmodule HandbeanWeb.WorkspaceLive.AgentEventsAndSchedulesTest do
  use HandbeanWeb.WorkspaceLiveCase

  describe "agent events via handle_info" do
    test "run_start event sets running state and clears previous tool state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "claude-sonnet"})})

      assert has_element?(view, "#status-label", "running")
      assert has_element?(view, ~s(#status-bar[data-model="claude-sonnet"]))
    end

    test "model switch events distinguish active and next-request models", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "sol-model"})})

      send(
        view.pid,
        {:agent_event,
         agent_event(
           :model_switch_accepted,
           %{model_ref: "grok-model", model: "grok-model", status: :accepted, revision: 2},
           2
         )}
      )

      assert has_element?(view, ~s(#status-bar[data-model="sol-model"]))
      assert has_element?(view, "#status-active-model", "sol-model")
      assert has_element?(view, "#status-pending-model", "grok-model next request")

      send(
        view.pid,
        {:agent_event,
         agent_event(
           :provider_request_started,
           %{model: "sol-model", config_revision: 1},
           3
         )}
      )

      assert has_element?(view, "#status-active-model", "sol-model")
      assert has_element?(view, "#status-pending-model", "grok-model next request")

      send(
        view.pid,
        {:agent_event,
         agent_event(
           :model_switch_applied,
           %{model_ref: "grok-model", model: "grok-model", status: :applied, revision: 2},
           4
         )}
      )

      assert has_element?(view, ~s(#status-bar[data-model="grok-model"]))
      assert has_element?(view, "#status-active-model", "grok-model")
      refute has_element?(view, "#status-pending-model")
    end

    test "recovery metadata overrides missing or stale model switch events" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          available_models: [],
          status_info: %{
            model: "old-model",
            active_model: "old-model",
            pending_model: "stale-model",
            pending_model_revision: 1,
            future_model: "future-model"
          }
        }
      }

      recovered =
        HandbeanWeb.WorkspaceLive.RuntimeProjection.reconcile_model_status(
          socket,
          %{
            active_model: %{model: "sol-model", model_ref: "sol-model", revision: 0},
            pending_model: %{model: "grok-model", model_ref: "grok-model", revision: 2},
            model_switch_status: :accepted,
            model_switch_revision: 2
          },
          true
        )

      assert recovered.assigns.status_info.active_model == "sol-model"
      assert recovered.assigns.status_info.pending_model == "grok-model"
      assert recovered.assigns.status_info.pending_model_revision == 2
      assert recovered.assigns.status_info.future_model == "future-model"

      cleared =
        HandbeanWeb.WorkspaceLive.RuntimeProjection.reconcile_model_status(
          recovered,
          %{
            active_model: %{model: "sol-model"},
            pending_model: nil,
            model_switch_status: :cancelled,
            model_switch_revision: 3
          },
          true
        )

      assert cleared.assigns.status_info.pending_model == nil
      assert cleared.assigns.status_info.pending_model_revision == nil
    end

    test "run_start event via bare struct (no tuple wrapper)", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, agent_event(:run_start, %{model: "claude-haiku"}))

      assert has_element?(view, "#status-label", "running")
      assert has_element?(view, ~s(#status-bar[data-model="claude-haiku"]))
    end

    test "message_delta appends a new assistant message", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "Hello, I am"})})

      assert has_element?(view, ".msg-bubble.msg-assistant", "Hello, I am")
    end

    test "ignores tuple-wrapped agent events from a stale session topic", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      current_sid = view |> render() |> session_id_from_html()
      stale_topic = "session:stale-conversation"

      send(
        view.pid,
        {:agent_event,
         agent_event(:message_delta, %{chunk: "stale assistant text"}, 1, stale_topic)}
      )

      assert is_binary(current_sid)
      refute render(view) =~ "stale assistant text"
    end

    test "ignores bare AgentEvent structs from a stale session topic", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        agent_event(:message_delta, %{chunk: "bare stale assistant text"}, 1, "session:old-conv")
      )

      refute render(view) =~ "bare stale assistant text"
    end

    test "message_delta merges into last assistant message incrementally", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "Part 1. "})})

      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "Part 2."}, 2)})

      # Should have ONE assistant message with combined content
      html = render(view)
      assert html =~ "Part 1. Part 2."
    end

    test "thinking_delta shows thinking status without exposing content", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "step-router-v1"})})

      send(
        view.pid,
        {:agent_event, agent_event(:thinking_delta, %{chunk: "private reasoning"}, 2)}
      )

      html = render(view)
      refute html =~ "private reasoning"

      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "Visible answer"}, 3)})

      html = render(view)
      refute html =~ "private reasoning"
      assert html =~ "Visible answer"
    end

    test "message_delta after user message creates new assistant block", %{conn: conn} do
      with_log(fn ->
        {:ok, view, _html} = live(conn, "/")
        view |> element("form") |> render_submit(%{"message" => "Hello"})
        send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "Hi there!"})})
        assert render(view) =~ "Hello"
        assert render(view) =~ "Hi there!"
      end)
    end

    test "tool_start event displays compact tool verb and input summary", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_start, %{
           tool_use_id: "tu_read_1",
           tool: "read",
           input: %{file_path: "config/runtime.exs"}
         })}
      )

      assert has_element?(view, "#tool-tu_read_1")
      assert has_element?(view, "#tool-tu_read_1", "read")
      assert has_element?(view, "#tool-tu_read_1", "runtime.exs")
    end

    test "tool_start event with command input shows command summary", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        {:agent_event, agent_event(:tool_start, %{tool: "bash", input: %{command: "mix test"}})}
      )

      assert has_element?(view, "#tool-event-bash")
      assert has_element?(view, "#tool-event-bash", "$")
      assert has_element?(view, "#tool-event-bash", "mix test")
      assert has_element?(view, "#tool-work-line-tool-event-bash.tool-work-line")
      refute has_element?(view, "#tool-event-bash .tool-status-line")
    end

    test "tool_start event with content input shows content summary", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_start, %{tool: "write", input: %{content: "defmodule Foo do end"}})}
      )

      assert has_element?(view, "#tool-event-write")
      assert has_element?(view, "#tool-event-write", "defmodule Foo do end")
    end

    test "tool_start event with empty input shows only the compact verb", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:tool_start, %{tool: "read", input: %{}})})

      assert has_element?(view, "#tool-event-read")
    end

    test "tool_end event updates tool status to done with duration", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        {:agent_event, agent_event(:tool_start, %{tool: "read", input: %{file_path: "test.txt"}})}
      )

      send(view.pid, {:agent_event, agent_event(:tool_end, %{tool: "read", duration_ms: 250}, 2)})

      rendered = render(view)
      assert rendered =~ "Explored 1 file"
      assert rendered =~ "tool-work-collapsed"
    end

    test "schedule center owns one-shot controls and follows the current conversation", %{
      conn: conn
    } do
      {:ok, conversation} = Handbean.ConversationStore.create("default", title: "Scheduled check")

      {:ok, schedule} =
        Handbean.Schedule.Store.create(%{
          workspace_id: "default",
          conversation_id: conversation["id"],
          name: "检查编译",
          instruction: "汇报编译结果",
          time_zone: "Asia/Shanghai",
          model: "fake/model",
          rule: %{
            "kind" => "once",
            "label" => "一小时后，只一次",
            "at" =>
              Handbean.Schedule.now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()
          }
        })

      {:ok, view, _html} = live(conn, "/w/default/c/#{conversation["id"]}")
      card = "#schedule-#{schedule.id}"

      assert has_element?(view, "#activity-bar #schedule-nav")
      refute has_element?(view, ".schedule-launcher")
      refute has_element?(view, "#once-schedule-dock")
      refute has_element?(view, "#schedule-center")

      view |> element("#schedule-nav") |> render_click()

      assert has_element?(view, "#schedule-center #{card}")
      refute has_element?(view, "#ai-input-area")
      refute has_element?(view, "#workspace-panel")
      assert has_element?(view, "#{card} [phx-click='schedule_pause']")

      view |> element("#{card} [phx-click='schedule_pause']") |> render_click()
      assert has_element?(view, "#{card} [phx-click='schedule_resume']")
      assert {:ok, %{status: "paused"}} = Handbean.Schedule.Store.get(schedule.id)

      view |> element("#{card} [phx-click='schedule_resume']") |> render_click()
      assert has_element?(view, "#{card} [phx-click='schedule_pause']")
      assert {:ok, %{status: "active"}} = Handbean.Schedule.Store.get(schedule.id)

      create_default_conversation(view)
      refute has_element?(view, "#schedule-center")
      send(view.pid, {:schedule_changed, conversation["id"]})
      refute has_element?(view, card)

      render_patch(view, "/w/default/c/#{conversation["id"]}")
      view |> element("#schedule-nav") |> render_click()
      assert has_element?(view, card)
      assert has_element?(view, "#{card} button[phx-click='schedule_delete']")
      view |> element("#{card} [phx-click='schedule_delete']") |> render_click()
      refute has_element?(view, card)
      assert {:error, :not_found} = Handbean.Schedule.Store.get(schedule.id)

      {:ok, pending} =
        schedule
        |> Map.from_struct()
        |> Handbean.Schedule.Store.create()

      send(view.pid, {:schedule_changed, conversation["id"]})
      assert has_element?(view, "#schedule-#{pending.id}")
      assert {:ok, claim} = Handbean.Schedule.Store.claim(pending, pending.next_run_at)
      send(view.pid, {:schedule_changed, conversation["id"]})
      assert has_element?(view, "#schedule-#{pending.id}")

      assert {:ok, _} = Handbean.Schedule.Store.finish_run(claim.run, "completed")
      send(view.pid, {:schedule_changed, conversation["id"]})
      assert has_element?(view, "#schedule-#{pending.id}", "已完成")
      refute has_element?(view, "#once-schedule-dock")
    end

    test "creating a schedule from the center opens a conversation in the current workspace", %{
      conn: conn
    } do
      project_dir =
        Path.join(
          System.tmp_dir!(),
          "sigil_schedule_project_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(project_dir)

      try do
        {:ok, project} = Handbean.WorkspaceStore.add(project_dir, name: "Schedule Project")

        {:ok, conversation} =
          Handbean.ConversationStore.create(project["id"], title: "Project chat")

        {:ok, view, html} = live(conn, "/w/#{project["id"]}/c/#{conversation["id"]}")
        origin_id = session_id_from_html(html)

        view |> element("#schedule-nav") |> render_click()
        assert has_element?(view, "#schedule-center")
        assert has_element?(view, "#schedule-workspace")
        assert render(view) =~ "任务会在「Schedule Project」的新对话中运行并返回结果"

        request = "工作日每天 09:00，把项目摘要发到这个聊天"

        view
        |> form("#schedule-ask", %{"request" => request})
        |> render_submit()

        html = render(view)
        new_id = session_id_from_html(html)

        refute has_element?(view, "#schedule-center")
        assert new_id != origin_id
        assert new_id != conversation["id"]
        assert {:ok, created} = Handbean.ConversationStore.get(new_id, include_timeline?: false)
        assert created["workspace_id"] == project["id"]
        assert html =~ request
        refute render(view) =~ ~s(data-session-id="#{conversation["id"]}")
      after
        File.rm_rf!(project_dir)
      end
    end

    test "revising a schedule from the center stays in the current conversation", %{conn: conn} do
      {:ok, conversation} = Handbean.ConversationStore.create("default", title: "Scheduled check")

      {:ok, schedule} =
        Handbean.Schedule.Store.create(%{
          workspace_id: "default",
          conversation_id: conversation["id"],
          name: "检查编译",
          instruction: "汇报编译结果",
          time_zone: "Asia/Shanghai",
          model: "fake/model",
          rule: %{
            "kind" => "weekly",
            "weekdays" => [1, 2, 3, 4, 5],
            "times" => ["09:00"]
          }
        })

      {:ok, view, _html} = live(conn, "/w/default/c/#{conversation["id"]}")
      view |> element("#schedule-nav") |> render_click()

      view
      |> element("#schedule-#{schedule.id} [phx-click='schedule_revise']")
      |> render_click()

      request = "把「检查编译」改成：每天 10:00"

      view
      |> form("#schedule-ask", %{"request" => request})
      |> render_submit()

      html = render(view)
      refute has_element?(view, "#schedule-center")
      assert session_id_from_html(html) == conversation["id"]
      assert html =~ request
    end

    test "schedule center lists every task and opens its conversation", %{conn: conn} do
      {:ok, host} = Handbean.ConversationStore.create("default", title: "天气日报")

      {:ok, schedule} =
        Handbean.Schedule.Store.create(%{
          workspace_id: "default",
          conversation_id: host["id"],
          name: "每天天气",
          instruction: "报告今天天气",
          time_zone: "Asia/Shanghai",
          model: "fake/model",
          rule: %{
            "kind" => "weekly",
            "weekdays" => [1, 2, 3, 4, 5, 6, 7],
            "times" => ["09:00"]
          }
        })

      {:ok, other} = Handbean.ConversationStore.create("default", title: "别的对话")
      {:ok, view, _html} = live(conn, "/w/default/c/#{other["id"]}")
      card = "#schedule-#{schedule.id}"

      view |> element("#schedule-nav") |> render_click()

      assert has_element?(view, "#schedule-center #{card}")
      assert has_element?(view, "#{card} #schedule-#{schedule.id}-conversation", "天气日报")

      view
      |> element("#{card} #schedule-#{schedule.id}-conversation")
      |> render_click()

      html = render(view)
      refute has_element?(view, "#schedule-center")
      assert session_id_from_html(html) == host["id"]
    end

    test "deleted one-shots and recurring tools do not leave cards in the composer dock",
         %{
           conn: conn
         } do
      old_once = %{
        "id" => "old-once-tool",
        "content_type" => "tool",
        "tool_name" => "schedule",
        "input" => %{
          "action" => "create",
          "name" => "很早以前的检查",
          "instruction" => "即使消息很多也保留删除态",
          "rule" => %{"kind" => "once", "at" => "2026-10-12T01:05:00Z"}
        },
        "output" => Handbean.JSON.encode!(%{"id" => "old-gone-once"})
      }

      later_messages =
        Enum.map(1..101, fn index ->
          %{
            "id" => "later-user-#{index}",
            "content_type" => "user_msg",
            "role" => "user",
            "content" => "later message #{index}"
          }
        end)

      {:ok, conversation} =
        Handbean.ConversationStore.create("default",
          title: "Schedule projection",
          timeline: [old_once | later_messages]
        )

      {:ok, view, _html} = live(conn, "/w/default/c/#{conversation["id"]}")

      refute has_element?(view, "#once-schedule-dock")

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_start, %{
           tool_use_id: "once-deleted",
           tool: "schedule",
           input: %{
             "action" => "create",
             "name" => "检查编译",
             "instruction" => "汇报测试和打包结果",
             "rule" => %{"kind" => "once", "at" => "2026-10-12T02:05:00Z"}
           }
         })}
      )

      send(
        view.pid,
        {:agent_event,
         agent_event(
           :tool_end,
           %{
             tool_use_id: "once-deleted",
             tool: "schedule",
             output: Handbean.JSON.encode!(%{"id" => "gone-once"})
           },
           2
         )}
      )

      refute has_element?(view, "#once-schedule-dock")
      refute has_element?(view, "#once-card-tool-once-deleted [phx-click='schedule_delete']")

      send(
        view.pid,
        {:agent_event,
         agent_event(
           :tool_start,
           %{
             tool_use_id: "recurring-deleted",
             tool: "schedule",
             input: %{
               "action" => "create",
               "rule" => %{"kind" => "interval", "every_minutes" => 5}
             }
           },
           3
         )}
      )

      send(
        view.pid,
        {:agent_event,
         agent_event(
           :tool_end,
           %{
             tool_use_id: "recurring-deleted",
             tool: "schedule",
             output: Handbean.JSON.encode!(%{"id" => "gone-recurring"})
           },
           4
         )}
      )

      refute has_element?(view, "#once-card-tool-recurring-deleted")

      create_default_conversation(view)
      refute has_element?(view, "#once-schedule-dock")

      render_patch(view, "/w/default/c/#{conversation["id"]}")
      refute has_element?(view, "#once-schedule-dock")

      render_click(view, "new_free_conversation")
      refute has_element?(view, "#once-schedule-dock")
    end
  end
end
