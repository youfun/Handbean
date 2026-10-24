defmodule HandbeanWeb.WorkspaceLive.NavigationAndFreeChatTest do
  use HandbeanWeb.WorkspaceLiveCase

  defmodule RefusingTranscriptStore do
    @behaviour Handbean.ConversationTranscriptStore

    alias Handbean.ConversationTranscriptStore.ConversationStore

    def list(conversation_id, opts), do: ConversationStore.list(conversation_id, opts)
    def page(conversation_id, opts), do: ConversationStore.page(conversation_id, opts)
    def append(_conversation_id, _entry, _opts), do: {:error, :storage_unavailable}

    def update(conversation_id, entry_id, patch, opts),
      do: ConversationStore.update(conversation_id, entry_id, patch, opts)

    def delete(conversation_id, entry_id, opts),
      do: ConversationStore.delete(conversation_id, entry_id, opts)

    def replace_all(conversation_id, entries, opts),
      do: ConversationStore.replace_all(conversation_id, entries, opts)
  end

  defmodule RefusingDeleteTranscriptStore do
    @behaviour Handbean.ConversationTranscriptStore

    alias Handbean.ConversationTranscriptStore.ConversationStore

    def list(conversation_id, opts), do: ConversationStore.list(conversation_id, opts)
    def page(conversation_id, opts), do: ConversationStore.page(conversation_id, opts)

    def append(conversation_id, entry, opts),
      do: ConversationStore.append(conversation_id, entry, opts)

    def update(conversation_id, entry_id, patch, opts),
      do: ConversationStore.update(conversation_id, entry_id, patch, opts)

    def delete(_conversation_id, _entry_id, _opts), do: {:error, :storage_unavailable}

    def replace_all(conversation_id, entries, opts),
      do: ConversationStore.replace_all(conversation_id, entries, opts)
  end

  describe "skill autocomplete" do
    setup do
      on_exit(fn ->
        home_skills = Path.join([System.get_env("HOME") || "", ".handbean", "skills"])

        if File.dir?(home_skills) do
          home_skills
          |> File.ls!()
          |> Enum.each(fn name ->
            if String.starts_with?(name, "autocomplete-") or name in ["other-skill", "other-code"] do
              File.rm_rf!(Path.join(home_skills, name))
            end
          end)
        end
      end)

      :ok
    end

    defp create_test_skill(name, description) do
      skill_dir =
        Path.join([System.get_env("HOME") || Handbean.Home.path(), ".handbean", "skills", name])

      File.mkdir_p!(skill_dir)

      File.write!(
        Path.join(skill_dir, "SKILL.md"),
        """
        ---
        name: #{name}
        description: #{description}
        ---

        Test skill body.
        """
      )

      :ok
    end

    test "typing / shows skill suggestions dropdown", %{conn: conn} do
      create_test_skill("autocomplete-alpha", "Alpha skill for testing")
      create_test_skill("autocomplete-beta", "Beta skill for testing")

      {:ok, view, _html} = live(conn, "/")

      html = render_keyup(view, "update_input", %{"value" => "/"})

      # The dropdown should appear with both skills
      assert html =~ "skill-suggestions"
      assert html =~ "autocomplete-alpha"
      assert html =~ "autocomplete-beta"
    end

    test "typing /autocomplete filters to matching skills", %{conn: conn} do
      create_test_skill("autocomplete-alpha", "Alpha")
      create_test_skill("autocomplete-beta", "Beta")
      create_test_skill("other-skill", "Other")

      {:ok, view, _html} = live(conn, "/")

      html = render_keyup(view, "update_input", %{"value" => "/autocomplete"})

      assert html =~ "skill-suggestions"
      assert html =~ "autocomplete-alpha"
      assert html =~ "autocomplete-beta"
      refute html =~ "other-skill"
    end

    test "typing /xyz with no match shows no suggestions", %{conn: conn} do
      create_test_skill("autocomplete-alpha", "Alpha")

      {:ok, view, _html} = live(conn, "/")

      html = render_keyup(view, "update_input", %{"value" => "/xyz"})

      # No dropdown when no matches
      refute html =~ "skill-suggestions"
    end

    test "typing plain text without / shows no suggestions", %{conn: conn} do
      create_test_skill("autocomplete-alpha", "Alpha")

      {:ok, view, _html} = live(conn, "/")

      html = render_keyup(view, "update_input", %{"value" => "hello world"})

      refute html =~ "skill-suggestions"
    end

    test "selecting a skill suggestion replaces input with /skill:name", %{conn: conn} do
      create_test_skill("autocomplete-alpha", "Alpha skill for testing")

      {:ok, view, _html} = live(conn, "/")

      # First, simulate typing "/auto"
      _html = render_keyup(view, "update_input", %{"value" => "/auto"})

      # Then select the suggestion
      html =
        view
        |> element(
          "button[phx-click='select_skill_suggestion'][phx-value-name='autocomplete-alpha']"
        )
        |> render_click()

      # Input should now contain /skill:autocomplete-alpha
      assert html =~ "/skill:autocomplete-alpha"
      # Dropdown should be dismissed
      refute html =~ "skill-suggestions"
    end

    test "dismissing skill suggestions clears the dropdown", %{conn: conn} do
      create_test_skill("autocomplete-alpha", "Alpha")

      {:ok, view, _html} = live(conn, "/")

      _html = render_keyup(view, "update_input", %{"value" => "/"})

      html = render_click(view, "dismiss_skill_suggestions", %{})

      refute html =~ "skill-suggestions"
    end

    test "typing /skill: filters by skill name after prefix", %{conn: conn} do
      create_test_skill("autocomplete-alpha", "Alpha")
      create_test_skill("autocomplete-beta", "Beta")
      create_test_skill("other-code", "Code")

      {:ok, view, _html} = live(conn, "/")

      html = render_keyup(view, "update_input", %{"value" => "/skill:auto"})

      assert html =~ "skill-suggestions"
      assert html =~ "autocomplete-alpha"
      assert html =~ "autocomplete-beta"
      refute html =~ "other-code"
    end
  end

  describe "conversation navigator" do
    test "renders delegation reports as collapsed cards without wrapper JSON or user navigation",
         %{
           conn: conn
         } do
      completed =
        "Background subagent report for child_conversation_id child-research (requires your review; use task_status to follow up):\n" <>
          Handbean.JSON.encode!(%{
            status: :completed,
            subagent_type: "researcher",
            child_conversation_id: "child-research",
            child_run_id: "run-research",
            usage: %{
              input_tokens: 5_481,
              output_tokens: 827,
              cache_read_input_tokens: 300
            },
            report: "## Finding\n\nOnly the **report** is rendered."
          })

      max_turns =
        "Background subagent report for child_conversation_id child-max (requires your review; use task_status to follow up):\n" <>
          Handbean.JSON.encode!(%{
            status: :max_turns,
            subagent_type: "researcher",
            child_conversation_id: "child-max",
            usage: %{input_tokens: "1200", output_tokens: 42},
            report: "Reached the turn limit with a usable result."
          })

      failed =
        "Background subagent report for child_conversation_id child-error (requires your review; use task_status to follow up):\n" <>
          Handbean.JSON.encode!(%{
            status: :error,
            subagent_type: "advisor",
            child_conversation_id: "child-error",
            error: "Provider unavailable"
          })

      legacy =
        "Background subagent report for child_conversation_id child-legacy (requires your review):\n" <>
          Handbean.JSON.encode!(%{report: "Legacy report body"})

      {:ok, conversation} =
        Handbean.ConversationStore.create("default",
          id: "conv-subagent-reports",
          title: "Subagent reports",
          timeline: [
            %{
              "id" => "report-completed",
              "content_type" => "user_msg",
              "role" => "user",
              "source" => "delegation",
              "channel" => "internal",
              "content" => completed
            },
            %{
              "id" => "nav-user-1",
              "content_type" => "user_msg",
              "role" => "user",
              "content" => "First real user message"
            },
            %{
              "id" => "report-max",
              "content_type" => "user_msg",
              "role" => "user",
              "source" => "delegation",
              "channel" => "internal",
              "content" => max_turns
            },
            %{
              "id" => "report-error",
              "content_type" => "user_msg",
              "role" => "user",
              "source" => "delegation",
              "channel" => "internal",
              "content" => failed
            },
            %{
              "id" => "report-legacy",
              "content_type" => "user_msg",
              "role" => "user",
              "content" => legacy
            },
            %{
              "id" => "report-malformed",
              "content_type" => "user_msg",
              "role" => "user",
              "source" => "delegation",
              "channel" => "internal",
              "content" => "not valid report JSON"
            },
            %{
              "id" => "nav-user-2",
              "content_type" => "user_msg",
              "role" => "user",
              "content" => "Second real user message"
            }
          ]
        )

      {:ok, view, html} = live(conn, "/w/default/c/#{conversation["id"]}")

      assert html |> Floki.parse_fragment!() |> Floki.find("[data-subagent-report]") |> length() ==
               5

      assert has_element?(
               view,
               "[data-subagent-report][data-status='completed'] details:not([open])"
             )

      assert has_element?(view, "[data-subagent-report][data-status='max_turns']")

      assert has_element?(
               view,
               "[data-subagent-report][data-status='error']",
               "Provider unavailable"
             )

      assert has_element?(
               view,
               "[data-subagent-report][data-status='unknown']",
               "Legacy report body"
             )

      assert has_element?(
               view,
               "#subagent-report-report-malformed-unknown-0",
               "Report unavailable"
             )

      assert has_element?(
               view,
               "[data-subagent-report] [data-source*='Only the **report** is rendered.']"
             )

      assert has_element?(view, "[data-subagent-report]", "Input 5.5K")
      assert has_element?(view, "[data-subagent-report]", "Output 827")
      assert has_element?(view, "[data-subagent-report] [data-copy='child-research']")
      refute html =~ "Background subagent report"
      refute html =~ "child_run_id"
      refute has_element?(view, "[data-user-msg='report-completed']")
      refute has_element?(view, "[data-user-msg='report-max']")
      refute has_element?(view, "[data-user-msg='report-malformed']")
      refute has_element?(view, "[data-target-id='report-completed']")
      assert has_element?(view, "[data-target-id='nav-user-1']")
      assert has_element?(view, "[data-target-id='nav-user-2']")
      assert has_element?(view, "#turn-header", "First real user message")

      html =
        view
        |> element(
          "#subagent-report-report-completed-child-research-0 .subagent-report-follow-up"
        )
        |> render_click()

      assert html =~ "@child-research "
    end

    test "lists only user messages next to the scroll-to-bottom control", %{conn: conn} do
      isolate_conversation_home!()

      {:ok, conversation} =
        Handbean.ConversationStore.create("default",
          id: "conv-nav-many",
          title: "Nav many",
          timeline: [
            %{
              "id" => "nav-user-1",
              "content_type" => "user_msg",
              "role" => "user",
              "content" => "先看第一轮用户问题"
            },
            %{
              "id" => "nav-assistant-1",
              "content_type" => "assistant_msg",
              "role" => "assistant",
              "content" => "助手不该出现在导航"
            },
            %{
              "id" => "nav-tool-1",
              "content_type" => "tool",
              "tool_name" => "read",
              "content" => "README.md"
            },
            %{
              "id" => "nav-user-2",
              "content_type" => "user_msg",
              "role" => "user",
              "content" => "再问第二轮"
            }
          ]
        )

      {:ok, _view, html} = live(conn, "/w/default/c/#{conversation["id"]}")

      assert html =~ ~s(id="conversation-nav")
      assert html =~ ~s(data-conversation-nav-toggle)
      assert html =~ ~s(id="mobile-fab")
      assert html =~ ~s(data-target-id="nav-user-1")
      assert html =~ ~s(data-target-id="nav-user-2")
      assert html =~ "先看第一轮用户问题"
      assert html =~ "再问第二轮"
      refute html =~ ~s(data-target-id="nav-assistant-1")
      refute html =~ ~s(data-target-id="nav-tool-1")
    end

    test "hides internal model compaction checkpoints", %{conn: conn} do
      isolate_conversation_home!()

      {:ok, conversation} =
        Handbean.ConversationStore.create("default",
          id: "conv-hidden-compaction",
          title: "Hidden compaction",
          timeline: [
            %{
              "id" => "compaction-hidden-1",
              "content_type" => "model_compaction",
              "message_type" => "internal",
              "role" => "internal",
              "summary" => "PRIVATE-COMPACTION-SUMMARY"
            },
            %{
              "id" => "visible-user",
              "content_type" => "user_msg",
              "role" => "user",
              "content" => "Visible request"
            }
          ]
        )

      {:ok, view, html} = live(conn, "/w/default/c/#{conversation["id"]}")

      assert html =~ "Visible request"
      refute html =~ "PRIVATE-COMPACTION-SUMMARY"
      refute has_element?(view, "#timeline-compaction-hidden-1")
      refute has_element?(view, "[data-target-id='compaction-hidden-1']")
    end

    test "hides the hamburger when there are fewer than two user turns", %{conn: conn} do
      isolate_conversation_home!()

      {:ok, conversation} =
        Handbean.ConversationStore.create("default",
          id: "conv-nav-short",
          title: "Nav short",
          timeline: [
            %{
              "id" => "nav-only-user",
              "content_type" => "user_msg",
              "role" => "user",
              "content" => "只有一条"
            },
            %{
              "id" => "nav-only-assistant",
              "content_type" => "assistant_msg",
              "role" => "assistant",
              "content" => "一条回复"
            }
          ]
        )

      {:ok, _view, html} = live(conn, "/w/default/c/#{conversation["id"]}")

      assert html =~ ~s(id="conversation-nav")
      assert html =~ ~s(id="mobile-fab")
      refute html =~ ~s(data-conversation-nav-toggle)
      refute html =~ ~s(data-target-id="nav-only-user")
    end
  end

  describe "widget commands" do
    test "completed main assistant widgets prefill the draft without changing run state", %{
      conn: conn
    } do
      content = """
      Choose files to move.

      ```html
      <button>Use selection</button>
      ```
      """

      {:ok, conversation} =
        Handbean.ConversationStore.create("default",
          id: "conv-widget-command",
          title: "Widget command",
          timeline: [
            %{
              "id" => "widget-assistant",
              "content_type" => "assistant_msg",
              "role" => "assistant",
              "status" => "completed",
              "content" => content
            }
          ]
        )

      {:ok, view, _html} = live(conn, "/w/default/c/#{conversation["id"]}")

      assert has_element?(
               view,
               "#assistant-md-wrapper-widget-assistant[data-widget-actions='true'][data-entry-id='widget-assistant'][data-conversation-id='#{conversation["id"]}']"
             )

      render_keyup(view, "update_input", %{"value" => "Existing draft"})

      :sys.replace_state(view.pid, fn %{socket: socket} = state ->
        %{state | socket: %{socket | assigns: %{socket.assigns | running: true}}}
      end)

      render_hook(view, "widget_command", %{
        "request_id" => "widget-request-ok",
        "entry_id" => "widget-assistant",
        "fence_index" => 0,
        "command" => "prefill_follow_up",
        "payload" => %{
          "prompt" => "Move the reviewed files.",
          "selections" => [%{"label" => "README.md", "value" => true}]
        }
      })

      expected = "Existing draft\nMove the reviewed files.\n\nSelections:\n- \"README.md\": true"
      assert_push_event(view, "composer:set-input", %{value: ^expected})

      assert_push_event(view, "widget-command-result", %{
        request_id: "widget-request-ok",
        status: "ok"
      })

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.input_value == expected
      assert assigns.running

      assert {:ok, entries} =
               Handbean.ConversationTranscriptStore.list(conversation["id"])

      assert Enum.map(entries, & &1["id"]) == ["widget-assistant"]
    end

    test "rejects an entry id from another conversation and leaves the draft untouched", %{
      conn: conn
    } do
      {:ok, current} =
        Handbean.ConversationStore.create("default",
          id: "conv-widget-current",
          title: "Current widget",
          timeline: [
            %{
              "id" => "current-assistant",
              "content_type" => "assistant_msg",
              "role" => "assistant",
              "status" => "completed",
              "content" => "```html\n<p>Current</p>\n```"
            }
          ]
        )

      {:ok, _other} =
        Handbean.ConversationStore.create("default",
          id: "conv-widget-other",
          title: "Other widget",
          timeline: [
            %{
              "id" => "other-assistant",
              "content_type" => "assistant_msg",
              "role" => "assistant",
              "status" => "completed",
              "content" => "```widget\n<button>Other</button>\n```"
            }
          ]
        )

      {:ok, view, _html} = live(conn, "/w/default/c/#{current["id"]}")
      render_keyup(view, "update_input", %{"value" => "Do not replace"})

      render_hook(view, "widget_command", %{
        "request_id" => "widget-request-error",
        "entry_id" => "other-assistant",
        "fence_index" => 0,
        "command" => "prefill_follow_up",
        "payload" => %{"prompt" => "Untrusted follow-up"}
      })

      assert_push_event(view, "widget-command-result", %{
        request_id: "widget-request-error",
        status: "error",
        reason: "entry_not_found"
      })

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.input_value == "Do not replace"
      refute assigns.running
    end
  end

  describe "new conversation first message" do
    test "a terminal staging failure restores the submitted text", %{conn: conn} do
      configure_test_models!()
      {:ok, view, _html} = live(conn, "/")

      view |> element("#new-conversation-picker-toggle") |> render_click()
      html = render(view)
      [draft_id] = Regex.run(~r/name="draft_id" value="([^"]+)"/, html, capture: :all_but_first)
      previous = Application.get_env(:handbean, :conversation_transcript_store)
      Application.put_env(:handbean, :conversation_transcript_store, RefusingTranscriptStore)

      try do
        view
        |> form("#new-conversation-composer", %{
          "draft_id" => draft_id,
          "message" => "restore this first message"
        })
        |> render_submit()

        assigns = :sys.get_state(view.pid).socket.assigns
        assert assigns.input_value == "restore this first message"
        assert assigns.composer_error =~ "Message not saved"
        assert assigns.pending_new_conversation_message == nil
      after
        if previous,
          do: Application.put_env(:handbean, :conversation_transcript_store, previous),
          else: Application.delete_env(:handbean, :conversation_transcript_store)
      end
    end
  end

  describe "free chat send" do
    test "free-chat draft uses the global catalog despite workspace restrictions", %{
      conn: conn
    } do
      configure_test_models!()
      :ok = Handbean.Settings.save_global(%{"default_model" => "sui2api/gpt-5.5"})
      workspace_path = Handbean.WorkspaceStore.list() |> List.first() |> Map.fetch!("path")

      settings_path = Handbean.WorkspaceSettings.path(workspace_path)
      File.mkdir_p!(Path.dirname(settings_path))

      File.write!(
        settings_path,
        Handbean.JSON.encode!(%{
          "models" => %{
            "allow" => %{
              "providers" => %{"stepfun" => %{"models" => ["step-router-v1"]}}
            }
          }
        })
      )

      {:ok, view, _html} = live(conn, "/")
      view |> element("#new-free-conversation") |> render_click()

      assert has_element?(
               view,
               "#new-conversation-model-picker option[value='sui2api/gpt-5.5'][selected]"
             )

      assert has_element?(
               view,
               "#new-conversation-model-picker option[value='stepfun/step-router-v1']"
             )
    end

    test "sending in a new free chat replies before the run starts", %{conn: conn} do
      isolate_conversation_home!()

      {:ok, view, _html} = live(conn, "/")

      view |> element("#mobile-tab-files") |> render_click()
      assert has_element?(view, "#workspace-panel.mobile-panel-open")

      view
      |> element("button[phx-click='open_sheet'][phx-value-type='workspace']")
      |> render_click()

      assert has_element?(view, "#workspace-sheet[aria-hidden='false']")

      html = view |> element("#new-free-conversation") |> render_click()

      assert has_element?(view, "#workspace-sheet[aria-hidden='true']")

      assert has_element?(
               view,
               ".chat-panel:not(.mobile-right-panel-open) #new-conversation-page"
             )

      refute has_element?(view, "#workspace-panel.mobile-panel-open")
      assert has_element?(view, ".mobile-workspace", "Free chats")
      refute has_element?(view, ".mobile-workspace-tabs")
      assert html =~ "Start with a message"
      assert has_element?(view, "#new-conversation-composer")

      html =
        view
        |> form("#new-conversation-composer", %{message: "hello free chat"})
        |> render_submit()

      assert html =~ "hello free chat"
      assert render(view) =~ "hello free chat"
      refute render(view) =~ "Message not delivered"

      conversation_id = :sys.get_state(view.pid).socket.assigns.current_conversation_id
      assert {:ok, entries} = Handbean.ConversationTranscriptStore.list(conversation_id)
      entry = Enum.find(entries, &(&1["source"] == "new_conversation_draft"))
      assert entry["source"] == "new_conversation_draft"
      assert entry["delivery_status"] == "accepted"
      assert entry["request_id"] == entry["id"]

      assert {:ok, %{"status" => "completed"}} =
               Handbean.Agent.OperationReceipt.lookup(
                 {:message, conversation_id},
                 entry["request_id"]
               )
    end

    test "a pending first message survives admission failure and reconnect", %{conn: conn} do
      configure_test_models!()
      workspace = Handbean.WorkspaceStore.list() |> List.first()

      assert {:ok, conversation} =
               Handbean.ConversationStore.create(workspace["id"],
                 selected_model: "stepfun/step-router-v1",
                 selected_reasoning_level: "medium"
               )

      conversation_id = conversation["id"]
      request_id = "new-conversation-message-reconnect"

      assert {:ok, _entry} =
               Handbean.ConversationTranscriptStore.append(conversation_id, %{
                 "id" => request_id,
                 "content_type" => "user_msg",
                 "message_type" => "user",
                 "role" => "user",
                 "direction" => "inbound",
                 "content" => "survive reconnect",
                 "dispatch_content" => "survive reconnect",
                 "delivery_status" => "pending",
                 "request_id" => request_id,
                 "source" => "new_conversation_draft"
               })

      assert {:ok, _session} = Handbean.PubSub.Session.start_or_get(session_id: conversation_id)

      assert {:ok, queue} =
               Handbean.Agent.CandidateQueue.start_link(
                 session_id: conversation_id,
                 owner: self(),
                 max_size: 1
               )

      assert :ok =
               Handbean.PubSub.Session.attach_run(conversation_id, self(), queue,
                 run_id: "pending-draft-run"
               )

      assert :ok =
               Handbean.Agent.CandidateQueue.enqueue(queue, "occupied",
                 message_id: "occupied",
                 deliver_as: :follow_up
               )

      path = "/w/#{workspace["id"]}/c/#{conversation_id}"
      {:ok, first_view, _html} = live(conn, path)

      assert {:ok, [pending_entry]} =
               Handbean.ConversationTranscriptStore.list(conversation_id)

      assert pending_entry["delivery_status"] == "pending"

      assert :error =
               Handbean.Agent.OperationReceipt.lookup({:message, conversation_id}, request_id)

      assert {:ok, _deleted} =
               Handbean.Agent.CandidateQueue.delete_message(queue, "occupied")

      {:ok, second_view, _html} = live(recycle(conn), path)

      assert {:ok, [accepted_entry]} =
               Handbean.ConversationTranscriptStore.list(conversation_id)

      assert accepted_entry["delivery_status"] == "accepted"

      assert {:ok, %{"status" => "completed"}} =
               Handbean.Agent.OperationReceipt.lookup({:message, conversation_id}, request_id)

      assert length(Handbean.Agent.CandidateQueue.get_messages(queue)) == 1
      assert render(first_view) =~ "survive reconnect"
      assert render(second_view) =~ "survive reconnect"
    end

    test "concurrent reconnects serialize the same pending first-message delivery", %{conn: conn} do
      configure_test_models!()
      workspace = Handbean.WorkspaceStore.list() |> List.first()

      assert {:ok, conversation} =
               Handbean.ConversationStore.create(workspace["id"],
                 selected_model: "stepfun/step-router-v1",
                 selected_reasoning_level: "medium"
               )

      conversation_id = conversation["id"]
      request_id = "new-conversation-message-concurrent"

      assert {:ok, _entry} =
               Handbean.ConversationTranscriptStore.append(conversation_id, %{
                 "id" => request_id,
                 "content_type" => "user_msg",
                 "message_type" => "user",
                 "role" => "user",
                 "direction" => "inbound",
                 "content" => "deliver exactly once",
                 "dispatch_content" => "deliver exactly once",
                 "delivery_status" => "pending",
                 "request_id" => request_id,
                 "source" => "new_conversation_draft"
               })

      assert {:ok, _session} = Handbean.PubSub.Session.start_or_get(session_id: conversation_id)

      assert {:ok, queue} =
               Handbean.Agent.CandidateQueue.start_link(
                 session_id: conversation_id,
                 owner: self(),
                 max_size: 1
               )

      assert :ok =
               Handbean.PubSub.Session.attach_run(conversation_id, self(), queue,
                 run_id: "concurrent-draft-run"
               )

      assert :ok =
               Handbean.Agent.CandidateQueue.enqueue(queue, "occupied",
                 message_id: "occupied",
                 deliver_as: :follow_up
               )

      path = "/w/#{workspace["id"]}/c/#{conversation_id}"
      {:ok, first_view, _html} = live(recycle(conn), path)
      {:ok, second_view, _html} = live(recycle(conn), path)
      assert {:ok, _deleted} = Handbean.Agent.CandidateQueue.delete_message(queue, "occupied")

      first_socket = :sys.get_state(first_view.pid).socket
      second_socket = :sys.get_state(second_view.pid).socket
      :ok = :sys.suspend(queue)

      first =
        Task.async(fn ->
          HandbeanWeb.WorkspaceLive.ConversationRouting.flush_pending_new_conversation_message(
            first_socket
          )
        end)

      assert_eventually(fn ->
        assert {:ok, %{"status" => "reserved"}} =
                 Handbean.Agent.OperationReceipt.lookup(
                   {:message, conversation_id},
                   request_id
                 )
      end)

      second =
        Task.async(fn ->
          HandbeanWeb.WorkspaceLive.ConversationRouting.flush_pending_new_conversation_message(
            second_socket
          )
        end)

      assert Task.yield(second, 200) == nil

      assert {:ok, %{"status" => "reserved"}} =
               Handbean.Agent.OperationReceipt.lookup({:message, conversation_id}, request_id)

      :ok = :sys.resume(queue)
      assert %Phoenix.LiveView.Socket{} = Task.await(first, 2_000)
      assert %Phoenix.LiveView.Socket{} = Task.await(second, 2_000)

      assert {:ok, %{"status" => "completed"}} =
               Handbean.Agent.OperationReceipt.lookup({:message, conversation_id}, request_id)

      assert [queued] = Handbean.Agent.CandidateQueue.get_messages(queue)
      assert Handbean.Agent.Message.text(queued.message) == "deliver exactly once"

      assert {:ok, [entry]} = Handbean.ConversationTranscriptStore.list(conversation_id)
      assert entry["delivery_status"] == "accepted"
    end

    test "a permanently rejected first message is removed and restored to the composer", %{
      conn: conn
    } do
      configure_test_models!()
      workspace = Handbean.WorkspaceStore.list() |> List.first()

      assert {:ok, conversation} =
               Handbean.ConversationStore.create(workspace["id"],
                 selected_model: "stepfun/step-router-v1",
                 selected_reasoning_level: "medium"
               )

      conversation_id = conversation["id"]
      request_id = "new-conversation-message-terminal"

      assert {:ok, _entry} =
               Handbean.ConversationTranscriptStore.append(conversation_id, %{
                 "id" => request_id,
                 "content_type" => "user_msg",
                 "message_type" => "user",
                 "role" => "user",
                 "direction" => "inbound",
                 "content" => "restore terminal failure",
                 "dispatch_content" => "restore terminal failure",
                 "delivery_status" => "pending",
                 "request_id" => request_id,
                 "source" => "new_conversation_draft"
               })

      assert {:ok, _session} = Handbean.PubSub.Session.start_or_get(session_id: conversation_id)

      assert {:ok, queue} =
               Handbean.Agent.CandidateQueue.start_link(
                 session_id: conversation_id,
                 owner: self(),
                 max_size: 1
               )

      assert :ok =
               Handbean.PubSub.Session.attach_run(conversation_id, self(), queue,
                 run_id: "terminal-draft-run"
               )

      assert :ok =
               Handbean.Agent.CandidateQueue.enqueue(queue, "occupied",
                 message_id: "occupied",
                 deliver_as: :follow_up
               )

      path = "/w/#{workspace["id"]}/c/#{conversation_id}"
      {:ok, view, _html} = live(conn, path)

      assert Enum.any?(
               :sys.get_state(view.pid).socket.assigns.timeline,
               &(&1["id"] == request_id)
             )

      :sys.replace_state(view.pid, fn %{socket: socket} = state ->
        %{state | socket: Phoenix.Component.assign(socket, :selected_model, "missing/model")}
      end)

      previous = Application.get_env(:handbean, :conversation_transcript_store)

      Application.put_env(
        :handbean,
        :conversation_transcript_store,
        RefusingDeleteTranscriptStore
      )

      try do
        render_patch(view, path)
        blocked = :sys.get_state(view.pid).socket.assigns
        assert blocked.composer_error =~ "cleanup pending"
        assert blocked.pending_new_conversation_message.request_id == request_id
        refute blocked.input_value == "restore terminal failure"
        assert {:ok, [_pending]} = Handbean.ConversationTranscriptStore.list(conversation_id)
      after
        if previous,
          do: Application.put_env(:handbean, :conversation_transcript_store, previous),
          else: Application.delete_env(:handbean, :conversation_transcript_store)
      end

      render_patch(view, path)
      assigns = :sys.get_state(view.pid).socket.assigns

      assert assigns.composer_error =~ "Message not delivered"
      assert assigns.input_value == "restore terminal failure"
      assert assigns.pending_new_conversation_message == nil
      refute Enum.any?(assigns.timeline, &(&1["id"] == request_id))
      assert {:ok, []} = Handbean.ConversationTranscriptStore.list(conversation_id)
    end

    test "mobile current conversation menu pins and renames the selected conversation", %{
      conn: conn
    } do
      isolate_conversation_home!()
      {:ok, conv} = Handbean.ConversationStore.create_free(title: "Mobile notes")
      {:ok, view, _html} = live(conn, "/c/#{conv["id"]}")
      menu = "#conversation-menu-mobile-free-#{conv["id"]}"

      view |> element(menu) |> render_click()
      view |> element("#conversation-action-pin-mobile-free-#{conv["id"]}") |> render_click()
      {:ok, pinned} = Handbean.ConversationStore.get_metadata(conv["id"])
      assert is_binary(pinned["pinned_at"])

      view |> element(menu) |> render_click()
      assert has_element?(view, "#conversation-action-pin-mobile-free-#{conv["id"]}", "Unpin")
      view |> element("#conversation-action-rename-mobile-free-#{conv["id"]}") |> render_click()
      view |> form("#rename-conversation-dialog", %{title: "Mobile renamed"}) |> render_submit()
      {:ok, renamed} = Handbean.ConversationStore.get_metadata(conv["id"])
      assert renamed["title"] == "Mobile renamed"
    end

    test "free chats can be renamed, archived, and restored", %{conn: conn} do
      isolate_conversation_home!()
      {:ok, conv} = Handbean.ConversationStore.create_free(title: "Free notes")

      {:ok, view, _html} = live(conn, "/c/#{conv["id"]}")

      assert has_element?(view, "#conversation-menu-free-#{conv["id"]}")
      view |> element("#conversation-menu-free-#{conv["id"]}") |> render_click()
      assert has_element?(view, "#conversation-action-rename-free-#{conv["id"]}", "Rename")
      assert has_element?(view, "#conversation-action-archive-free-#{conv["id"]}", "Archive")

      view |> element("#conversation-action-rename-free-#{conv["id"]}") |> render_click()
      assert has_element?(view, "#rename-conversation-dialog")

      view
      |> form("#rename-conversation-dialog", %{title: "Renamed free"})
      |> render_submit()

      assert has_element?(view, "#free-conversation-#{conv["id"]}", "Renamed free")
      {:ok, renamed} = Handbean.ConversationStore.get_metadata(conv["id"])
      assert renamed["title"] == "Renamed free"
      assert renamed["title_source"] == "manual"

      view |> element("#conversation-menu-free-#{conv["id"]}") |> render_click()
      view |> element("#conversation-action-archive-free-#{conv["id"]}") |> render_click()

      refute has_element?(view, "#free-conversation-#{conv["id"]}")
      {:ok, archived} = Handbean.ConversationStore.get_metadata(conv["id"])
      assert is_binary(archived["archived_at"])

      view |> element("button.workspace-header[phx-click='toggle_archive']") |> render_click()

      assert has_element?(
               view,
               "button[phx-click='unarchive_conversation'][phx-value-id='#{conv["id"]}']"
             )

      view
      |> element("button[phx-click='unarchive_conversation'][phx-value-id='#{conv["id"]}']")
      |> render_click()

      assert has_element?(view, "#free-conversation-#{conv["id"]}", "Renamed free")
    end

    test "free chats can be deleted after confirmation and switch to a remaining chat", %{
      conn: conn
    } do
      isolate_conversation_home!()
      {:ok, doomed} = Handbean.ConversationStore.create_free(title: "Delete me")
      {:ok, kept} = Handbean.ConversationStore.create_free(title: "Keep me")

      {:ok, view, _html} = live(conn, "/c/#{doomed["id"]}")

      view |> element("#conversation-menu-free-#{doomed["id"]}") |> render_click()

      view
      |> element("#conversation-action-delete-free-#{doomed["id"]}")
      |> render_click()

      assert has_element?(view, "#delete-conversation-dialog")
      assert has_element?(view, "#confirm-delete-conversation")

      view |> element("#confirm-delete-conversation") |> render_click()

      assert_patch(view, "/c/#{kept["id"]}")
      refute has_element?(view, "#free-conversation-#{doomed["id"]}")
      refute Handbean.ConversationStore.exists?(doomed["id"])

      assert %Handbean.Storage.Conversation{status: "pending_delete"} =
               Handbean.Repo.get(Handbean.Storage.Conversation, doomed["id"])
    end

    test "mobile conversation info exposes the same confirmed delete flow", %{conn: conn} do
      isolate_conversation_home!()
      {:ok, conversation} = Handbean.ConversationStore.create_free(title: "Mobile delete")
      {:ok, view, _html} = live(conn, "/c/#{conversation["id"]}")

      view
      |> element("button[phx-click='open_sheet'][phx-value-type='workspace']")
      |> render_click()

      assert has_element?(view, "#workspace-sheet #mobile-delete-conversation")
      view |> element("#mobile-delete-conversation") |> render_click()
      assert has_element?(view, "#delete-conversation-dialog")
    end
  end

  defp assert_eventually(assertion, attempts \\ 100)
  defp assert_eventually(assertion, 0), do: assertion.()

  defp assert_eventually(assertion, attempts) do
    assertion.()
  rescue
    ExUnit.AssertionError ->
      receive do
      after
        10 -> assert_eventually(assertion, attempts - 1)
      end
  end
end
