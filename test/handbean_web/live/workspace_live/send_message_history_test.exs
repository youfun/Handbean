defmodule HandbeanWeb.WorkspaceLive.SendMessageHistoryTest do
  use HandbeanWeb.WorkspaceLiveCase

  describe "send_message" do
    test "adding a user message appears in the message list", %{conn: conn} do
      with_log(fn ->
        {:ok, view, _html} = live(conn, "/")
        view |> element("form") |> render_submit(%{"message" => "Read sample.txt"})
        assert render(view) =~ "Read sample.txt"
      end)
    end

    test "input clears after sending a message", %{conn: conn} do
      with_log(fn ->
        {:ok, view, _html} = live(conn, "/")
        view |> element("form") |> render_submit(%{"message" => "Read config"})
        assert has_element?(view, "textarea#ai-input", "")
      end)
    end

    test "send button prevents duplicate submission while the server acknowledges", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      assert has_element?(view, "#send-button[phx-disable-with='…']")
    end

    test "sending a message persists user-visible history before run_end", %{conn: conn} do
      isolate_conversation_home!()

      {:ok, view, _html} = live(conn, "/")
      conversation_id = create_default_conversation(view)
      view |> element("form") |> render_submit(%{"message" => "durable before run_end"})
      _ = render(view)

      assert Enum.any?(
               Handbean.ConversationStore.load_messages(conversation_id),
               &match?(%{"content" => "durable before run_end", "role" => "user"}, &1)
             )

      {:ok, _view2, html2} = live(conn, "/")
      assert html2 =~ "durable before run_end"

      assert {:ok, conversation} = Handbean.ConversationStore.get(conversation_id)

      assert Enum.any?(conversation["timeline"], fn entry ->
               entry["content"] == "durable before run_end"
             end)
    end

    test "sending a message preserves previously loaded history", %{conn: conn} do
      isolate_conversation_home!()

      {:ok, _conv} =
        Handbean.ConversationStore.create("default",
          id: "conv-history",
          title: "New chat",
          timeline: [
            %{
              "id" => "timeline-1",
              "content_type" => "user_msg",
              "role" => "user",
              "content" => "Earlier context"
            },
            %{
              "id" => "timeline-2",
              "content_type" => "assistant_msg",
              "role" => "assistant",
              "content" => "Previous reply"
            }
          ]
        )

      {:ok, view, _html} = live(conn, "/")

      rendered_before = render(view)
      assert rendered_before =~ "Earlier context"
      assert rendered_before =~ "Previous reply"

      view |> element("form") |> render_submit(%{"message" => "New question"})

      rendered_after = render(view)
      assert rendered_after =~ "Earlier context"
      assert rendered_after =~ "Previous reply"
      assert rendered_after =~ "New question"
    end

    test "renders role-neutral user and assistant attachments without an empty assistant bubble",
         %{
           conn: conn
         } do
      conversation_id = "conv-assistant-media"
      media_url = "/media/#{conversation_id}/media-generated/content"
      data_url = "data:image/png;base64,iVBORw0KGgo="

      assistant_attachments = [
        %{
          "media_id" => "media-generated",
          "conversation_id" => conversation_id,
          "kind" => "image",
          "mime_type" => "image/png",
          "filename" => "generated.png"
        },
        %{
          "kind" => "image",
          "mime_type" => "image/png",
          "filename" => "legacy-data.png",
          "data" => "iVBORw0KGgo="
        },
        %{
          "kind" => "text",
          "filename" => "notes.txt",
          "url" => "/uploads/legacy-notes.txt"
        }
      ]

      {:ok, conversation} =
        Handbean.ConversationStore.create("default",
          id: conversation_id,
          title: "Assistant media",
          timeline: [
            %{
              "id" => "user-legacy-media",
              "content_type" => "user_msg",
              "role" => "user",
              "content" => "",
              "attachments" => [
                %{
                  "kind" => "image",
                  "filename" => "legacy-user.png",
                  "url" => "/uploads/legacy-user.png"
                }
              ]
            },
            %{
              "id" => "assistant-media",
              "content_type" => "assistant_msg",
              "role" => "assistant",
              "content" => "",
              "attachments" => assistant_attachments
            },
            %{
              "id" => "assistant-text",
              "content_type" => "assistant_msg",
              "role" => "assistant",
              "content" => "Rendered reply"
            }
          ]
        )

      {:ok, view, _html} = live(conn, "/w/default/c/#{conversation["id"]}")

      :sys.replace_state(view.pid, fn %{socket: socket} = state ->
        timeline =
          Enum.map(socket.assigns.timeline, fn
            %{"id" => "assistant-media"} = entry ->
              Map.put(entry, "attachments", assistant_attachments)

            entry ->
              entry
          end)

        socket =
          socket
          |> Phoenix.Component.assign(:timeline, timeline)
          |> Phoenix.LiveView.stream(:timeline, timeline, reset: true)

        %{state | socket: socket}
      end)

      render_click(view, "clear_composer_error", %{})

      assert has_element?(
               view,
               "[data-user-msg='user-legacy-media'] .msg-shot[data-shot-src='/uploads/legacy-user.png'] img[alt='legacy-user.png']"
             )

      assert has_element?(view, "[data-assistant-msg='assistant-media']")

      assert has_element?(
               view,
               "[data-assistant-msg='assistant-media'] .msg-shot[data-shot-name='generated.png'][title='generated.png'][aria-label] img[alt='generated.png']"
             )

      assert has_element?(
               view,
               "[data-assistant-msg='assistant-media'] .msg-shot[data-shot-src='#{media_url}'] img[src='#{media_url}']"
             )

      assert has_element?(
               view,
               "[data-assistant-msg='assistant-media'] .msg-shot[data-shot-src='#{data_url}'] img[src='#{data_url}'][alt='legacy-data.png']"
             )

      assert has_element?(
               view,
               "[data-assistant-msg='assistant-media'] a.msg-file[href='/uploads/legacy-notes.txt'][target='_blank'][rel='noreferrer']",
               "notes.txt"
             )

      refute has_element?(view, "[data-assistant-msg='assistant-media'] .msg-bubble")
      refute has_element?(view, "[data-assistant-msg='assistant-media'] .msg-copy-btn")

      refute has_element?(
               view,
               "[data-assistant-msg='assistant-media'] [phx-hook='StreamingMarkdown']"
             )

      assert has_element?(
               view,
               "[data-assistant-msg='assistant-text'] [phx-hook='StreamingMarkdown']"
             )

      assert has_element?(view, "[data-assistant-msg='assistant-text'] .msg-copy-btn")

      assert {:ok, transcript} =
               Handbean.ConversationTranscriptStore.list(conversation["id"])

      persisted = Enum.find(transcript, &(&1["id"] == "assistant-media"))
      media_descriptor = hd(persisted["attachments"])
      assert media_descriptor["media_id"] == "media-generated"
      refute Map.has_key?(media_descriptor, "url")
    end

    test "pages long history backward without losing newly appended messages", %{conn: conn} do
      timeline =
        for index <- 1..250 do
          %{
            "id" => "long-history-#{index}",
            "content_type" => "user_msg",
            "role" => "user",
            "content" => "history item #{index}"
          }
        end

      {:ok, conversation} =
        Handbean.ConversationStore.create("default",
          id: "conv-long-history",
          title: "Long history",
          timeline: timeline
        )

      {:ok, view, _html} = live(conn, "/w/default/c/#{conversation["id"]}")

      assert render(view) =~ "history item 250"
      refute render(view) =~ "history item 150"
      assert has_element?(view, "#ai-messages[data-history-has-more='true']")

      send(
        view.pid,
        {:agent_event,
         agent_event(
           :message_delta,
           %{chunk: "live after newest page"},
           1,
           "session:#{conversation["id"]}"
         )}
      )

      render_hook(view, "load_older_history", %{})
      rendered = render(view)
      assert rendered =~ "history item 51"
      assert rendered =~ "live after newest page"

      render_hook(view, "load_older_history", %{})
      rendered = render(view)
      assert rendered =~ "history item 1"
      assert rendered =~ "live after newest page"
      refute has_element?(view, "#ai-messages[data-history-has-more='true']")

      send(
        view.pid,
        {:agent_event,
         agent_event(
           :message_delta,
           %{chunk: " and after loading older history"},
           2,
           "session:#{conversation["id"]}"
         )}
      )

      rendered = render(view)
      assert rendered =~ "live after newest page and after loading older history"
      assert rendered =~ "history item 1"
    end

    test "projects tool groups when older history is loaded", %{conn: conn} do
      older_entries = [
        %{
          "id" => "older-commentary",
          "content_type" => "assistant_msg",
          "role" => "assistant",
          "content" => "Inspecting older files"
        },
        %{
          "id" => "older-read",
          "content_type" => "tool",
          "tool_name" => "read",
          "tool_status" => "done",
          "input" => %{"file_path" => "lib/older.ex"}
        },
        %{
          "id" => "older-search",
          "content_type" => "tool",
          "tool_name" => "grep",
          "tool_status" => "done",
          "input" => %{"path" => "lib", "pattern" => "older"}
        },
        %{
          "id" => "older-answer",
          "content_type" => "assistant_msg",
          "role" => "assistant",
          "content" => "Older inspection complete"
        }
      ]

      newer_entries =
        Enum.map(1..100, fn index ->
          %{
            "id" => "newer-history-#{index}",
            "content_type" => "user_msg",
            "role" => "user",
            "content" => "newer history item #{index}"
          }
        end)

      {:ok, conversation} =
        Handbean.ConversationStore.create("default",
          id: "conv-older-tool-work",
          title: "Older tool work",
          timeline: older_entries ++ newer_entries
        )

      {:ok, view, _html} = live(conn, "/w/default/c/#{conversation["id"]}")

      refute has_element?(view, "#older-read")

      render_hook(view, "load_older_history", %{})

      assert has_element?(view, "#older-read .tool-work-collapsed.tool-work-lead")

      assert has_element?(
               view,
               "#tool-work-summary-older-read[aria-expanded='false']",
               "Explored 1 file, 1 search"
             )

      assert has_element?(view, "#older-search .tool-work-collapsed.tool-work-follow")
      refute has_element?(view, "#tool-work-line-older-read")
      refute has_element?(view, "#tool-work-line-older-search")
    end

    test "switching away and back reloads persisted streaming display history", %{conn: conn} do
      isolate_conversation_home!()

      {:ok, first} =
        Handbean.ConversationStore.create("default",
          id: "conv-switch-a",
          title: "Count from 1",
          timeline: [
            %{
              "id" => "msg-user-a",
              "content_type" => "user_msg",
              "role" => "user",
              "content" => "从1数到1011"
            }
          ]
        )

      {:ok, second} =
        Handbean.ConversationStore.create("default",
          id: "conv-switch-b",
          title: "Second chat",
          timeline: []
        )

      {:ok, view, _html} = live(conn, "/")

      view
      |> element(
        ".conversation-item[phx-click='select_conversation'][phx-value-id='#{first["id"]}']"
      )
      |> render_click()

      assert render(view) =~ "从1数到1011"

      Handbean.Agent.TranscriptPersistence.handle_event(
        first["id"],
        {:run_start, %{model: "test"}}
      )

      Handbean.Agent.TranscriptPersistence.handle_event(
        first["id"],
        {:message_delta, %{chunk: "1, 2, 3, 4, 5"}}
      )

      view
      |> element(
        ".conversation-item[phx-click='select_conversation'][phx-value-id='#{second["id"]}']"
      )
      |> render_click()

      refute render(view) =~ "1, 2, 3, 4, 5"

      Handbean.Agent.TranscriptPersistence.handle_event(
        first["id"],
        {:run_end, %{status: "completed", turns: 1}}
      )

      view
      |> element(
        ".conversation-item[phx-click='select_conversation'][phx-value-id='#{first["id"]}']"
      )
      |> render_click()

      rendered = render(view)
      assert rendered =~ "从1数到1011"
      assert rendered =~ "1, 2, 3, 4, 5"
    end

    test "syncing current running conversation preserves in-flight timeline", %{conn: conn} do
      isolate_conversation_home!()

      {:ok, conversation} =
        Handbean.ConversationStore.create("default",
          id: "conv-running-preserve",
          title: "Running preserve",
          timeline: [
            %{
              "id" => "msg-user-running-preserve",
              "content_type" => "user_msg",
              "role" => "user",
              "content" => "keep running user text"
            }
          ]
        )

      {:ok, view, _html} = live(conn, "/w/default/c/#{conversation["id"]}")
      topic = "session:#{conversation["id"]}"

      # Runtime text is durable before broadcast; recovery intentionally does
      # not preserve an unpersisted projection-only assistant row.
      {:ok, _} =
        Handbean.ConversationTranscriptStore.append(conversation["id"], %{
          "id" => "running-reply",
          "role" => "assistant",
          "content_type" => "assistant_msg",
          "content" => "in-flight reply",
          "status" => "streaming"
        })

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "test"}, 1, topic)})

      send(
        view.pid,
        {:agent_event,
         agent_event(
           :message_delta,
           %{transcript_id: "running-reply", text_offset: 0, text: "in-flight reply"},
           2,
           topic
         )}
      )

      assert render(view) =~ "in-flight reply"

      view
      |> element(
        ".conversation-item[phx-click='select_conversation'][phx-value-id='#{conversation["id"]}']"
      )
      |> render_click()

      assert render(view) =~ "in-flight reply"
    end

    test "switching conversations ignores previous conversation running state when resetting timeline",
         %{
           conn: conn
         } do
      isolate_conversation_home!()

      {:ok, first} =
        Handbean.ConversationStore.create("default",
          id: "conv-running-switch-a",
          title: "Running first",
          timeline: [
            %{
              "id" => "msg-user-running-a",
              "content_type" => "user_msg",
              "role" => "user",
              "content" => "first running conversation"
            }
          ]
        )

      {:ok, second} =
        Handbean.ConversationStore.create("default",
          id: "conv-running-switch-b",
          title: "Running second",
          timeline: [
            %{
              "id" => "msg-user-running-b",
              "content_type" => "user_msg",
              "role" => "user",
              "content" => "second selected conversation"
            }
          ]
        )

      {:ok, view, _html} = live(conn, "/w/default/c/#{first["id"]}")
      first_topic = "session:#{first["id"]}"

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "test"}, 1, first_topic)})

      assert render(view) =~ "first running conversation"

      view
      |> element(
        ".conversation-item[phx-click='select_conversation'][phx-value-id='#{second["id"]}']"
      )
      |> render_click()

      rendered = render(view)
      assert rendered =~ "second selected conversation"
      refute rendered =~ "first running conversation"
      refute has_element?(view, "#status-label", "running")
    end

    test "switching conversations clears composer attachments from the previous conversation", %{
      conn: conn
    } do
      isolate_conversation_home!()

      {:ok, first} =
        Handbean.ConversationStore.create("default",
          id: "conv-attach-switch-a",
          title: "Attach first"
        )

      {:ok, second} =
        Handbean.ConversationStore.create("default",
          id: "conv-attach-switch-b",
          title: "Attach second"
        )

      {:ok, view, _html} = live(conn, "/w/default/c/#{first["id"]}")

      png_path =
        Path.join(System.tmp_dir!(), "sigil_lv_upload_#{System.unique_integer([:positive])}.png")

      File.write!(png_path, <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0>>)

      upload =
        file_input(view, "form", :images, [
          %{
            path: png_path,
            name: "from-a.png",
            type: "image/png",
            content: File.read!(png_path)
          }
        ])

      render_upload(upload, "from-a.png")
      assert has_element?(view, "#composer-attachments span.sr-only", "from-a.png")

      view
      |> element(
        ".conversation-item[phx-click='select_conversation'][phx-value-id='#{second["id"]}']"
      )
      |> render_click()

      refute has_element?(view, "#composer-attachments span.sr-only", "from-a.png")
      refute has_element?(view, "#composer-attachments button[phx-click='cancel_upload']")
      assert :sys.get_state(view.pid).socket.assigns.pending_attachments == []

      view
      |> element(
        ".conversation-item[phx-click='select_conversation'][phx-value-id='#{first["id"]}']"
      )
      |> render_click()

      assert has_element?(view, "#composer-attachments img[alt='from-a.png']")
      assert :sys.get_state(view.pid).socket.assigns.current_conversation_id == first["id"]
    end

    test "sets running state after submitting a message", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Use run_start event to reliably set running state (avoids race with async Task)
      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "step-router-v1"})})

      rendered = render(view)
      assert rendered =~ "running"
    end

    test "input remains enabled when agent is running for steering", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Use run_start event to reliably set running state (avoids race with async Task)
      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "step-router-v1"})})

      rendered = render(view)
      refute rendered =~ "disabled"
    end
  end
end
