defmodule HandbeanProbe.HomeScreenNavigationHistoryTest do
  use HandbeanProbe.HomeScreenCase

  alias Handbean.PubSub.AgentEvent
  alias HandbeanProbe.HomeScreenCase.{ProviderFixture, UnavailableHistory}
  alias HandbeanProbe.NativeChat

  test "handoff navigation opens a child conversation and returns to its parent", %{view: view} do
    {:ok, parent} = Handbean.ConversationStore.create("default", title: "Parent")
    {:ok, child} = Handbean.ConversationStore.create("default", title: "Researcher")

    view = info(view, {:tap, {:conversation, parent["id"]}})

    view =
      info(
        view,
        {:tap, {:open_subagent_conversation, child["id"], "researcher"}}
      )

    assert assigns(view).chat.conversation["id"] == child["id"]
    assert assigns(view).conversation_stack == [parent["id"]]

    view = info(view, {:tap, :close_subagent_conversation})
    assert assigns(view).chat.conversation["id"] == parent["id"]
    assert assigns(view).conversation_stack == []
  end

  test "handoff Message action prefills an exact subagent mention", %{view: view} do
    view = info(view, {:tap, {:prefill_subagent_message, "researcher"}})

    assert assigns(view).page == :chat
    assert assigns(view).draft == "@researcher "
  end

  test "native chat and placeholder pages have no web view", %{view: view} do
    # The checked-in Android bridge implements :icon (Mob's tag manifest omits it).
    assert_renderable(view, extra: [:icon, :settings_select, :settings_button])
    refute find(view, :web_view)
    assert find(view, :text_field).props.multiline
    assert find(view, :text_field).props.plain
    assert text(view) =~ gettext("Start a new conversation")

    assert Enum.any?(
             flatten(tree(view)),
             &(&1.type == :icon and &1.props[:name] == "add" and
                 match?({_, {:platform, :begin, :pick_photos}}, &1.props[:on_tap]))
           )

    refute text(view) =~ "{:platform"
    refute text(view) =~ gettext("Not implemented yet")
    view = info(view, {:tap, {:page, :workspace}})

    assert Enum.any?(
             flatten(tree(view)),
             &match?({_, :open_create}, &1.props[:on_tap])
           )

    view = info(view, {:tap, {:page, :settings}})
    assert text(view) =~ gettext("Model / AI")
    assert text(view) =~ gettext("Workspace")
    refute text(view) =~ gettext("Default model")

    refute Enum.any?(
             flatten(tree(view)),
             &(&1.type == :settings_select && &1.props[:id] == "select-reasoning")
           )

    view = info(view, {:tap, {:page, :model_ai}})
    assert text(view) =~ gettext("Default model")
    assert text(view) =~ gettext("Advisor")

    assert Enum.any?(
             flatten(tree(view)),
             &(&1.type == :settings_select && &1.props[:id] == "select-reasoning")
           )

    view = info(view, {:tap, {:reasoning, "medium"}})
    assert assigns(view).models.defaults.reasoning == "medium"
    view = info(view, {:tap, {:page, :models}})
    view = info(view, {:tap, :add_model})
    assert assigns(view).models.editing == nil
    view = info(view, {:tap, :add_provider})
    assert assigns(view).models.editing == :new_provider
    assert_renderable(view, extra: [:icon, :settings_select, :settings_button])
  end

  test "workspaces state is loaded at mount and never nil across navigation", %{
    view: view,
    dir: dir
  } do
    default_id = assigns(view).workspace["id"]
    refute Map.has_key?(assigns(view), :last_composer_intent)

    workspaces = assigns(view).workspaces
    assert %{mode: :list, items: items} = workspaces
    assert Enum.any?(items, &(&1.id == default_id))

    {:ok, conv} = Handbean.ConversationStore.create(default_id, title: "Workspaces fixture")
    view = info(view, {:tap, {:conversation, conv["id"]}})
    assert %{mode: :list} = assigns(view).workspaces

    path_b = Path.join(dir, "workspace_ws_state")
    File.mkdir_p!(path_b)
    {:ok, workspace_b} = Handbean.WorkspaceStore.add(path_b, name: "WS state")

    view = info(view, {:tap, {:workspace, workspace_b["id"]}})
    assert assigns(view).workspace["id"] == workspace_b["id"]
    assert %{mode: :list} = assigns(view).workspaces

    view = info(view, {:tap, {:page, :workspace}})
    assert assigns(view).page == :workspace
    assert Enum.any?(assigns(view).workspaces.items, &(&1.id == workspace_b["id"]))
    assert_renderable(view, extra: [:icon, :settings_select, :settings_button])
    refute Map.has_key?(assigns(view), :last_composer_intent)
  end

  test "older chat pages remain chronological and a sequence gap reloads durable text once", %{
    view: view
  } do
    {:ok, conversation} = Handbean.ConversationStore.create("default", title: "Paged chat")
    id = conversation["id"]

    entries =
      for n <- 1..205,
          do: %{"id" => "history-#{n}", "role" => "user", "content" => "message #{n}"}

    :ok = Handbean.ConversationTranscriptStore.replace_all(id, entries)
    {:ok, _} = Handbean.PubSub.Session.start_or_get(session_id: id)
    on_exit(fn -> Handbean.SessionSupervisor.stop_session(id) end)

    view = info(view, {:tap, {:conversation, id}})
    assert length(assigns(view).chat.entries) == 100
    assert hd(assigns(view).chat.entries)["id"] == "history-106"
    assert assigns(view).chat.history_has_more?
    assert_renderable(view, extra: [:icon, :settings_select, :settings_button])
    timeline = find(view, :scroll, id: "chat-timeline-#{id}")
    assert timeline.props.on_top_reached
    refute find(view, :text, text: gettext("Load older messages"))

    view =
      info(view, {:top_reached, :load_older_history}) |> info({:top_reached, :load_older_history})

    assert Enum.map(assigns(view).chat.entries, & &1["id"]) == Enum.map(entries, & &1["id"])
    refute assigns(view).chat.history_has_more?
    refute Map.has_key?(find(view, :scroll, id: "chat-timeline-#{id}").props, :on_top_reached)

    {:ok, _} =
      Handbean.ConversationTranscriptStore.append(id, %{
        "id" => "reply",
        "role" => "assistant",
        "content_type" => "assistant_msg",
        "content" => "你好 world"
      })

    :ok = Handbean.PubSub.Session.broadcast_event(id, :thinking_delta, %{})

    :ok =
      Handbean.PubSub.Session.broadcast_event(id, :message_delta, %{
        transcript_id: "reply",
        text_offset: 0,
        text: "你好 world"
      })

    snapshot = Handbean.PubSub.Session.snapshot(id)
    event = Enum.max_by(snapshot.events, & &1.seq)
    view = info(view, {:agent_event, event})
    chat = assigns(view).chat
    assert chat.seq == snapshot.last_seq
    assert [%{"content" => "你好 world"}] = Enum.filter(chat.entries, &(&1["id"] == "reply"))
    assert chat.stream == ""
    view = info(view, {:agent_event, event})
    assert assigns(view).chat == chat

    :ok = Handbean.SessionSupervisor.stop_session(id)
    {:ok, _} = Handbean.PubSub.Session.start_or_get(session_id: id, session_store_enabled?: false)
    Handbean.PubSub.Session.broadcast_event(id, :thinking_delta, %{})
    restarted = Handbean.PubSub.Session.snapshot(id)
    event = Enum.max_by(restarted.events, & &1.seq)
    view = info(view, {:agent_event, event})
    assert assigns(view).chat.seq == 1
    assert assigns(view).chat.epoch == restarted.epoch
    assert assigns(view).chat.entries == chat.entries
  end

  test "history failure preserves prefix-recovery checkpoint and never acknowledges an empty load",
       %{
         view: view
       } do
    {:ok, conversation} = Handbean.ConversationStore.create("default")
    id = conversation["id"]
    {:ok, _} = Handbean.PubSub.Session.start_or_get(session_id: id)
    on_exit(fn -> Handbean.SessionSupervisor.stop_session(id) end)

    {:ok, _} =
      Handbean.ConversationTranscriptStore.append(id, %{"id" => "saved", "content" => "keep"})

    Handbean.PubSub.Session.broadcast_event(id, :thinking_delta, %{})
    view = info(view, {:tap, {:conversation, id}})
    chat = assigns(view).chat
    previous_store = Application.get_env(:handbean, :conversation_transcript_store)

    try do
      Application.put_env(:handbean, :conversation_transcript_store, UnavailableHistory)

      event = %{
        AgentEvent.new(
          "session:#{id}",
          :message_delta,
          %{
            transcript_id: "missing-prefix",
            text_offset: 20,
            text: "suffix"
          },
          chat.seq + 1
        )
        | epoch: chat.epoch
      }

      view = info(view, {:agent_event, event})
      assert assigns(view).chat.seq == chat.seq
      assert assigns(view).chat.entries == chat.entries
      fresh = NativeChat.load(conversation)
      assert fresh.seq == 0
      assert fresh.epoch == nil
      assert fresh.transcript_dirty

      assert NativeChat.project(
               %{AgentEvent.new("session:#{id}", :thinking_delta, %{}, 1) | epoch: chat.epoch},
               fresh
             ) == fresh
    after
      if previous_store,
        do: Application.put_env(:handbean, :conversation_transcript_store, previous_store),
        else: Application.delete_env(:handbean, :conversation_transcript_store)
    end
  end

  test "history overlays the unchanged chat and navigation identifies only user messages", %{
    view: view
  } do
    {:ok, c} = Handbean.ConversationStore.create("default", title: "Drawer fixture")

    for {id, role, body} <- [
          {"u1", "user", "first\n question"},
          {"a1", "assistant", "answer"},
          {"u2", "user", "second"}
        ] do
      {:ok, _} =
        Handbean.ConversationTranscriptStore.append(c["id"], %{
          "id" => id,
          "role" => role,
          "content" => body
        })
    end

    view = view |> info({:tap, {:conversation, c["id"]}}) |> info({:change, :draft, "unsent"})
    chat_tree = hd(tree(view).children)
    assert find(view, :scroll, id: "chat-timeline-#{c["id"]}").props.chat_navigation
    markers = Enum.filter(flatten(tree(view)), & &1.props[:nav_user_id])
    assert Enum.map(markers, & &1.props.nav_user_id) == ["u1", "u2"]
    assert hd(markers).props.nav_user_summary == "first question"
    view = info(view, {:tap, {:page, :history}})
    assert tree(view).props.drawer_open
    assert length(tree(view).children) == 2
    assert hd(tree(view).children) == chat_tree
    view = info(view, {:tap, {:page, :chat}})
    refute tree(view).props.drawer_open
    assert assigns(view).draft == "unsent"
    view = view |> info({:tap, {:page, :history}}) |> info({:tap, {:conversation, c["id"]}})
    refute tree(view).props.drawer_open
  end

  test "history and notification restore durable transcript without a LiveView", %{view: view} do
    {:ok, conversation} = Handbean.ConversationStore.create("default", title: "Native history")

    {:ok, _} =
      Handbean.ConversationTranscriptStore.append(conversation["id"], %{
        "id" => "a1",
        "role" => "assistant",
        "content" => "persisted answer"
      })

    view =
      info(
        view,
        {:notification,
         %{"data" => %{"workspace_id" => "default", "conversation_id" => conversation["id"]}}}
      )

    assert assigns(view).page == :chat
    assert text(view) =~ "persisted answer"
    view = info(view, {:tap, {:page, :history}})
    assert find(view, :row, id: "conversation-open-#{conversation["id"]}").props.on_tap

    view =
      info(
        view,
        {:notification, %{data: %{workspace_id: "wrong", conversation_id: conversation["id"]}}}
      )

    assert notice_text(view) =~ gettext("The conversation in the notification is unavailable")
  end

  test "history starts and opens a free chat without a workspace", %{view: view} do
    workspace_id = assigns(view).workspace["id"]
    view = info(view, {:tap, {:page, :history}})
    assert find(view, :icon, id: "{:new_free_chat}")

    view = info(view, {:tap, :new_free_chat})
    assert assigns(view).chat == nil
    assert assigns(view).free_draft
    assert assigns(view).workspace["id"] == workspace_id
    refute text(view) =~ gettext("Files")

    view = view |> info({:change, :draft, "free hello"}) |> info({:tap, :send})
    conversation = assigns(view).chat.conversation
    assert Handbean.ConversationStore.free?(conversation)
    assert conversation["workspace_id"] == nil
    assert assigns(view).workspace["id"] == workspace_id

    id = conversation["id"]
    view = info(view, {:tap, :new_chat})
    assert assigns(view).chat == nil
    refute assigns(view).free_draft

    view = info(view, {:tap, {:page, :history}})
    assert text(view) =~ "free hello"
    view = info(view, {:tap, {:conversation, id}})
    assert assigns(view).chat.conversation["id"] == id
    assert assigns(view).workspace["id"] == workspace_id
    refute text(view) =~ gettext("Files")
    refute text(view) =~ gettext("Conversation not found")
  end

  test "native history confirms cascading archive and switches away from an archived child", %{
    view: view
  } do
    {:ok, fallback} = Handbean.ConversationStore.create("default", title: "Archive fallback")
    {:ok, parent} = Handbean.ConversationStore.create("default", title: "Archive parent")

    {:ok, child} =
      Handbean.ConversationStore.create("default",
        title: "Archive child",
        parent_conversation_id: parent["id"]
      )

    view = info(view, {:tap, {:conversation, child["id"]}})
    view = info(view, {:tap, {:page, :history}})
    view = info(view, {:tap, {:archive_conversation, parent["id"]}})

    assert assigns(view).conversation_menu_id == nil
    assert %{id: id, descendant_count: 1} = assigns(view).archive_conversation
    assert id == parent["id"]
    assert find(view, :sheet, id: "archive-conversation-confirm")

    assert text(view) =~
             ngettext(
               "“%{title}” and its %{count} child thread will move to Archived.",
               "“%{title}” and its %{count} child threads will move to Archived.",
               1,
               title: parent["title"],
               count: 1
             )

    for conversation <- [parent, child] do
      assert {:ok, %{"archived_at" => nil}} =
               Handbean.ConversationStore.get_metadata(conversation["id"])
    end

    view = info(view, {:tap, :cancel_archive_conversation})
    assert assigns(view).archive_conversation == nil
    refute find(view, :sheet, id: "archive-conversation-confirm")

    view = info(view, {:tap, {:archive_conversation, parent["id"]}})
    view = info(view, {:tap, :confirm_archive_conversation})

    assert assigns(view).archive_conversation == nil
    assert assigns(view).page == :chat
    assert assigns(view).chat.conversation["id"] == fallback["id"]

    for conversation <- [parent, child] do
      assert {:ok, %{"archived_at" => archived_at}} =
               Handbean.ConversationStore.get_metadata(conversation["id"])

      assert is_binary(archived_at)
    end
  end

  test "conversation menu copies the conversation ID and closes the menu", %{view: view} do
    on_exit(fn -> Application.delete_env(:handbean_probe, :clipboard_put) end)
    {:ok, c} = Handbean.ConversationStore.create("default", title: "Copy fixture")

    parent = self()

    Application.put_env(:handbean_probe, :clipboard_put, fn text ->
      send(parent, {:copied, text})
    end)

    view = info(view, {:tap, {:page, :history}})
    view = info(view, {:tap, {:toggle_conversation_menu, c["id"]}})
    assert assigns(view).conversation_menu_id == c["id"]

    view = info(view, {:tap, {:copy_conversation_id, c["id"]}})
    assert_receive {:copied, copied}
    assert copied == c["id"]
    assert assigns(view).conversation_menu_id == nil
    assert notice_text(view) =~ gettext("Conversation ID copied")
  end

  test "chat header overflow is conversation actions, not settings", %{view: view} do
    workspace_id = assigns(view).workspace["id"]
    {:ok, c} = Handbean.ConversationStore.create(workspace_id, title: "Header menu")
    view = info(view, {:tap, {:conversation, c["id"]}})

    menu = find(view, :text, id: "chat-conversation-menu")
    assert menu.props.text == "⋯"
    assert menu.props.on_tap
    refute find(view, :icon, name: "more")
    refute find(view, :icon, id: "{:page, :settings}")
    refute text(view) =~ gettext("Settings")

    view = info(view, {:tap, {:toggle_conversation_menu, c["id"]}})
    assert assigns(view).conversation_menu_id == c["id"]
    assert find(view, :column, id: "conversation-menu-panel-#{c["id"]}")
    assert find(view, :box, id: "conversation-menu-dismiss")
    id = c["id"]

    taps =
      tree(view)
      |> flatten()
      |> Enum.map(& &1.props[:on_tap])
      |> Enum.map(fn
        {_, tag} -> tag
        _ -> nil
      end)

    assert {:toggle_pin_conversation, id} in taps
    assert {:rename_conversation, id} in taps
    assert {:copy_conversation_id, id} in taps
    assert {:archive_conversation, id} in taps
    assert :close_conversation_menu in taps
    refute {:page, :settings} in taps

    view = info(view, {:tap, {:toggle_conversation_menu, c["id"]}})
    assert assigns(view).conversation_menu_id == nil
    refute find(view, :column, id: "conversation-menu-panel-#{c["id"]}")

    view = info(view, {:tap, {:toggle_conversation_menu, c["id"]}})
    assert assigns(view).conversation_menu_id == c["id"]
    view = info(view, {:tap, :close_conversation_menu})
    assert assigns(view).conversation_menu_id == nil
    refute find(view, :column, id: "conversation-menu-panel-#{c["id"]}")
  end

  test "workspace chat shows agent changes files tabs on the conversation", %{view: view} do
    workspace_id = assigns(view).workspace["id"]
    {:ok, c} = Handbean.ConversationStore.create(workspace_id, title: "Panel tabs")
    view = info(view, {:tap, {:conversation, c["id"]}})

    assert find(view, :row, id: "chat-panel-tabs")
    assert find(view, :row, id: "chat-tab-agent")
    assert find(view, :row, id: "chat-tab-changes")
    assert find(view, :row, id: "chat-tab-files")
    assert assigns(view).chat_panel == :agent
    assert find(view, :icon, id: "send")

    view = info(view, {:tap, {:chat_panel, :changes}})
    assert assigns(view).chat_panel == :changes
    assert assigns(view).page == :chat
    assert text(view) =~ "No file changes in this conversation."
    refute find(view, :icon, id: "send")

    view = info(view, {:tap, {:chat_panel, :files}})
    assert assigns(view).chat_panel == :files
    assert assigns(view).page == :chat
    refute find(view, :icon, id: "send")

    view = info(view, {:tap, {:chat_panel, :agent}})
    assert assigns(view).chat_panel == :agent
    assert find(view, :icon, id: "send")
  end

  test "free chat has no agent changes files tabs", %{view: view} do
    view = info(view, {:tap, :new_free_chat})
    refute find(view, :row, id: "chat-panel-tabs")
    refute find(view, :row, id: "chat-tab-agent")
  end

  test "app entries live in the history drawer, not the chat header", %{view: view} do
    refute find(view, :icon, id: "{:page, :settings}")
    refute find(view, :icon, id: "{:page, :about}")
    refute text(view) =~ gettext("Scheduled tasks")
    refute text(view) =~ gettext("Settings")

    view = info(view, {:tap, {:page, :history}})
    settings = find(view, :row, id: "history-settings")
    assert settings.props.on_tap
    assert text(view) =~ gettext("Settings")

    files = find(view, :row, id: "history-files")
    assert files.props.on_tap
    assert text(view) =~ gettext("Files")

    tasks = find(view, :row, id: "history-tasks")
    assert tasks.props.on_tap
    assert text(view) =~ gettext("Scheduled tasks")

    about = find(view, :row, id: "history-about")
    assert about.props.on_tap
    assert text(view) =~ gettext("About")

    view = info(view, {:tap, {:page, :schedules}})
    assert assigns(view).page == :schedules
    refute assigns(view).schedules.loading?
    assert find(view, :scroll, id: "native-schedules")

    view = info(view, {:tap, {:page, :history}})
    view = info(view, {:tap, {:page, :settings}})
    assert text(view) =~ gettext("Model / AI")
  end

  test "a free-chat notification opens without inventing a workspace", %{view: view} do
    {:ok, conversation} = Handbean.ConversationStore.create_free(title: "Notify free")
    workspace_id = assigns(view).workspace["id"]

    {:ok, _} =
      Handbean.ConversationTranscriptStore.append(conversation["id"], %{
        "id" => "free-note",
        "role" => "assistant",
        "content" => "free persisted"
      })

    view =
      info(
        view,
        {:notification, %{"data" => %{"conversation_id" => conversation["id"]}}}
      )

    assert assigns(view).page == :chat
    assert assigns(view).chat.conversation["id"] == conversation["id"]
    assert assigns(view).workspace["id"] == workspace_id
    assert text(view) =~ "free persisted"
    refute text(view) =~ gettext("The conversation in the notification is unavailable")
  end

  test "workspace switch isolates drafts, models, running events, and Coordinator path", %{
    view: view,
    dir: dir
  } do
    workspace_a = assigns(view).workspace
    path_b = Path.join(dir, "workspace_b")
    File.mkdir_p!(path_b)
    File.write!(Path.join(path_b, "only-b.txt"), "b-file")
    {:ok, workspace_b} = Handbean.WorkspaceStore.add(path_b, name: "Project B")

    {:ok, conv_a} = Handbean.ConversationStore.create(workspace_a["id"], title: "Chat A")
    {:ok, conv_b} = Handbean.ConversationStore.create(workspace_b["id"], title: "Chat B")

    {:ok, _} =
      Handbean.ConversationTranscriptStore.append(conv_a["id"], %{
        "id" => "a1",
        "role" => "assistant",
        "content" => "answer-from-a"
      })

    assert {:ok, _} = Handbean.Permissions.ConversationMode.update(conv_a["id"], :yolo)
    assert {:ok, _} = Handbean.Permissions.ConversationMode.update(conv_b["id"], :prompt)

    view = info(view, {:tap, {:conversation, conv_a["id"]}})
    view = info(view, {:change, :draft, "draft-for-a"})
    assert assigns(view).workspace["id"] == workspace_a["id"]

    view = info(view, {:tap, {:page, :history}})
    listed = Enum.flat_map(assigns(view).history.workspaces, & &1.conversations)
    assert Enum.any?(listed, &(&1["id"] == conv_a["id"]))
    assert Enum.any?(listed, &(&1["id"] == conv_b["id"]))
    view = info(view, {:tap, {:conversation, conv_b["id"]}})
    assert assigns(view).workspace["id"] == workspace_b["id"]
    assert assigns(view).workspace["path"] == Path.expand(path_b)
    assert assigns(view).chat.conversation["id"] == conv_b["id"]
    assert assigns(view).draft == ""
    assert assigns(view).permission_mode == :prompt
    refute text(view) =~ "answer-from-a"
    refute text(view) =~ "draft-for-a"

    view = info(view, {:change, :draft, "draft-for-b"})
    topic_a = "session:#{conv_a["id"]}"

    view =
      info(view, {:agent_event, AgentEvent.message_delta(topic_a, "should-not-appear", 99)})

    assert assigns(view).chat.conversation["id"] == conv_b["id"]
    refute assigns(view).chat.stream =~ "should-not-appear"
    refute text(view) =~ "should-not-appear"

    view = info(view, {:tap, {:workspace, workspace_a["id"]}})
    assert assigns(view).workspace["id"] == workspace_a["id"]
    assert assigns(view).chat.conversation["id"] == conv_a["id"]
    assert assigns(view).draft == "draft-for-a"
    assert text(view) =~ "answer-from-a"
    assert assigns(view).permission_mode != :deny

    view = info(view, {:tap, {:workspace, workspace_b["id"]}})
    assert assigns(view).draft == "draft-for-b"

    server =
      start_supervised!({Bandit, plug: {ProviderFixture, self()}, ip: {127, 0, 0, 1}, port: 0})

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    assert :ok =
             Handbean.Agent.ModelConfig.write_config(%{
               "defaultProvider" => "fixture",
               "defaultModel" => "native-model",
               "providers" => %{
                 "fixture" => %{
                   "api" => "openai-chat-completions",
                   "apiKey" => "fixture-key",
                   "baseUrl" => "http://127.0.0.1:#{port}/v1",
                   "models" => [%{"id" => "native-model", "name" => "Fixture"}]
                 }
               }
             })

    view = view |> info({:change, :draft, "from-b"}) |> info({:tap, :send})
    assert_receive {:provider_request, request, _body}, 5_000
    id = assigns(view).chat.conversation["id"]
    assert {:ok, %{run_pid: runner, running?: true}} = Handbean.Agent.Coordinator.status(id)
    opts = :sys.get_state(runner).opts
    assert opts[:workspace_path] == Path.expand(path_b)
    assert opts[:working_directory] == Path.expand(path_b)
    assert opts[:workspace_id] == workspace_b["id"]
    send(request, :respond)
    send(request, :finish)
    assert_receive {:agent_event, %{kind: :run_end} = ended}, 5_000
    _view = info(view, {:agent_event, ended})
  end

  test "creating an empty workspace does not inherit the previous chat or draft", %{view: view} do
    {:ok, conversation} = Handbean.ConversationStore.create("default", title: "Keep me")

    {:ok, _} =
      Handbean.ConversationTranscriptStore.append(conversation["id"], %{
        "id" => "keep",
        "role" => "user",
        "content" => "old-project-message"
      })

    view =
      view
      |> info({:tap, {:conversation, conversation["id"]}})
      |> info({:change, :draft, "do-not-send-here"})
      |> info({:tap, {:page, :workspace}})
      |> info({:tap, :open_create})
      |> info({:change, :workspace_name, "Fresh"})
      |> info({:tap, :create_workspace})

    assert assigns(view).workspace["name"] == "Fresh"
    assert assigns(view).chat == nil
    assert assigns(view).draft == ""
    assert assigns(view).conversations == []
    refute text(view) =~ "old-project-message"
    refute text(view) =~ "do-not-send-here"
    assert File.dir?(assigns(view).workspace["path"])
  end

  test "notification switch reuses workspace apply and keeps the other draft", %{view: view} do
    workspace_a = assigns(view).workspace
    {:ok, extra} = HandbeanProbe.NativeWorkspaces.create_empty("Notify B")
    {:ok, conv_b} = Handbean.ConversationStore.create(extra["id"], title: "Notify chat")

    view =
      view
      |> info({:change, :draft, "stay-on-a"})
      |> info(
        {:notification,
         %{"data" => %{"workspace_id" => extra["id"], "conversation_id" => conv_b["id"]}}}
      )

    assert assigns(view).workspace["id"] == extra["id"]
    assert assigns(view).chat.conversation["id"] == conv_b["id"]
    view = info(view, {:tap, {:workspace, workspace_a["id"]}})
    assert assigns(view).draft == "stay-on-a"
  end

  test "a non-delta burst schedules one transcript reload and ignores a stale id", %{view: view} do
    {:ok, conversation} = Handbean.ConversationStore.create("default")
    id = conversation["id"]
    topic = "session:#{id}"
    view = info(view, {:tap, {:conversation, id}})
    entries = assigns(view).chat.entries

    view = info(view, {:agent_event, AgentEvent.tool_start(topic, "read", %{}, 1)})
    assert assigns(view).chat.entries != entries or assigns(view).chat.seq == 1

    first_entries = assigns(view).chat.entries
    view = info(view, {:agent_event, AgentEvent.tool_end(topic, "read", 1, nil, 2)})
    assert assigns(view).chat.transcript_dirty
    assert assigns(view).chat.entries == first_entries
    assert is_reference(assigns(view).chat.reload_timer)

    view = info(view, {:agent_event, AgentEvent.run_start(topic, "m", "p", 3)})
    assert assigns(view).chat.entries == first_entries

    assert_receive {:reload_transcript, ^id}, 200
    refute_received {:reload_transcript, _}

    view = info(view, {:reload_transcript, id})
    refute assigns(view).chat.transcript_dirty
    assert assigns(view).chat.reload_timer == nil

    stale = assigns(view).chat
    view = info(view, {:reload_transcript, "other-conversation"})
    assert assigns(view).chat == stale

    view = info(view, {:tap, :new_chat})
    assert assigns(view).chat == nil
    view = info(view, {:reload_transcript, id})
    assert assigns(view).chat == nil
  end

  test "deltas after a deferred boundary survive reload without duplicating", %{view: view} do
    {:ok, conversation} = Handbean.ConversationStore.create("default")
    id = conversation["id"]
    topic = "session:#{id}"
    view = info(view, {:tap, {:conversation, id}})

    view = info(view, {:agent_event, AgentEvent.tool_start(topic, "read", %{}, 1)})
    view = info(view, {:agent_event, AgentEvent.message_delta(topic, "abc", 2)})
    assert assigns(view).chat.stream == "abc"

    {:ok, _} =
      Handbean.ConversationTranscriptStore.append(id, %{
        "role" => "assistant",
        "content" => "abc"
      })

    view = info(view, {:agent_event, AgentEvent.tool_end(topic, "read", 1, nil, 3)})
    assert assigns(view).chat.stream == "abc"
    assert assigns(view).chat.transcript_dirty

    view = info(view, {:agent_event, AgentEvent.message_delta(topic, "def", 4)})
    assert assigns(view).chat.stream == "abcdef"

    if assigns(view).chat.reload_timer do
      assert_receive {:reload_transcript, ^id}, 200
    end

    view = info(view, {:reload_transcript, id})
    assert assigns(view).chat.stream == "def"
    assert Enum.any?(assigns(view).chat.entries, &(&1["content"] == "abc"))
    refute assigns(view).chat.stream =~ "abcdef"
  end
end
