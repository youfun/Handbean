defmodule HandbeanWeb.WorkspaceLive.MountAndInputTest do
  use HandbeanWeb.WorkspaceLiveCase

  describe "mount" do
    test "renders workspace with correct page_title", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Handbean — Workspace"
      assert html =~ "projects-panel-title"
      assert html =~ "专案" or html =~ "Projects"
    end

    test "renders three-column layout regions", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "id=\"activity-bar\""
      assert html =~ "id=\"workspace-panel\""
      assert html =~ "id=\"ai-panel\""
    end

    test "renders status bar with tokens and session id", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "id=\"status-bar\""
      assert html =~ "id=\"status-model\""
      assert html =~ "id=\"status-active-model\""
      refute html =~ "href=\"?locale="
      assert html =~ "Tokens:"
      assert html =~ "id=\"status-input-tokens\""
      assert html =~ "id=\"status-output-tokens\""
      assert html =~ "id=\"status-label\""
      assert html =~ "idle"
      assert html =~ "sid:"
    end

    test "loads persisted token usage for an existing conversation", %{conn: conn} do
      {:ok, conversation} = Handbean.ConversationStore.create("default", title: "Token Stats")

      :ok =
        Handbean.ConversationStore.add_token_usage(conversation["id"], %{
          input_tokens: 17,
          output_tokens: 23
        })

      {:ok, view, _html} = live(conn, "/w/default/c/#{conversation["id"]}")

      assert has_element?(view, "#status-input-tokens", "17")
      assert has_element?(view, "#status-output-tokens", "23")
    end

    test "does not select a conversation owned by another workspace", %{conn: conn} do
      {:ok, foreign_conversation} =
        Handbean.ConversationStore.create("another-workspace", title: "Foreign")

      {:ok, _view, html} = live(conn, "/w/default/c/#{foreign_conversation["id"]}")

      refute html =~ ~s(data-session-id="#{foreign_conversation["id"]}")
    end

    test "does not render archived conversations in the sidebar", %{conn: conn} do
      {:ok, conversation} =
        Handbean.ConversationStore.create("default", title: "Archived conversation")

      {:ok, _archived} = Handbean.ConversationStore.archive(conversation["id"])

      {:ok, _view, html} = live(conn, "/")

      refute html =~ ~s(data-conversation-id="#{conversation["id"]}")
    end

    test "static mount shows loading state and connected mount fills the sidebar", %{conn: conn} do
      {:ok, conversation} =
        Handbean.ConversationStore.create("default",
          title: "Loaded asynchronously",
          timeline: [%{"id" => "message", "role" => "user", "content" => "hello"}]
        )

      static_html = conn |> get("/") |> html_response(200)
      assert static_html =~ ~s(id="conversation-list-loading")
      refute static_html =~ "Loaded asynchronously"

      {:ok, view, _html} = live(recycle(conn), "/")
      rendered = render_async(view, 5_000)

      assert rendered =~ "Loaded asynchronously"
      assert rendered =~ ~s(data-conversation-id="#{conversation["id"]}")
      refute rendered =~ ~s(id="conversation-list-loading")
      refute rendered =~ ~s(id="conversation-list-refreshing")
    end

    test "sidebar More reveals the next conversation batch", %{conn: conn} do
      for index <- 1..12 do
        {:ok, _conversation} =
          Handbean.ConversationStore.create("default", title: "History #{index}")
      end

      {:ok, view, _html} = live(conn, "/")
      render_async(view, 5_000)

      assert has_element?(view, "#workspace-more-default")

      assert view
             |> render()
             |> Floki.parse_document!()
             |> Floki.find("#workspace-conversations-default > .conversation-row")
             |> length() == 10

      view
      |> element("#workspace-more-default")
      |> render_click()

      refute has_element?(view, "#workspace-more-default")

      assert view
             |> render()
             |> Floki.parse_document!()
             |> Floki.find("#workspace-conversations-default > .conversation-row")
             |> length() == 12
    end

    test "stale sidebar results and refresh failures preserve newer rows" do
      current = %{"id" => "current", "title" => "Current", "workspace_id" => "default"}
      stale = %{"id" => "stale", "title" => "Stale", "workspace_id" => "default"}

      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          conversation_list_boot: nil,
          conversation_list_error: nil,
          conversation_list_loaded: true,
          conversation_list_loading: true,
          conversation_list_revision: 2,
          conversation_list_task_revision: 1,
          conversations_by_workspace: %{"default" => [current], free: []},
          workspaces: [%{"id" => "default", "path" => System.tmp_dir!()}]
        }
      }

      assert {:noreply, refreshed} =
               HandbeanWeb.WorkspaceLive.handle_async(
                 :conversation_list,
                 {:ok, {1, {:ok, %{"default" => [stale], free: []}}}},
                 socket
               )

      assert refreshed.assigns.conversation_list_revision == 3
      assert refreshed.assigns.conversation_list_task_revision == 3
      assert refreshed.assigns.conversations_by_workspace["default"] == [current]

      assert {:noreply, failed} =
               HandbeanWeb.WorkspaceLive.handle_async(
                 :conversation_list,
                 {:exit, :index_unavailable},
                 refreshed
               )

      assert failed.assigns.conversations_by_workspace["default"] == [current]
      assert failed.assigns.conversation_list_loaded
      refute failed.assigns.conversation_list_loading
      assert failed.assigns.conversation_list_error
    end

    test "stale sidebar task exits trigger a fresh query without showing an error" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          conversation_list_error: nil,
          conversation_list_loaded: true,
          conversation_list_loading: true,
          conversation_list_revision: 2,
          conversation_list_task_revision: 1,
          conversations_by_workspace: %{"default" => [], free: []},
          workspaces: [%{"id" => "default", "path" => System.tmp_dir!()}]
        }
      }

      assert {:noreply, refreshed} =
               HandbeanWeb.WorkspaceLive.handle_async(
                 :conversation_list,
                 {:exit, :index_unavailable},
                 socket
               )

      assert refreshed.assigns.conversation_list_revision == 3
      assert refreshed.assigns.conversation_list_task_revision == 3
      assert refreshed.assigns.conversation_list_loading
      refute refreshed.assigns.conversation_list_error
    end

    test "renders AI input area with input box and send button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "id=\"ai-input\""
      assert html =~ "id=\"send-button\""
      assert html =~ "id=\"ai-input-area\""
      refute html =~ "id=\"speech-input-button\""
    end

    test "speech activity follows transcription independently of an agent run", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      assigns = :sys.get_state(view.pid).socket.assigns

      for running <- [false, true], speech_state <- [:disabled, :ready, :transcribing] do
        html =
          render_component(
            &HandbeanWeb.WorkspaceLive.ChatComposerComponents.composer/1,
            Map.merge(assigns, %{running: running, speech_state: speech_state})
          )

        assert html
               |> Floki.parse_document!()
               |> Floki.find("#composer-activity")
               |> Floki.attribute("data-active") == [to_string(speech_state == :transcribing)]
      end
    end

    test "ai input textarea does not render leading whitespace around the value", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ ~r/<textarea[^>]*id=\"ai-input\"[^>]*><\/textarea>/
      refute html =~ ~r/<textarea[^>]*id=\"ai-input\"[^>]*>\s+\n\s*<\/textarea>/
    end

    test "model picker distinguishes stored variants that share a display name" do
      models = [
        %{id: "cursor/composer-2.5", model_id: "composer-2.5", name: "Composer 2.5"},
        %{id: "cursor/composer-2.5-fast", model_id: "composer-2.5-fast", name: "Composer 2.5"},
        %{
          id: "cursor/grok-4.7-high-fast",
          model_id: "grok-4.7-high-fast",
          name: "Grok 4.7 High Fast"
        }
      ]

      assert HandbeanWeb.WorkspaceLive.model_option_label(Enum.at(models, 0), models) ==
               "Composer 2.5"

      assert HandbeanWeb.WorkspaceLive.model_option_label(Enum.at(models, 1), models) ==
               "Composer 2.5 Fast"

      assert HandbeanWeb.WorkspaceLive.model_option_label(Enum.at(models, 2), models) ==
               "Grok 4.7 High Fast"
    end

    test "renders empty state when no messages are present", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "id=\"no-messages\""
      assert html =~ "No messages yet"
    end

    test "renders the workspace file tree instead of an empty editor placeholder", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, ".workspace-file-tree[role='tree']")
      refute has_element?(view, "#editor-content")
    end

    test "diff view is hidden initially", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      refute html =~ "id=\"diff-view\""
      refute html =~ "file-change-diff"
    end

    test "workspace panel starts in the Files view", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, ".workspace-panel-tab.active", "Files")
      refute has_element?(view, "#terminal-panel")
    end
  end

  describe "input interaction" do
    test "update_input event updates the input_value assign", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      _html = render_keyup(view, "update_input", %{"value" => "hello world"})

      assert element(view, "textarea#ai-input") |> render() =~ "hello world"
    end

    test "speech transcription appends to the current draft without submitting" do
      request = %{id: "speech-1", conversation_id: "conversation-1", revision: 3}

      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          available_skills: [],
          composer_error: nil,
          current_conversation_id: "conversation-1",
          input_value: "检查",
          skill_suggestions: [],
          speech_request: request,
          speech_revision: 3,
          speech_state: :processing
        }
      }

      assert {:noreply, updated} =
               HandbeanWeb.WorkspaceLive.handle_async(
                 {:speech_transcription, "speech-1"},
                 {:ok, {request, {:ok, "这个文件"}}},
                 socket
               )

      assert updated.assigns.input_value == "检查 这个文件"
      assert updated.assigns.speech_request == nil
      assert updated.assigns.speech_state == :ready
    end

    test "speech transcription drops a stale composer generation" do
      request = %{id: "speech-stale", conversation_id: "conversation-1", revision: 2}

      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          available_skills: [],
          current_conversation_id: "conversation-1",
          input_value: "new draft",
          speech_request: nil,
          speech_revision: 3,
          speech_state: :ready
        }
      }

      assert {:noreply, unchanged} =
               HandbeanWeb.WorkspaceLive.handle_async(
                 {:speech_transcription, "speech-stale"},
                 {:ok, {request, {:ok, "old transcription"}}},
                 socket
               )

      assert unchanged.assigns.input_value == "new draft"
      assert unchanged.assigns.speech_request == nil
    end

    test "disabling speech invalidates the active composer generation" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          speech_available?: true,
          speech_request: %{id: "speech-active"},
          speech_revision: 4,
          speech_state: :processing,
          uploads: %{}
        }
      }

      assert {:noreply, updated} =
               HandbeanWeb.WorkspaceLive.handle_info({:speech_enabled, false}, socket)

      refute updated.assigns.speech_available?
      assert updated.assigns.speech_request == nil
      assert updated.assigns.speech_revision == 5
      assert updated.assigns.speech_state == :disabled
    end

    test "speech upload is consumed without transcription while voice input is disabled", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/")

      upload =
        file_input(view, "#composer", :speech_audio, [
          %{
            name: "disabled-voice.pcm",
            type: "application/octet-stream",
            content: :binary.copy(<<0, 0, 0, 0>>, 4_800)
          }
        ])

      render_upload(upload, "disabled-voice.pcm")

      assert :sys.get_state(view.pid).socket.assigns.uploads.speech_audio.entries == []
      refute has_element?(view, "#speech-input-button")
    end

    test "empty message does not add to list on send (whitespace only)", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view
      |> element("form")
      |> render_submit(%{"message" => "   "})

      # No new user message with whitespace-only content should appear
      refute render(view) =~ ~s(class="msg-bubble msg-user")
    end

    test "empty string does not add to list on send", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view
      |> element("form")
      |> render_submit(%{"message" => ""})

      refute render(view) =~ ~s(class="msg-bubble msg-user")
    end
  end

  describe "auto title sidebar" do
    test "a generated title replaces New chat without a reload", %{conn: conn} do
      isolate_conversation_home!()

      {:ok, conversation} =
        Handbean.ConversationStore.create("default",
          id: "conv-title-delay",
          title: "New chat",
          title_source: "manual",
          timeline: [
            %{
              "id" => "title-user-1",
              "content_type" => "user_msg",
              "role" => "user",
              "content" => "模型列表怎么不一致"
            }
          ]
        )

      {:ok, view, html} = live(conn, "/")
      assert html =~ "New chat"

      send(view.pid, {:conversation_title_ready, conversation["id"], "模型列表展示不一致"})

      assert has_element?(view, "#conversation-conv-title-delay", "模型列表展示不一致")
      refute has_element?(view, "#conversation-conv-title-delay", "New chat")
    end

    test "a provisional title replaces New chat before the model returns", %{conn: conn} do
      isolate_conversation_home!()

      {:ok, conversation} =
        Handbean.ConversationStore.create("default",
          id: "conv-title-now",
          title: "New chat",
          title_source: "manual"
        )

      {:ok, view, html} = live(conn, "/")
      assert html =~ "New chat"

      assert {:ok, "模型列表怎么不一致"} =
               Handbean.ConversationTitleGenerator.publish_provisional(
                 conversation["id"],
                 "模型列表怎么不一致"
               )

      assert has_element?(view, "#conversation-conv-title-now", "模型列表怎么不一致")
      refute has_element?(view, "#conversation-conv-title-now", "New chat")
    end
  end
end
