defmodule HandbeanProbe.HomeScreenTest do
  use Mob.ScreenCase, async: false
  use Gettext, backend: HandbeanProbe.Gettext
  import HandbeanProbe.ScreenSettle

  alias HandbeanProbe.{HomeScreen, ModelSettings, NativeApproval, NativeChat, PendingRequests}
  alias HandbeanProbe.HomeScreen.{Notice, Settings}
  alias Handbean.ArtifactDelivery
  alias Handbean.PubSub.AgentEvent
  alias HandbeanWeb.WorkspaceHelper

  defmodule UnavailableHistory do
    def page(_id, _opts), do: {:error, :unavailable}
  end

  defmodule ApprovalProvider do
    @behaviour Handbean.Agent.Provider
    alias Handbean.Agent.Message

    # With `provider_config: %{gate: pid}` every provider call first reports
    # `{:provider_turn, turn, self()}` to `pid` and waits for
    # `{:provider_continue, turn}`. Tests use it to order "rule written to disk"
    # before "next turn evaluates ToolPolicy" without sleeping.
    def complete(messages, _tools, config) do
      turn = Enum.count(messages, &(&1.role == :tool_result))
      wait_for_gate(config[:gate], turn)

      message =
        if turn < 2 do
          Message.tool_use([
            %{
              type: "tool_use",
              id: "approval-#{turn}",
              name: "write",
              input: %{"file_path" => "approval.txt", "content" => "write-#{turn}"}
            }
          ])
        else
          Message.assistant("approval finished")
        end

      {:ok,
       %{
         stop_reason: if(turn < 2, do: :tool_use, else: :end_turn),
         messages: [message],
         usage: %{input_tokens: 1, output_tokens: 1}
       }}
    end

    def stream(messages, tools, config, _callback), do: complete(messages, tools, config)

    defp wait_for_gate(gate, turn) when is_pid(gate) do
      send(gate, {:provider_turn, turn, self()})

      receive do
        {:provider_continue, ^turn} -> :ok
      after
        5_000 -> :ok
      end
    end

    defp wait_for_gate(_gate, _turn), do: :ok
  end

  defmodule ApprovalFileProvider do
    @behaviour Handbean.Agent.Provider
    alias Handbean.Agent.Message

    def complete(messages, _tools, _config) do
      if Enum.any?(messages, &(&1.role == :tool_result)) do
        {:ok,
         %{
           stop_reason: :end_turn,
           messages: [Message.assistant("file approval finished")],
           usage: %{input_tokens: 1, output_tokens: 1}
         }}
      else
        {:ok,
         %{
           stop_reason: :tool_use,
           messages: [
             Message.tool_use([
               %{
                 type: "tool_use",
                 id: "approval-file-0",
                 name: "open_file",
                 input: %{"path" => "approval.txt"}
               }
             ])
           ],
           usage: %{input_tokens: 1, output_tokens: 1}
         }}
      end
    end

    def stream(messages, tools, config, _callback), do: complete(messages, tools, config)
  end

  defmodule ProviderFixture do
    def init(owner), do: owner

    def call(conn, owner) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:provider_request, self(), Jason.decode!(body)})

      receive do
        :respond -> :ok
      after
        5_000 -> :ok
      end

      conn =
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(200)

      {:ok, conn} =
        Plug.Conn.chunk(
          conn,
          "data: " <>
            Jason.encode!(%{
              choices: [%{delta: %{content: "Native fixture"}, finish_reason: nil}]
            }) <> "\n\n"
        )

      # Hold the response open: the UI must expose this prefix BEFORE completion.
      receive do
        :finish -> :ok
      after
        5_000 -> :ok
      end

      reply =
        "data: " <>
          Jason.encode!(%{
            choices: [%{delta: %{content: " answer"}, finish_reason: nil}]
          }) <>
          "\n\n" <>
          "data: " <>
          Jason.encode!(%{choices: [%{delta: %{}, finish_reason: "stop"}]}) <>
          "\n\ndata: [DONE]\n\n"

      {:ok, conn} = Plug.Conn.chunk(conn, reply)
      conn
    end
  end

  setup do
    Handbean.Repo.delete_all(Handbean.Storage.Conversation)

    dir = Path.join(System.tmp_dir!(), "native_chat_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    host = Application.get_env(:handbean, :host)
    previous_platform = Application.get_env(:handbean_probe, :native_platform)
    HandbeanProbe.NativePlatform.put!(:android)
    Handbean.Host.put!(%{data_dir: dir, shell: false, mcp: false})

    vars = %{
      "HANDBEAN_WORKSPACE" => Path.join(dir, "workspace"),
      "HANDBEAN_MODELS_FILE" => Path.join(dir, "models.json"),
      "HANDBEAN_WORKSPACES_FILE" => Path.join(dir, "workspaces.json"),
      "HANDBEAN_GLOBAL_SETTINGS_FILE" => Path.join(dir, "settings.json")
    }

    previous = Map.new(vars, fn {key, _} -> {key, System.get_env(key)} end)
    Enum.each(vars, fn {key, value} -> System.put_env(key, value) end)

    on_exit(fn ->
      HandbeanProbe.RuntimeCleanup.stop!()

      if host,
        do: Application.put_env(:handbean, :host, host),
        else: Application.delete_env(:handbean, :host)

      if previous_platform,
        do: Application.put_env(:handbean_probe, :native_platform, previous_platform),
        else: Application.delete_env(:handbean_probe, :native_platform)

      Enum.each(previous, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)

      _ = File.rm_rf(dir)
    end)

    %{view: settle(mount_screen(HomeScreen)), dir: dir}
  end

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
    view = info(view, {:tap, {:page, :attachments}})
    assert text(view) =~ gettext("Attachments")
    assert text(view) =~ gettext("Choose photos")
    assert text(view) =~ gettext("Open in system browser")
    assert text(view) =~ gettext("Share or open an artifact file")
    assert text(view) =~ gettext("Open with a system app")
    assert text(view) =~ gettext("Share to another app")
    refute text(view) =~ "{:platform"
    refute text(view) =~ gettext("Not implemented yet")
    view = info(view, {:tap, {:page, :workspace}})

    assert Enum.any?(
             flatten(tree(view)),
             &(&1.type == :settings_button && &1.props[:id] == "open_create")
           )

    view = info(view, {:tap, {:page, :settings}})
    assert text(view) =~ gettext("Default model")

    assert Enum.any?(
             flatten(tree(view)),
             &(&1.type == :settings_select && &1.props[:id] == "select-reasoning")
           )

    view = info(view, {:tap, {:reasoning, "medium"}})
    assert assigns(view).models.defaults.reasoning == "medium"
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

  test "first stamped event after loading without Session restores the live queue", %{view: view} do
    {:ok, conversation} = Handbean.ConversationStore.create("default")
    id = conversation["id"]
    view = info(view, {:tap, {:conversation, id}})
    assert assigns(view).chat.epoch == nil
    {:ok, _} = Handbean.PubSub.Session.start_or_get(session_id: id, session_store_enabled?: false)
    on_exit(fn -> Handbean.SessionSupervisor.stop_session(id) end)
    queue = start_supervised!({Handbean.Agent.CandidateQueue, session_id: id, owner: self()})
    run_id = Ecto.UUID.generate()
    :ok = Handbean.PubSub.Session.attach_run(id, self(), queue, run_id: run_id)
    :ok = Handbean.Agent.CandidateQueue.enqueue(queue, "queued", message_id: "queued")
    Handbean.PubSub.Session.broadcast_event(id, :thinking_delta, %{run_id: run_id})
    snapshot = Handbean.PubSub.Session.snapshot(id)
    event = Enum.max_by(snapshot.events, & &1.seq)
    view = info(view, {:agent_event, event})
    assert assigns(view).chat.pending["queued"].status == :queued
    assert assigns(view).chat.epoch == snapshot.epoch
    assert assigns(view).chat.thinking

    {:ok, _} =
      Handbean.ConversationTranscriptStore.append(id, %{
        "id" => "reply",
        "role" => "assistant",
        "content" => "answer"
      })

    Handbean.PubSub.Session.broadcast_event(id, :message_delta, %{
      run_id: run_id,
      transcript_id: "reply",
      text_offset: 0,
      text: "answer"
    })

    refute NativeChat.load(conversation).thinking
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

  test "blank send does not create a conversation; failed send preserves draft and conversation",
       %{view: view} do
    view = info(view, {:tap, :send})
    assert assigns(view).chat == nil
    view = view |> info({:change, :draft, "hello"}) |> info({:tap, :send})
    assert assigns(view).draft == "hello"
    assert notice_text(view) =~ send_failed()
    id = assigns(view).chat.conversation["id"]
    view = info(view, {:tap, :send})
    assert assigns(view).chat.conversation["id"] == id
    assert length(Handbean.ConversationStore.list_for_workspace("default")) == 1

    view = info(view, {:tap, :new_chat})
    assert assigns(view).draft == ""
    view = info(view, {:tap, {:conversation, id}})
    assert assigns(view).draft == "hello"
  end

  test "Android share is reviewed before it is added to the unsent draft", %{view: view} do
    root = share_root!("share_ui")

    id = Ecto.UUID.generate()

    write_share_fixture!(id, %{
      "state" => "pending_review",
      "subject" => "页面标题",
      "text" => "https://example.com/共享🙂",
      "attachments" => [],
      "consumption" => "structured_attachments"
    })

    view = info(view, {:share_intake_ready, id, "pending_review"})
    assert assigns(view).chat == nil
    assert assigns(view).draft == ""
    assert text(view) =~ "https://example.com/共享🙂"
    assert text(view) =~ gettext("Add to current draft")
    workspace_name = assigns(view).workspace["name"] || gettext("Workspace")

    assert text(view) =~
             gettext("Current target: %{workspace} · %{conversation}",
               workspace: workspace_name,
               conversation: gettext("New conversation")
             )

    assert text(view) =~ gettext("System share")

    view = info(view, {:tap, {:share_confirm, id}})
    assert assigns(view).chat == nil
    assert assigns(view).draft =~ "https://example.com/共享🙂"
    assert assigns(view).composer_mode == :chat
    assert MapSet.member?(assigns(view).merged_intake_ids, id)
    refute text(view) =~ gettext("Write review")
    refute text(view) =~ gettext("Generate review")
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

  test "native send reaches Coordinator and streams from a local fixture; stop cancels the run",
       %{view: view} do
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

    view =
      view
      |> info({:change, :draft, "stale draft"})
      |> info({:change, :draft, "粘贴中文🙂 最新输入"})
      |> info({:tap, :send})

    assert assigns(view).draft == ""
    assert assigns(view).chat.running
    assert_receive {:provider_request, request, body}, 5_000
    assert body["model"] == "native-model"

    assert Enum.any?(
             body["messages"],
             &(&1["role"] == "user" and &1["content"] == "粘贴中文🙂 最新输入")
           )

    send(request, :respond)

    assert_receive {:agent_event,
                    %{kind: :message_delta, payload: %{chunk: "Native fixture"}} = partial},
                   5_000

    view = info(view, {:agent_event, partial})
    assert assigns(view).chat.running
    assert text(view) =~ "Native fixture"

    assert Enum.any?(
             assigns(view).chat.entries,
             &(&1["id"] == partial.payload.transcript_id and &1["content"] == "Native fixture")
           )

    assert assigns(view).chat.stream == ""
    refute text(view) =~ "Native fixture answer"

    refute Enum.any?(
             NativeChat.transcript(assigns(view).chat.conversation["id"]),
             &(&1["content"] == "Native fixture answer")
           )

    send(request, :finish)

    assert_receive {:agent_event, %{kind: :run_end} = ended}, 5_000
    view = info(view, {:agent_event, ended})
    refute assigns(view).chat.running
    assert text(view) =~ "Native fixture answer"
    view = view |> info({:change, :draft, "cancel fixture"}) |> info({:tap, :send})
    assert_receive {:provider_request, request, _body}, 5_000
    assert assigns(view).chat.running
    assert find(view, :icon, id: "send")
    assert find(view, :icon, id: "stop")
    view = view |> info({:change, :draft, "运行中追加中文🙂"}) |> info({:submit, :send})
    id = assigns(view).chat.conversation["id"]
    assert {:ok, %{running?: true, queue_pid: queue}} = Handbean.Agent.Coordinator.status(id)

    assert [%{message: %{content: "运行中追加中文🙂"}, metadata: %{deliver_as: :steer}}] =
             Handbean.Agent.CandidateQueue.get_messages(queue)

    assert Enum.any?(
             NativeChat.transcript(id),
             &(&1["content"] == "运行中追加中文🙂" and &1["interrupts_work"] == true and
                 &1["delivery"] == "steer")
           )

    assert text(view) =~ gettext("Insert next ▾")
    {:acknowledged, inbound_id} = assigns(view).last_send_ack
    assert assigns(view).chat.pending[inbound_id].deliver_as == :steer
    assert assigns(view).deliver_mode == :steer

    assert notice_text(view) =~
             gettext(
               "The message will be inserted at the next step. To wait until this run finishes, switch to “When done”, or write “when you’re done…”."
             )

    view = info(view, {:tap, :toggle_deliver_mode})
    assert assigns(view).deliver_mode == :follow_up
    view = view |> info({:change, :draft, "完成后处理"}) |> info({:tap, :send})
    assert assigns(view).deliver_mode == :steer

    assert Enum.any?(
             Handbean.Agent.CandidateQueue.get_messages(queue),
             &(&1.message.content == "完成后处理" and &1.metadata.deliver_as == :follow_up)
           )

    view = info(view, {:tap, :stop})
    assert_receive {:agent_event, %{kind: :run_end} = cancelled}, 5_000
    view = info(view, {:agent_event, cancelled})
    refute assigns(view).chat.running
    assert Enum.any?(Map.values(assigns(view).chat.pending), &(&1.status == :undelivered))

    old_id =
      assigns(view).chat.pending
      |> Enum.find_value(fn {id, item} -> if item.status == :undelivered, do: id end)

    keep_att = %{"id" => "keep-stop", "filename" => "keep-stop.png"}

    view =
      %{
        view
        | socket:
            view.socket
            |> Mob.Socket.assign(:draft, "keep after stop")
            |> Mob.Socket.assign(:pending_attachments, [keep_att])
      }

    view = info(view, {:tap, {:resend_pending, old_id}})
    assert assigns(view).draft == "keep after stop"
    assert assigns(view).pending_attachments == [keep_att]
    refute Map.has_key?(assigns(view).chat.pending, old_id)
    assert_receive {:provider_request, resent_request, _body}, 5_000
    send(resent_request, :respond)
    send(resent_request, :finish)
    send(request, :respond)
    send(request, :finish)
  end

  test "follow_up enqueue does not show the steer insertion hint", %{view: view} do
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

    view = view |> info({:change, :draft, "start"}) |> info({:tap, :send})
    assert_receive {:provider_request, request, _body}, 5_000
    assert assigns(view).chat.running
    refute notice_text(view)

    view =
      view
      |> info({:tap, :toggle_deliver_mode})
      |> info({:change, :draft, "later please"})
      |> info({:tap, :send})

    refute notice_text(view)
    id = assigns(view).chat.conversation["id"]
    assert {:ok, %{queue_pid: queue}} = Handbean.Agent.Coordinator.status(id)

    assert Enum.any?(
             Handbean.Agent.CandidateQueue.get_messages(queue),
             &(&1.metadata.deliver_as == :follow_up)
           )

    view = info(view, {:tap, :stop})
    assert_receive {:agent_event, %{kind: :run_end} = cancelled}, 5_000
    _ = info(view, {:agent_event, cancelled})
    send(request, :respond)
    send(request, :finish)
  end

  test "resend_pending sends only the undelivered item and keeps composer draft", %{view: view} do
    write_native_models!("http://127.0.0.1:9/v1")
    {:ok, conversation} = Handbean.ConversationStore.create("default")
    id = conversation["id"]
    old_id = "msg-old-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Handbean.ConversationTranscriptStore.append(id, %{
        "id" => old_id,
        "role" => "user",
        "content_type" => "user_msg",
        "content" => "retry me"
      })

    {:ok, _session} = Handbean.PubSub.Session.start_or_get(session_id: id, model: "native-model")
    {:ok, queue} = Handbean.Agent.CandidateQueue.start_link(session_id: id, owner: self())
    :ok = Handbean.PubSub.Session.attach_run(id, self(), queue)

    chat =
      conversation
      |> NativeChat.load()
      |> NativeChat.note_enqueued(old_id, :steer, %{content: "retry me"})
      |> then(&%{&1 | pending: Handbean.Agent.PendingMessages.mark_undelivered(&1.pending)})

    keep_att = %{"id" => "draft-att", "filename" => "keep.png"}

    view =
      %{
        view
        | socket:
            view.socket
            |> Mob.Socket.assign(:chat, chat)
            |> Mob.Socket.assign(:draft, "keep draft")
            |> Mob.Socket.assign(:pending_attachments, [keep_att])
      }

    view = info(view, {:tap, {:resend_pending, old_id}})
    assert assigns(view).draft == "keep draft"
    assert assigns(view).pending_attachments == [keep_att]
    refute Map.has_key?(assigns(view).chat.pending, old_id)

    assert Enum.any?(
             Handbean.Agent.CandidateQueue.get_messages(queue),
             &(&1.message.content == "retry me")
           )

    view = info(view, {:tap, {:resend_pending, old_id}})
    assert assigns(view).draft == "keep draft"
    assert length(Handbean.Agent.CandidateQueue.get_messages(queue)) == 1
  end

  test "resend_pending keeps the item when send fails", %{view: view} do
    {:ok, conversation} = Handbean.ConversationStore.create("default")
    old_id = "msg-fail-#{System.unique_integer([:positive])}"

    chat =
      NativeChat.load(conversation)
      |> NativeChat.note_enqueued(old_id, :steer, %{content: "retry me"})
      |> then(&%{&1 | pending: Handbean.Agent.PendingMessages.mark_undelivered(&1.pending)})

    view =
      %{
        view
        | socket:
            view.socket
            |> Mob.Socket.assign(:chat, chat)
            |> Mob.Socket.assign(:draft, "keep draft")
            |> Mob.Socket.assign(:pending_attachments, [])
      }

    view = info(view, {:tap, {:resend_pending, old_id}})
    assert assigns(view).chat.pending[old_id].status == :undelivered
    assert assigns(view).draft == "keep draft"
    assert notice_text(view)
  end

  test "undo of queued item restores persisted attachments into the composer", %{view: view} do
    write_native_models!("http://127.0.0.1:9/v1")
    {:ok, conversation} = Handbean.ConversationStore.create("default")
    id = conversation["id"]
    mid = "msg-undo-#{System.unique_integer([:positive])}"
    atts = [%{"id" => "att-u", "filename" => "back.png"}]

    {:ok, _} =
      Handbean.ConversationTranscriptStore.append(id, %{
        "id" => mid,
        "role" => "user",
        "content_type" => "user_msg",
        "content" => "queued pic",
        "attachments" => atts
      })

    {:ok, _session} = Handbean.PubSub.Session.start_or_get(session_id: id, model: "native-model")
    {:ok, queue} = Handbean.Agent.CandidateQueue.start_link(session_id: id, owner: self())
    :ok = Handbean.PubSub.Session.attach_run(id, self(), queue)
    :ok = Handbean.Agent.CandidateQueue.enqueue(queue, "queued pic", message_id: mid)

    chat = NativeChat.load(conversation)
    assert chat.pending[mid].attachments == atts

    view =
      %{
        view
        | socket:
            view.socket
            |> Mob.Socket.assign(:chat, chat)
            |> Mob.Socket.assign(:draft, "already")
            |> Mob.Socket.assign(:pending_attachments, [])
      }

    view = info(view, {:tap, {:cancel_pending, mid}})
    assert assigns(view).draft =~ "queued pic"
    assert Enum.any?(assigns(view).pending_attachments, &(&1["filename"] == "back.png"))
  end

  test "stream projection filters duplicates and other conversations and reconciles on completion",
       %{view: view} do
    {:ok, conversation} = Handbean.ConversationStore.create("default")
    state = NativeChat.load(conversation)
    event = AgentEvent.message_delta("session:#{conversation["id"]}", "native reply", 1)
    state = NativeChat.project(event, state)
    assert state.stream == "native reply"
    assert NativeChat.project(event, state) == state
    assert NativeChat.project(%{event | topic: "session:other", seq: 2}, state) == state

    {:ok, _} =
      Handbean.ConversationTranscriptStore.append(conversation["id"], %{
        "id" => "a1",
        "role" => "assistant",
        "content" => "native reply"
      })

    state = NativeChat.project(AgentEvent.run_end(event.topic, :done, 1, 2), state)
    assert state.stream == ""
    refute state.running
    assert [%{"content" => "native reply"}] = state.entries
    assert assigns(view).chat == nil
  end

  test "models save, remount, edit without exposing or erasing key, and select defaults", %{
    view: view
  } do
    workspace = assigns(view).workspace
    state = new_model(workspace)
    state = ModelSettings.action(:save_model, state, workspace)
    assert state.notice == gettext("Model saved")
    assert [%{id: "test/native-model"}] = state.models
    state = ModelSettings.action({:edit_model, "test", "native-model"}, state, workspace)
    refute Map.has_key?(state.form, :api_key)
    state = ModelSettings.change(state, :name, "Renamed")
    state = ModelSettings.action(:save_model, state, workspace)
    config = File.read!(Handbean.Agent.ModelConfig.config_file_path()) |> Jason.decode!()
    assert config["providers"]["test"]["apiKey"] == "fixture-key-not-real"
    assert [%{"name" => "Renamed"}] = config["providers"]["test"]["models"]
    state = ModelSettings.action({:default_model, "test/native-model"}, state, workspace)
    state = ModelSettings.action({:reasoning, "high"}, state, workspace)
    assert state.reasoning == "high"

    assert Handbean.Settings.effective_model_ai(workspace["path"]).default_model ==
             "test/native-model"

    view =
      view
      |> info({:tap, {:page, :models}})
      |> info({:tap, {:edit_model, "test", "native-model"}})

    assert_renderable(view, extra: [:icon, :settings_select, :settings_button])
    refute Enum.any?(flatten(tree(view)), &(&1.type == :text_field and &1.props[:secure]))
    refute inspect(tree(view)) =~ "fixture-key-not-real"

    view = info(view, {:tap, :cancel_model})
    view = info(view, {:tap, {:edit_provider, "test"}})
    secure = Enum.find(flatten(tree(view)), &(&1.type == :text_field and &1.props[:secure]))
    assert secure.props.value == ""
    refute inspect(tree(view)) =~ "fixture-key-not-real"
  end

  test "model fetch clears an old error, preserves durable notices, and keeps its provider selection",
       %{
         view: view
       } do
    assert :ok =
             Handbean.Agent.ModelConfig.write_config(%{
               "defaultProvider" => "alpha",
               "providers" => %{
                 "alpha" => %{
                   "name" => "Alpha",
                   "baseUrl" => "invalid alpha",
                   "apiKey" => "fixture-key",
                   "api" => "openai-completions",
                   "models" => []
                 },
                 "beta" => %{
                   "name" => "Beta",
                   "baseUrl" => "invalid beta",
                   "apiKey" => "fixture-key",
                   "api" => "openai-completions",
                   "models" => []
                 }
               }
             })

    socket =
      view.socket
      |> Mob.Socket.assign(:models, ModelSettings.load(assigns(view).workspace))
      |> Notice.put_error("old catalog error")
      |> then(&Settings.handle({:tap, {:fetch_models, "beta"}}, &1))

    assert socket.assigns.notice == nil
    assert socket.assigns.models.selected_provider == "beta"
    assert socket.assigns.models.notice == gettext("Fetching models…")

    socket =
      socket
      |> Notice.put_info("Send outcome unknown", :share)
      |> then(&Settings.handle({:tap, {:fetch_models, "alpha"}}, &1))

    assert socket.assigns.notice.kind == :share
    assert socket.assigns.models.selected_provider == "alpha"
  end

  test "model validation rejects HTTP and corrupt config without losing form", %{view: view} do
    workspace = assigns(view).workspace
    state = new_provider(workspace) |> ModelSettings.change(:base_url, "http://example.com")
    rejected = ModelSettings.action(:save_provider, state, workspace)
    assert rejected.notice =~ "HTTPS"
    refute File.exists?(Handbean.Agent.ModelConfig.config_file_path())
    state = new_model(workspace)
    File.write!(Handbean.Agent.ModelConfig.config_file_path(), "invalid json")
    rejected = ModelSettings.action(:save_model, state, workspace)
    assert rejected.notice =~ gettext("Could not read model configuration")
    assert rejected.form.model == "native-model"
  end

  test "native Work, activity and output expansion are independent and final stays visible", %{
    view: view
  } do
    {:ok, c} = Handbean.ConversationStore.create("default")

    tools = [
      %{
        "id" => "one",
        "content_type" => "tool",
        "tool" => "bash",
        "status" => "done",
        "input" => %{"command" => "pwd"}
      },
      %{
        "id" => "two",
        "content_type" => "tool",
        "tool" => "browser",
        "status" => "error",
        "error" => "fixture failure"
      },
      %{
        "id" => "separator",
        "role" => "assistant",
        "phase" => "commentary",
        "content" => "Between groups"
      },
      %{
        "id" => "three",
        "content_type" => "tool",
        "tool" => "read",
        "status" => "done",
        "input" => %{"path" => "README.md"}
      },
      %{
        "id" => "final",
        "role" => "assistant",
        "phase" => "final",
        "status" => "completed",
        "content" => "Final answer"
      }
    ]

    Enum.each(tools, &Handbean.ConversationTranscriptStore.append(c["id"], &1))
    view = info(view, {:tap, {:conversation, c["id"]}})
    assert text(view) =~ "Final answer"
    assert text(view) =~ "Between groups"
    refute text(view) =~ gettext("Show Work")
    refute text(view) =~ "pwd"
    refute text(view) =~ "fixture failure"
    refute text(view) =~ "README.md"

    assert text(view) =~
             WorkspaceHelper.tool_work_summary([%{"tool" => "bash"}, %{"tool" => "browser"}])

    assert text(view) =~ WorkspaceHelper.tool_work_summary([%{"tool" => "read"}])

    view = info(view, {:tap, {:toggle_tool_work, "one"}})
    assert text(view) =~ "pwd"
    refute text(view) =~ "fixture failure"
    view = info(view, {:tap, {:toggle_tool_output, "two"}})
    assert text(view) =~ "fixture failure"
    view = info(view, {:tap, {:toggle_tool_work, "one"}})
    refute text(view) =~ "fixture failure"
    assert text(view) =~ "Final answer"
    assert text(view) =~ "Between groups"
    view = info(view, {:tap, {:toggle_tool_work, "one"}})
    assert text(view) =~ "fixture failure"
    view = info(view, {:tap, :new_chat})
    assert assigns(view).work_groups == %{}
    assert assigns(view).work_segments == %{}
    assert assigns(view).tool_outputs == %{}
    assert assigns(view).file_diffs == %{}
    view = info(view, {:tap, {:conversation, c["id"]}})
    refute text(view) =~ "fixture failure"
    refute text(view) =~ gettext("Show Work")
    refute text(view) =~ "README.md"
  end

  test "an edit line opens its diff and copies the relative path", %{view: view} do
    on_exit(fn -> Application.delete_env(:handbean_probe, :clipboard_put) end)
    {:ok, c} = Handbean.ConversationStore.create("default")

    {:ok, _} =
      Handbean.ConversationTranscriptStore.append(c["id"], %{
        "id" => "edit-1",
        "content_type" => "tool",
        "tool" => "edit",
        "status" => "done",
        "input" => %{"file_path" => "lib/a.ex"},
        "diff_lines" => [%{"type" => "add", "text" => "hello-diff"}]
      })

    view = info(view, {:tap, {:conversation, c["id"]}})
    view = info(view, {:tap, {:toggle_tool_work, "edit-1"}})
    assert text(view) =~ "+1"
    refute text(view) =~ "hello-diff"
    view = info(view, {:tap, {:toggle_file_diff, "edit-1"}})
    assert text(view) =~ "hello-diff"

    parent = self()

    Application.put_env(:handbean_probe, :clipboard_put, fn text ->
      send(parent, {:copied, text})
    end)

    info(view, {:tap, {:copy_relative_path, "lib/a.ex"}})
    assert_receive {:copied, "lib/a.ex"}
  end

  test "assistant history uses markdown while user input stays literal", %{view: view} do
    {:ok, c} = Handbean.ConversationStore.create("default")
    user = "## literal user input"
    reply = "## Answer\n\n**bold**\n\n```json\n{\"ok\": true}\n```"

    for {role, body} <- [{"user", user}, {"assistant", reply}] do
      {:ok, _} =
        Handbean.ConversationTranscriptStore.append(c["id"], %{"role" => role, "content" => body})
    end

    view = info(view, {:tap, {:conversation, c["id"]}})
    assert find(view, :text, text: reply).props.markdown
    refute Map.get(find(view, :text, text: user).props, :markdown, false)
  end

  test "thinking-only deltas show activity and text appears incrementally", %{view: view} do
    {:ok, c} = Handbean.ConversationStore.create("default")
    view = info(view, {:tap, {:conversation, c["id"]}})
    chat = %{assigns(view).chat | running: true}
    view = %{view | socket: Mob.Socket.assign(view.socket, :chat, chat)}
    topic = "session:#{c["id"]}"

    view =
      info(view, {:agent_event, AgentEvent.new(topic, :thinking_delta, %{chunk: "reasoning"}, 1)})

    assert text(view) =~ gettext("Thinking…")
    refute text(view) =~ "reasoning"
    view = info(view, {:agent_event, AgentEvent.message_delta(topic, "第一段", 2)})
    assert find(view, :text, id: "stream-text").props.text == "第一段"
    assert find(view, :text, id: "stream-text").props.markdown
    assert find(view, :text, id: "stream-text").props.markdown_streaming
    view = info(view, {:agent_event, AgentEvent.message_delta(topic, " → 第二段", 3)})
    assert find(view, :text, id: "stream-text").props.text == "第一段 → 第二段"
    refute text(view) =~ gettext("Thinking…")
  end

  test "reopening an active file approval reconciles the missing export", %{view: view} do
    parent = self()
    workspace = assigns(view).workspace
    path = workspace["path"]
    File.mkdir_p!(Path.join(path, ".handbean"))
    File.write!(Path.join(path, "approval.txt"), "approval snapshot")

    File.write!(
      Handbean.WorkspaceSettings.path(path),
      Jason.encode!(%{"tools" => %{"default_mode" => "prompt"}})
    )

    install_platform_fake(fn req, _opts ->
      send(parent, {:approval_platform, req})
      {:ok, :async}
    end)

    {:ok, conversation} = Handbean.ConversationStore.create("default")
    view = info(view, {:tap, {:conversation, conversation["id"]}})

    {:ok, %{run_pid: runner}} =
      Handbean.Agent.Coordinator.add_message(conversation["id"], "open approval.txt",
        provider: ApprovalFileProvider,
        provider_config: %{},
        source: :native,
        model: "fixture",
        streaming: false,
        workspace_path: path,
        tools: [Handbean.Tool.Builtin.OpenFile],
        max_turns: 3
      )

    on_exit(fn -> Handbean.Agent.Coordinator.cancel(conversation["id"]) end)
    assert_receive {:agent_event, %{kind: :tool_approval_requested} = request}, 5_000
    await_approval(runner)

    view = info(view, {:agent_event, request})

    assert_receive {:approval_platform,
                    %{op: "platform_export", request_id: first_id, generation: first_generation}},
                   1_000

    view = info(view, {:tap, :new_chat})

    assert_receive {:approval_platform,
                    %{
                      op: "platform_cancel",
                      payload: %{"target_request_id" => ^first_id}
                    }},
                   1_000

    view =
      info(
        view,
        {:engine_result,
         %{
           request_id: first_id,
           generation: first_generation,
           result: Handbean.JSON.encode!(%{"snapshot_id" => "snapshot-late-after-navigation"})
         }}
      )

    assert_receive {:approval_platform,
                    %{
                      op: "platform_cleanup",
                      generation: ^first_generation,
                      payload: %{
                        "snapshot_id" => "snapshot-late-after-navigation",
                        "owner_request_id" => ^first_id
                      }
                    }},
                   1_000

    view = info(view, {:tap, {:conversation, conversation["id"]}})

    assert assigns(view).chat.pending_approval
    assert_receive {:approval_platform, %{op: "platform_export", request_id: second_id}}, 1_000
    assert second_id != first_id
    refute_received {:approval_platform, %{op: "platform_export"}}
  end

  for {action, scope} <- [
        {:approve, :once},
        {:approve, :session},
        {:approve, :always},
        {:deny, :once},
        {:deny, :always}
      ] do
    test "native approval #{action}/#{scope} resumes real Runner with correct persistence", %{
      view: view
    } do
      action = unquote(action)
      scope = unquote(scope)
      workspace = assigns(view).workspace
      path = workspace["path"]
      File.mkdir_p!(Path.join(path, ".handbean"))

      File.write!(
        Handbean.WorkspaceSettings.path(path),
        Jason.encode!(%{"tools" => %{"default_mode" => "prompt"}})
      )

      {:ok, c} = Handbean.ConversationStore.create("default")
      view = info(view, {:tap, {:conversation, c["id"]}})

      {:ok, %{run_pid: runner}} =
        Handbean.Agent.Coordinator.add_message(c["id"], "approval fixture",
          provider: ApprovalProvider,
          provider_config: %{gate: self()},
          source: :native,
          model: "fixture",
          streaming: false,
          workspace_path: path,
          tools: [Handbean.Tool.Builtin.Write],
          max_turns: 4
        )

      on_exit(fn -> Handbean.Agent.Coordinator.cancel(c["id"]) end)
      release_turn(0)
      assert_receive {:agent_event, %{kind: :tool_approval_requested} = request}, 5_000
      view = info(view, {:agent_event, request})
      assert text(view) =~ gettext("Tool action needs approval")
      assert text(view) =~ "approval.txt"
      refute File.exists?(Path.join(path, "approval.txt"))
      await_approval(runner)
      # Reopening restores from runtime snapshot, not a made-up UI flag.
      view = view |> info({:tap, :new_chat}) |> info({:tap, {:conversation, c["id"]}})
      assert assigns(view).chat.pending_approval
      view = info(view, {:tap, :dismiss_approval})
      refute text(view) =~ gettext("Tool action needs approval")
      assert text(view) =~ gettext("Waiting for tool approval · Review")
      view = info(view, {:tap, :review_approval})
      tag = {:approval, c["id"], assigns(view).chat.approval_seq, action, scope}
      # A stale button from another conversation must never authorize this one.
      stale =
        info(
          view,
          {:tap, {:approval, "other", assigns(view).chat.approval_seq, :approve, :always}}
        )

      assert assigns(stale).chat == assigns(view).chat

      view = info(view, {:tap, tag})
      assert assigns(view).notice == nil
      refute assigns(view).chat.pending_approval
      # `decide/5` has returned, so an :always rule is on disk before the
      # resumed run asks the provider for its next tool call.
      release_turn(1)

      if scope == :once do
        assert_receive {:agent_event, %{kind: :tool_approval_requested} = second}, 5_000
        assert second.seq > request.seq
        await_approval(runner)
        view = info(view, {:agent_event, second})
        assert assigns(info(view, {:tap, tag})).chat == assigns(view).chat
        view = info(view, {:tap, {:approval, c["id"], second.seq, :deny, :once}})
        refute assigns(view).chat.pending_approval
      end

      release_turn(2)

      assert_receive {:agent_event,
                      %{kind: :message_delta, payload: %{chunk: "approval finished"}}},
                     5_000

      expected =
        cond do
          action == :deny -> nil
          scope == :once -> "write-0"
          true -> "write-1"
        end

      if expected,
        do: assert(File.read!(Path.join(path, "approval.txt")) == expected),
        else: refute(File.exists?(Path.join(path, "approval.txt")))

      {:ok, settings} = Handbean.WorkspaceSettings.load(path)

      if scope == :always do
        list = if action == :approve, do: "allow", else: "deny"
        assert settings["tools"][list] == ["write(approval.txt)"]
      else
        refute settings["tools"]["allow"]
        refute settings["tools"]["deny"]
      end
    end
  end

  test "always-allow resume succeeds even when workspace rules cannot be saved", %{view: view} do
    workspace = assigns(view).workspace
    path = workspace["path"]
    File.mkdir_p!(Path.join(path, ".handbean"))
    settings_path = Handbean.WorkspaceSettings.path(path)
    original = Jason.encode!(%{"tools" => %{"default_mode" => "prompt"}})
    File.write!(settings_path, original)

    {:ok, c} = Handbean.ConversationStore.create("default")
    view = info(view, {:tap, {:conversation, c["id"]}})

    {:ok, %{run_pid: runner}} =
      Handbean.Agent.Coordinator.add_message(c["id"], "approval fixture",
        provider: ApprovalProvider,
        provider_config: %{},
        source: :native,
        model: "fixture",
        streaming: false,
        workspace_path: path,
        tools: [Handbean.Tool.Builtin.Write],
        max_turns: 4
      )

    on_exit(fn -> Handbean.Agent.Coordinator.cancel(c["id"]) end)
    assert_receive {:agent_event, %{kind: :tool_approval_requested} = request}, 5_000
    view = info(view, {:agent_event, request})
    await_approval(runner)
    refute File.exists?(Path.join(path, "approval.txt"))

    File.write!(settings_path, "invalid json")
    tag = {:approval, c["id"], assigns(view).chat.approval_seq, :approve, :always}
    view = info(view, {:tap, tag})
    assert assigns(view).chat.pending_approval == nil

    assert notice_text(view) =~
             gettext("Approval submitted, but the rule could not be saved to the workspace.")

    assert_receive {:agent_event, %{kind: :tool_end}}, 5_000
    assert File.exists?(Path.join(path, "approval.txt"))
    File.write!(settings_path, original)
  end

  test "decide rejects a missing pending approval" do
    chat = %{conversation: %{"id" => "unused"}, pending_approval: nil}

    assert NativeApproval.decide(chat, %{"path" => "/tmp"}, :approve, :once) ==
             {:error, :not_awaiting_approval}
  end

  test "composer selectors expose model, reasoning, and permission options", %{view: view} do
    model = find(view, :settings_select, id: "composer-model")
    reasoning = find(view, :settings_select, id: "composer-reasoning")
    permission = find(view, :settings_select, id: "composer-permission")

    for select <- [model, reasoning, permission] do
      refute Map.has_key?(select.props, :on_tap)
    end

    assert length(reasoning.children) == length(Handbean.Agent.Reasoning.levels())
    assert length(permission.children) == 3
  end

  test "composer selection persists in workspace without leaving chat or losing draft", %{
    view: view
  } do
    assert :ok =
             Handbean.Agent.ModelConfig.write_config(%{
               "defaultProvider" => "fixture",
               "defaultModel" => "native-model",
               "providers" => %{
                 "fixture" => %{
                   "api" => "openai-chat-completions",
                   "apiKey" => "fixture-key",
                   "models" => [%{"id" => "native-model", "name" => "Fixture"}]
                 }
               }
             })

    view = info(view, {:change, :draft, "keep this draft"})
    view = info(view, {:tap, {:composer_setting, :reasoning, "high"}})
    assert assigns(view).page == :chat
    assert assigns(view).draft == "keep this draft"
    assert assigns(view).models.reasoning == "high"

    assert Handbean.Settings.effective_model_ai(assigns(view).workspace["path"]).reasoning ==
             "high"

    model = hd(assigns(view).models.allowed_models).id
    view = info(view, {:tap, {:composer_setting, :default_model, model}})
    assert assigns(view).page == :chat
    assert assigns(view).models.default == model
    assert assigns(view).draft == "keep this draft"
  end

  test "permission selector persists workspace policy and reloads on mount", %{view: view} do
    view = info(view, {:tap, {:page, :permissions}})
    assert text(view) =~ gettext("Tool permissions")
    assert text(view) =~ gettext("Smart approval")
    refute text(view) =~ "Full access"
    view = info(view, {:tap, {:permission_mode, :prompt}})
    assert assigns(view).page == :chat
    assert assigns(view).permission_mode == :prompt
    assert assigns(mount_screen(HomeScreen)).permission_mode == :prompt

    assert Handbean.Permissions.ToolPolicy.from_workspace(assigns(view).workspace["path"]).default_mode ==
             :prompt

    view = info(view, {:tap, {:permission_mode, :yolo}})
    assert assigns(view).permission_mode == :yolo

    view = info(view, {:tap, {:permission_mode, :auto_review}})
    assert assigns(view).permission_mode == :auto_review
    assert assigns(mount_screen(HomeScreen)).permission_mode == :auto_review
    path = assigns(view).workspace["path"]
    assert Handbean.Permissions.ToolPolicy.from_workspace(path).default_mode == :auto
    assert Handbean.WorkspaceSettings.approvals_reviewer(path) == :auto_review
  end

  test "approval projection ignores foreign and stale requests and clears cancelled review", %{
    view: view
  } do
    {:ok, c} = Handbean.ConversationStore.create("default")
    view = info(view, {:tap, {:conversation, c["id"]}})

    payload = %{
      "action_requests" => [
        %{"tool_call_id" => "one", "tool_name" => "write", "arguments" => %{"content" => "中文🙂"}}
      ]
    }

    event = AgentEvent.new("session:#{c["id"]}", :tool_approval_requested, payload, 1)
    view = info(view, {:agent_event, event})
    assert text(view) =~ "中文🙂"
    assert assigns(view).chat.running

    assert assigns(info(view, {:agent_event, %{event | topic: "session:other", seq: 2}})).chat ==
             assigns(view).chat

    assert assigns(info(view, {:agent_event, %{event | seq: 0}})).chat == assigns(view).chat
    ended = AgentEvent.run_end(event.topic, :interrupted, 1, 2)
    view = info(view, {:agent_event, ended})
    assert assigns(view).chat.pending_approval == payload
    view = info(view, {:agent_event, %{ended | seq: 3, payload: %{status: "cancelled"}}})
    refute assigns(view).chat.pending_approval
    refute assigns(view).chat.running
    refute text(view) =~ gettext("Tool action needs approval")
  end

  test "external approval cancellation clears snapshots, bindings, and unfinished exports", %{
    view: view
  } do
    parent = self()
    workspace = assigns(view).workspace
    path = workspace["path"]
    File.write!(Path.join(path, "external-a.txt"), "a")
    File.write!(Path.join(path, "external-b.txt"), "b")

    install_platform_fake(fn req, _opts ->
      send(parent, {:external_cancel_platform, req})
      {:ok, :async}
    end)

    {:ok, conversation} = Handbean.ConversationStore.create("default")
    view = info(view, {:tap, {:conversation, conversation["id"]}})

    payload = %{
      "action_requests" => [
        %{
          "tool_call_id" => "external-a",
          "tool_name" => "open_file",
          "arguments" => %{"path" => "external-a.txt"}
        },
        %{
          "tool_call_id" => "external-b",
          "tool_name" => "open_file",
          "arguments" => %{"path" => "external-b.txt"}
        }
      ]
    }

    topic = "session:#{conversation["id"]}"
    requested = AgentEvent.new(topic, :tool_approval_requested, payload, 1)
    view = info(view, {:agent_event, requested})

    assert_receive {:external_cancel_platform,
                    %{op: "platform_export", payload: %{"relative_path" => "external-a.txt"}} =
                      export_a},
                   1_000

    assert_receive {:external_cancel_platform,
                    %{op: "platform_export", payload: %{"relative_path" => "external-b.txt"}} =
                      export_b},
                   1_000

    view =
      info(
        view,
        {:engine_result,
         %{
           request_id: export_a.request_id,
           generation: export_a.generation,
           result: Handbean.JSON.encode!(%{"snapshot_id" => "snapshot-external-a"})
         }}
      )

    assert {:ok, %{snapshot_id: "snapshot-external-a"}} =
             Handbean.ExportSnapshot.Binding.fetch(conversation["id"], "external-a")

    cancelled = AgentEvent.run_end(topic, :cancelled, 1, 2)
    view = info(view, {:agent_event, cancelled})

    refute assigns(view).chat.pending_approval
    assert assigns(view).approval_snapshots == %{}
    assert assigns(view).approval_export_inflight == MapSet.new()
    assert :error = Handbean.ExportSnapshot.Binding.fetch(conversation["id"], "external-a")

    assert_receive {:external_cancel_platform,
                    %{
                      op: "platform_cleanup",
                      payload: %{"snapshot_id" => "snapshot-external-a"}
                    }},
                   1_000

    assert_receive {:external_cancel_platform,
                    %{
                      op: "platform_cancel",
                      payload: %{"target_request_id" => unfinished_request_id}
                    }},
                   1_000

    assert unfinished_request_id == export_b.request_id
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

    File.write!(
      Handbean.WorkspaceSettings.path(workspace_b["path"]),
      Jason.encode!(%{"tools" => %{"default_mode" => "deny"}})
    )

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
    assert assigns(view).permission_mode == :deny
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

  test "late import receipts after cancel do not open a workspace", %{view: view, dir: dir} do
    view = info(view, {:tap, {:page, :workspace}})
    view = info(view, {:tap, :start_import})
    request_id = assigns(view).workspaces.import.request_id
    assert request_id
    current = assigns(view).workspace["id"]
    view = info(view, {:tap, :cancel_import})

    dest = Path.join(HandbeanProbe.NativeWorkspaces.imported_root(), request_id)
    File.mkdir_p!(dest)
    File.write!(Path.join(dest, "copied.txt"), "payload")

    view =
      info(view, {:files, :picked, [%{path: dest, name: "Late", request_id: request_id}]})

    assert assigns(view).workspace["id"] == current
    refute Enum.any?(Handbean.WorkspaceStore.list(), &(&1["name"] == "Late"))
    refute File.dir?(dest)
    assert File.dir?(dir)
  end

  test "platform begin starts a typed Request and the C wire map has required keys", %{view: view} do
    parent = self()

    install_platform_fake(fn req, _opts ->
      send(parent, {:platform_started, req, HandbeanProbe.Platform.Nif.wire_map(req)})
      {:ok, :async}
    end)

    import_payload = %{
      "path" => "/cache/controlled_import/draft/note.ex",
      "display_name" => "note.ex",
      "mime" => "text/x-source"
    }

    view = info(view, {:platform, :begin, :import, import_payload})
    request_id = assigns(view).last_platform_request
    generation = composer_generation(view)
    assert is_binary(request_id)
    assert PendingRequests.has?(assigns(view).pending_requests, request_id)

    assert_receive {:platform_started, req, wired}, 1_000
    assert %HandbeanProbe.Platform.Request{} = req
    assert req.op == "platform_import"
    assert req.request_id == request_id
    assert req.generation == generation
    assert is_pid(req.caller)
    assert req.payload["path"] == import_payload["path"]
    assert req.payload["display_name"] == "note.ex"
    assert {:ok, payload} = Jason.decode(wired.payload)
    assert payload["op"] == "platform_import"
    assert payload["path"] == import_payload["path"]
    assert Map.keys(wired) |> Enum.sort() == [:caller, :generation, :op, :payload, :request_id]
    assert is_binary(wired.request_id) and wired.request_id != ""
    assert is_integer(wired.generation)
    assert is_pid(wired.caller)

    pending_after_import = assigns(view).pending_requests
    view = info(view, {:platform, :begin, :export})
    assert assigns(view).pending_requests == pending_after_import
    assert assigns(view).notice

    assert {:error, :unknown_op} =
             HandbeanProbe.Platform.Request.for_kind(
               :camera,
               %{
                 request_id: request_id,
                 composer_generation: generation,
                 workspace_id: "default",
                 conversation_id: nil
               },
               self()
             )
  end

  test "platform start failure does not leave a pending request", %{view: view} do
    install_platform_fake(fn _req, _opts -> {:error, :host_unbound} end)

    before = PendingRequests.entries(assigns(view).pending_requests)
    view = info(view, {:platform, :begin, :import, %{"path" => "/cache/controlled_import/a.txt"}})
    assert PendingRequests.entries(assigns(view).pending_requests) == before
    assert assigns(view).last_platform_request == nil
    assert assigns(view).notice
  end

  test "fake import joins the current draft and stale results are ignored", %{view: view} do
    parent = self()

    install_platform_fake(fn req, _opts ->
      send(parent, {:platform_cmd, req})
      {:ok, :async}
    end)

    dir = Path.join(System.tmp_dir!(), "native_import_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "note.ex")
    File.write!(path, "defmodule Note do\nend\n")

    view =
      info(view, {:platform, :begin, :import, %{"path" => path, "display_name" => "note.ex"}})

    request_id = assigns(view).last_platform_request
    generation = composer_generation(view)
    assert_receive {:platform_cmd, %{op: "platform_import"}}, 1_000

    imported = %Handbean.Attachments.Imported{
      attachment_id: "att-live",
      source: :test,
      display_name: "note.ex",
      canonical_type: "text/x-source",
      size_bytes: File.stat!(path).size,
      controlled_path: path
    }

    view = info(view, {:platform, :result, request_id, {:ok, imported}})
    assert length(assigns(view).pending_attachments) == 1
    assert text(view) =~ "note.ex"

    view = info(view, {:tap, :new_chat})
    assert composer_generation(view) > generation
    assert assigns(view).pending_attachments == []
    assert PendingRequests.by_kind(assigns(view).pending_requests, :import) == []
    assert File.exists?(path)

    view = info(view, {:platform, :result, request_id, {:ok, imported}})
    assert assigns(view).pending_attachments == []
    assert File.exists?(path)
  end

  test "image draft thumbs open a local preview without sending", %{view: view} do
    parent = self()

    install_platform_fake(fn req, _opts ->
      send(parent, {:platform_cmd, req})
      {:ok, :async}
    end)

    dir = Path.join(System.tmp_dir!(), "native_img_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "shot.png")

    File.write!(
      path,
      <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8,
        6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 248, 207, 192,
        240, 31, 0, 5, 0, 1, 253, 46, 43, 34, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>
    )

    view =
      info(view, {:platform, :begin, :import, %{"path" => path, "display_name" => "shot.png"}})

    request_id = assigns(view).last_platform_request

    imported = %Handbean.Attachments.Imported{
      attachment_id: "img-live",
      source: :test,
      display_name: "shot.png",
      canonical_type: "image/png",
      size_bytes: File.stat!(path).size,
      controlled_path: path
    }

    view = info(view, {:platform, :result, request_id, {:ok, imported}})
    assert length(assigns(view).pending_attachments) == 1
    assert assigns(view).composer_open_id == nil
    refute assigns(view).chat && assigns(view).chat.running

    view = info(view, {:tap, {:open_draft_image, "img-live"}})
    assert assigns(view).composer_open_id == "img-live"
    assert text(view) =~ "shot.png"
    assert text(view) =~ "image/png"
    refute assigns(view).chat && assigns(view).chat.running

    view = info(view, {:tap, :close_draft_image})
    assert assigns(view).composer_open_id == nil
    assert length(assigns(view).pending_attachments) == 1
  end

  test "restored sent images open from message and attachment ids without sending", %{
    view: view
  } do
    workspace = assigns(view).workspace
    {:ok, conv} = Handbean.ConversationStore.create(workspace["id"])

    dest =
      Path.join(
        Handbean.Uploads.ensure_conversation_dir!(workspace["path"], conv["id"]),
        "sent-1.png"
      )

    File.write!(
      dest,
      <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8,
        6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 248, 207, 192,
        240, 31, 0, 5, 0, 1, 253, 46, 43, 34, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>
    )

    relative = Path.join([".handbean", "uploads", conv["id"], "sent-1.png"])

    {:ok, entry} =
      Handbean.Agent.TranscriptPersistence.append_inbound(conv["id"], "历史图片",
        attachments: [
          %{
            "id" => "sent-1",
            "kind" => "image",
            "mime_type" => "image/png",
            "filename" => "hist.png",
            "relative_path" => relative
          }
        ],
        inbound_id: "sent-in"
      )

    view = info(view, {:tap, {:conversation, conv["id"]}})
    chat = assigns(view).chat
    assert chat.workspace_id == workspace["id"]
    assert chat.workspace_path == workspace["path"]
    refute chat.running
    assert Enum.any?(chat.entries, &(&1["id"] == entry["id"]))

    view = info(view, {:tap, {:open_sent_image, entry["id"], "sent-1"}})
    assert assigns(view).timeline_open == %{message_id: entry["id"], attachment_id: "sent-1"}
    assert assigns(view).composer_open_id == nil
    assert text(view) =~ "hist.png"
    assert text(view) =~ "image/png"
    refute assigns(view).chat.running

    view = info(view, {:tap, :close_sent_image})
    assert assigns(view).timeline_open == nil
  end

  test "switching drafts cancels pending ops and only deletes importer-owned files", %{
    view: view
  } do
    parent = self()

    install_platform_fake(fn req, _opts ->
      send(parent, {:platform_cmd, req})
      {:ok, :async}
    end)

    owned = Path.join(System.tmp_dir!(), "owned_import_#{System.unique_integer([:positive])}")
    File.mkdir_p!(owned)
    owned_path = Path.join(owned, "kept.ex")
    File.write!(owned_path, "defmodule Kept do\nend\n")

    foreign = Path.join(System.tmp_dir!(), "foreign_import_#{System.unique_integer([:positive])}")
    File.mkdir_p!(foreign)
    foreign_path = Path.join(foreign, "secret.ex")
    File.write!(foreign_path, "secret")

    Application.put_env(:handbean_probe, :staging_roots, [owned])
    on_exit(fn -> Application.delete_env(:handbean_probe, :staging_roots) end)

    view = info(view, {:platform, :begin, :import, %{"path" => owned_path}})
    request_id = assigns(view).last_platform_request
    assert_receive {:platform_cmd, %{op: "platform_import", request_id: ^request_id}}, 1_000

    imported = %Handbean.Attachments.Imported{
      attachment_id: "owned-1",
      source: :test,
      display_name: "kept.ex",
      canonical_type: "text/x-source",
      size_bytes: 20,
      controlled_path: owned_path
    }

    view = info(view, {:platform, :result, request_id, {:ok, imported}})

    view =
      info(view, {:platform, :begin, :import, %{"path" => "/cache/controlled_import/pending.ex"}})

    pending_id = assigns(view).last_platform_request
    assert_receive {:platform_cmd, %{op: "platform_import", request_id: ^pending_id}}, 1_000

    view = info(view, {:tap, :new_chat})
    assert_receive {:platform_cmd, cancel_req}, 1_000
    assert cancel_req.op == "platform_cancel"
    assert cancel_req.request_id != pending_id
    assert cancel_req.payload["target_request_id"] == pending_id
    refute File.exists?(owned_path)
    assert File.exists?(foreign_path)

    view =
      info(
        view,
        {:platform, :result, pending_id,
         {:ok, %{controlled_path: foreign_path, display_name: "secret.ex", source: "test"}}}
      )

    assert assigns(view).pending_attachments == []
    assert File.exists?(foreign_path)
  end

  test "opening another conversation cancels pending attachment work", %{view: view} do
    parent = self()

    install_platform_fake(fn req, _opts ->
      send(parent, {:platform_cmd, req})
      {:ok, :async}
    end)

    view = info(view, {:platform, :begin, :import, %{"path" => "/cache/pending.txt"}})
    generation = composer_generation(view)
    assert_receive {:platform_cmd, %{request_id: request_id}}
    {:ok, conversation} = Handbean.ConversationStore.create(assigns(view).workspace["id"])
    view = info(view, {:tap, {:conversation, conversation["id"]}})

    assert composer_generation(view) > generation
    assert PendingRequests.by_kind(assigns(view).pending_requests, :import) == []
    assert assigns(view).pending_attachments == []
    assert_receive {:platform_cmd, %{op: "platform_cancel", payload: payload}}
    assert payload["target_request_id"] == request_id
  end

  test "engine_result with C atom keys joins the draft", %{view: view} do
    install_platform_fake(fn _req, _opts -> {:ok, :async} end)

    dir = Path.join(System.tmp_dir!(), "native_import_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "from_c.ex")
    File.write!(path, "defmodule FromC do\nend\n")

    view = info(view, {:platform, :begin, :import, %{"path" => path}})
    request_id = assigns(view).last_platform_request

    json =
      Jason.encode!(%{
        "attachment_id" => "from-c",
        "display_name" => "from_c.ex",
        "canonical_type" => "text/x-source",
        "controlled_path" => path,
        "size_bytes" => File.stat!(path).size,
        "source" => "test"
      })

    view =
      info(view, {:engine_result, %{request_id: request_id, generation: 1, result: json}})

    assert Enum.any?(assigns(view).pending_attachments, fn att ->
             (att["filename"] || att[:filename]) == "from_c.ex"
           end)
  end

  test "text-only model blocks photo picker with a dismissible warning", %{view: view} do
    view = seed_input_models(view)
    view = info(view, {:change, :draft, "keep this draft"})
    view = info(view, {:tap, {:platform, :begin, :pick_photos}})
    assert assigns(view).input_warning.status == :unsupported
    assert assigns(view).input_warning.model == "Step Router v1"
    assert assigns(view).last_platform_request == nil
    assert find(view, :sheet)
    view = info(view, {:dismiss, :dismiss_input_warning})
    assert assigns(view).input_warning == nil
    assert assigns(view).draft == "keep this draft"
  end

  test "image result after model switch is kept, warns, and cannot be sent", %{
    view: view,
    dir: dir
  } do
    view = seed_input_models(view)
    path = Path.join(dir, "draft.png")
    File.write!(path, <<0>>)
    view = info(view, {:tap, {:composer_setting, :default_model, "stepfun/step-3.7-flash"}})

    att = %{
      "id" => "image-draft",
      "kind" => "image",
      "mime_type" => "image/png",
      "filename" => "draft.png",
      "controlled_path" => path,
      "size_bytes" => 1
    }

    socket = HandbeanProbe.HomeScreen.Platform.add_attachment(view.socket, att)
    view = %{view | socket: socket}
    assert assigns(view).input_warning == nil

    view = info(view, {:tap, {:composer_setting, :default_model, "stepfun/step-router-v1"}})
    assert assigns(view).input_warning.status == :unsupported
    view = info(view, {:tap, :dismiss_input_warning})
    view = info(view, {:tap, :send})
    assert assigns(view).input_warning.status == :unsupported
    assert assigns(view).chat == nil
    assert length(assigns(view).pending_attachments) == 1
    assert Handbean.ConversationStore.list() == []

    view = info(view, {:tap, {:composer_setting, :default_model, "stepfun/step-3.7-flash"}})
    assert assigns(view).input_warning == nil
    view = info(view, {:tap, {:composer_setting, :default_model, "stepfun/step-router-v1"}})
    view = info(view, {:tap, {:remove_attachment, "image-draft"}})
    assert assigns(view).input_warning == nil
    assert assigns(view).pending_attachments == []
  end

  test "unknown image capability warns without discarding externally imported images", %{
    view: view,
    dir: dir
  } do
    view = seed_input_models(view)
    path = Path.join(dir, "shared.png")
    File.write!(path, <<0>>)
    :ok = Handbean.Agent.ModelConfig.add_model("stepfun", "custom", %{"name" => "Custom"})
    view = info(view, {:tap, {:composer_setting, :default_model, "stepfun/custom"}})

    att = %{
      "id" => "shared",
      "kind" => "image",
      "mime_type" => "image/png",
      "filename" => "shared.png",
      "controlled_path" => path,
      "size_bytes" => 1,
      "source" => "share"
    }

    socket = HandbeanProbe.HomeScreen.Platform.add_attachment(view.socket, att)
    assert socket.assigns.input_warning.status == :unknown
    assert socket.assigns.pending_attachments == [att]
  end

  test "photo picker begin uses one request id and stale batch files are released", %{
    view: view
  } do
    view = seed_input_models(view)
    view = info(view, {:tap, {:composer_setting, :default_model, "stepfun/step-3.7-flash"}})
    parent = self()

    install_platform_fake(fn req, _opts ->
      send(parent, {:platform_cmd, req})
      {:ok, :async}
    end)

    view = info(view, {:tap, {:platform, :begin, :pick_photos}})
    request_id = assigns(view).last_platform_request
    generation = composer_generation(view)
    assert_receive {:platform_cmd, req}, 1_000
    assert req.op == "platform_pick_photos"
    assert req.request_id == request_id

    dir = Path.join(System.tmp_dir!(), "photo_stale_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "pic.bin")
    File.write!(path, "img")
    Application.put_env(:handbean_probe, :staging_roots, [dir])
    on_exit(fn -> Application.delete_env(:handbean_probe, :staging_roots) end)

    view = info(view, {:tap, :new_chat})
    assert composer_generation(view) > generation

    json =
      Jason.encode!(%{
        "attachments" => [
          %{
            "attachment_id" => "p1",
            "display_name" => "pic.jpg",
            "canonical_type" => "image/jpeg",
            "controlled_path" => path,
            "size_bytes" => 3,
            "source" => "photo"
          }
        ],
        "errors" => []
      })

    view = info(view, {:engine_result, %{request_id: request_id, result: json}})
    assert assigns(view).pending_attachments == []
    refute File.exists?(path)
  end

  test "iOS photo pick waits for files_picked, imports into composer, and ignores late results",
       %{view: view} do
    previous_platform = Application.get_env(:handbean_probe, :native_platform)
    previous_adapter = Application.get_env(:handbean_probe, :ios_platform_adapter)
    Application.delete_env(:handbean_probe, :platform_fake)
    HandbeanProbe.NativePlatform.put!(:ios)

    Application.put_env(
      :handbean_probe,
      :ios_platform_adapter,
      HandbeanProbe.HomeScreenTest.IOSAdapter
    )

    Application.put_env(:handbean_probe, :ios_test_pid, self())
    Application.put_env(:handbean_probe, :ios_adapter_reply, :ok)

    staging = Path.join(System.tmp_dir!(), "hs_ios_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(staging, "draft"))
    Application.put_env(:handbean_probe, :staging_roots, [staging])

    on_exit(fn ->
      File.rm_rf!(staging)
      Application.delete_env(:handbean_probe, :staging_roots)
      Application.delete_env(:handbean_probe, :ios_test_pid)
      Application.delete_env(:handbean_probe, :ios_adapter_reply)

      if previous_platform,
        do: Application.put_env(:handbean_probe, :native_platform, previous_platform),
        else: Application.delete_env(:handbean_probe, :native_platform)

      if previous_adapter,
        do: Application.put_env(:handbean_probe, :ios_platform_adapter, previous_adapter),
        else: Application.delete_env(:handbean_probe, :ios_platform_adapter)
    end)

    view = seed_input_models(view)
    view = info(view, {:tap, {:composer_setting, :default_model, "stepfun/step-3.7-flash"}})
    view = info(view, {:tap, {:platform, :begin, :pick_photos}})
    request_id = assigns(view).last_platform_request
    generation = composer_generation(view)
    assert is_binary(request_id)
    assert_receive :pick_images
    refute_received {:engine_result, _}
    assert PendingRequests.has?(assigns(view).pending_requests, request_id)
    assert assigns(view).pending_attachments == []

    png = Path.join(System.tmp_dir!(), "hs_pick_#{System.unique_integer([:positive])}.png")

    File.write!(
      png,
      <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8,
        6, 0, 0, 0, 31, 21, 196, 137>>
    )

    view = info(view, {:files, :picked, [%{path: png, name: "shot.png", size: 32}]})
    assert_receive {:engine_result, map}, 1_000
    view = info(view, {:engine_result, map})
    assert length(assigns(view).pending_attachments) == 1
    att = hd(assigns(view).pending_attachments)
    assert att["filename"] == "shot.png"
    assert att["controlled_path"]
    assert String.starts_with?(att["controlled_path"], staging)

    view = info(view, {:tap, :new_chat})
    assert composer_generation(view) > generation
    assert assigns(view).pending_attachments == []

    view = info(view, {:files, :picked, [%{path: png, name: "late.png"}]})
    refute_received {:engine_result, _}
    assert assigns(view).pending_attachments == []
  end

  test "mount scan lists durable share when ready event was dropped", %{view: view} do
    root = share_root!("share_pre")

    id = Ecto.UUID.generate()

    write_share_fixture!(id, %{
      "state" => "pending_review",
      "text" => "prestart share",
      "attachments" => []
    })

    {:ok, socket} = HomeScreen.mount(%{}, %{}, view.socket)
    view = settle(%{view | socket: socket})
    assert text(view) =~ "prestart share"
    assert Enum.any?(assigns(view).share_intakes, &(&1["intake_id"] == id))
  end

  test "storage_error notify is visible", %{view: view} do
    view = info(view, {:share_intake_ready, Ecto.UUID.generate(), "storage_error"})

    assert notice_text(view) =~
             gettext("The share could not be written to local storage. Retry or free up space.")
  end

  test "share confirm merges draft without sending; ack is explicit", %{view: view} do
    root = share_root!("share_hs")

    id = Ecto.UUID.generate()

    write_share_fixture!(id, %{
      "state" => "pending_review",
      "text" => "from share",
      "attachments" => []
    })

    view = info(view, {:share_intake_ready, id, "pending_review"})
    assert text(view) =~ "from share"
    assert text(view) =~ gettext("Add to current draft")

    view = info(view, {:tap, {:share_confirm, id}})
    assert assigns(view).draft == "from share"
    assert MapSet.member?(assigns(view).merged_intake_ids, id)
    assert assigns(view).chat == nil
    assert {:ok, %{"state" => "merged_current_process"}} = HandbeanProbe.ShareIntake.get(id)

    view = info(view, {:tap, {:share_confirm, id}})
    assert assigns(view).draft == "from share"

    view = info(view, {:tap, :send})
    assert assigns(view).draft == "from share"
    assert notice_text(view) =~ send_failed()
    assert {:ok, %{"state" => "merged_current_process"}} = HandbeanProbe.ShareIntake.get(id)
    refute assigns(view).last_send_ack
  end

  test "share confirm from settings is not dispatched to ModelSettings", %{view: view} do
    root = share_root!("share_set")

    id = Ecto.UUID.generate()

    write_share_fixture!(id, %{
      "state" => "pending_review",
      "text" => "from settings page",
      "attachments" => []
    })

    view =
      view
      |> info({:share_intake_ready, id, "pending_review"})
      |> info({:tap, {:page, :settings}})
      |> info({:tap, {:share_confirm, id}})

    assert assigns(view).draft == "from settings page"
    assert assigns(view).page == :chat
    assert {:ok, %{"state" => "merged_current_process"}} = HandbeanProbe.ShareIntake.get(id)
  end

  test "failed merge persistence leaves draft untouched", %{view: view} do
    root = share_root!("share_failm")

    id = Ecto.UUID.generate()

    write_share_fixture!(id, %{
      "state" => "pending_review",
      "text" => "must not merge",
      "attachments" => []
    })

    dir = Path.join(root, id)
    File.chmod!(dir, 0o500)
    on_exit(fn -> File.chmod!(dir, 0o700) end)

    view =
      view
      |> info({:change, :draft, "original draft"})
      |> info({:share_intake_ready, id, "pending_review"})
      |> info({:tap, {:share_confirm, id}})

    assert assigns(view).draft == "original draft"
    refute MapSet.member?(assigns(view).merged_intake_ids, id)

    assert notice_text(view) =~
             gettext("The share confirmation could not be saved: %{reason}", reason: "")

    assert {:ok, %{"state" => "pending_review"}} = HandbeanProbe.ShareIntake.get(id)
  end

  test "importing intake cannot confirm into draft", %{view: view} do
    root = share_root!("share_imp")

    id = Ecto.UUID.generate()

    write_share_fixture!(id, %{"state" => "importing", "text" => "in flight", "attachments" => []})

    view =
      view
      |> info({:change, :draft, "keep"})
      |> info({:tap, {:share_confirm, id}})

    assert assigns(view).draft == "keep"
    refute MapSet.member?(assigns(view).merged_intake_ids, id)
    assert {:ok, %{"state" => "importing"}} = HandbeanProbe.ShareIntake.get(id)
  end

  test "failed mark_send_pending aborts send without coordinator", %{view: view} do
    missing = Ecto.UUID.generate()
    view = info(view, {:change, :draft, "should not send"})

    socket = %{
      view.socket
      | assigns: Map.put(view.socket.assigns, :merged_intake_ids, MapSet.new([missing]))
    }

    {:noreply, socket} = HomeScreen.handle_info({:tap, :send}, socket)
    view = settle(%{view | socket: socket})

    assert assigns(view).draft == "should not send"

    assert notice_text(view) =~
             gettext("The share send state could not be saved: %{reason}", reason: "")

    refute assigns(view).last_send_ack
    assert assigns(view).chat
    assert NativeChat.transcript(assigns(view).chat.conversation["id"]) == []
  end

  test "overflow share notify is visible and does not add review", %{view: view} do
    view = info(view, {:share_intake_ready, Ecto.UUID.generate(), "too_many_pending"})

    assert notice_text(view) =~
             gettext("Pending shares are full (max %{max}). Confirm or discard one first.",
               max: HandbeanProbe.ShareIntake.max_pending()
             )

    assert assigns(view).share_intakes == []
  end

  test "workspace copy confirm is queued and late discard rolls back", %{view: view} do
    root = share_root!("share_ws_hs")

    workspace = assigns(view).workspace
    a = Ecto.UUID.generate()
    b = Ecto.UUID.generate()
    source_dir = Path.join(root, a)
    File.mkdir_p!(source_dir)
    source = Path.join(source_dir, "notes.md")
    File.write!(source, "shared notes")

    write_share_fixture!(a, %{
      "state" => "pending_review",
      "consumption" => "workspace_copy",
      "created_seq" => 1,
      "text" => "first share",
      "files" => [
        %{"status" => "ready", "name" => "notes.md", "path" => source, "size" => 12}
      ]
    })

    write_share_fixture!(b, %{
      "state" => "pending_review",
      "consumption" => "workspace_copy",
      "created_seq" => 2,
      "text" => "second share",
      "files" => []
    })

    view =
      view
      |> info({:share_intake_ready, a, "pending_review"})
      |> info({:share_intake_ready, b, "pending_review"})

    assert text(view) =~ "first share"
    assert text(view) =~ "second share"

    view = info(view, {:tap, {:share_confirm, a}})
    assert Map.has_key?(assigns(view).share_confirming, a)
    assert Enum.any?(assigns(view).share_intakes, &(&1["intake_id"] == b))
    refute Enum.any?(assigns(view).share_intakes, &(&1["intake_id"] == a))
    assert assigns(view).chat == nil
    assert assigns(view).draft == ""

    Application.put_env(:handbean_probe, :share_io_notify, self())
    on_exit(fn -> Application.delete_env(:handbean_probe, :share_io_notify) end)

    view = info(view, {:tap, {:share_discard, a}})
    refute Map.has_key?(assigns(view).share_confirming, a)
    assert_receive {:share_rollback, ^a, :ok}, 1_000

    dest = Path.join([workspace["path"], ".handbean", "shared", a])
    File.mkdir_p!(dest)
    File.write!(Path.join(dest, "notes.md"), "shared notes")

    view =
      info(
        view,
        {:share_workspace_result,
         %{
           intake_id: a,
           target: HandbeanProbe.ShareConfirm.target_from(workspace, nil, a),
           result: {:ok, [".handbean/shared/#{a}/notes.md"]}
         }}
      )

    assert_receive {:share_rollback, ^a, :ok}, 1_000
    refute File.exists?(dest)
    assert assigns(view).draft == ""
    refute MapSet.member?(assigns(view).merged_intake_ids, a)
  end

  test "late workspace copy after workspace switch does not merge current draft", %{view: view} do
    root = share_root!("share_ws_switch")
    Application.put_env(:handbean_probe, :share_io_notify, self())
    on_exit(fn -> Application.delete_env(:handbean_probe, :share_io_notify) end)

    original = assigns(view).workspace
    a = Ecto.UUID.generate()
    source_dir = Path.join(root, a)
    File.mkdir_p!(source_dir)
    source = Path.join(source_dir, "notes.md")
    File.write!(source, "shared notes")

    write_share_fixture!(a, %{
      "state" => "pending_review",
      "consumption" => "workspace_copy",
      "created_seq" => 1,
      "text" => "switch share",
      "files" => [
        %{"status" => "ready", "name" => "notes.md", "path" => source, "size" => 12}
      ]
    })

    view = info(view, {:share_intake_ready, a, "pending_review"})
    view = info(view, {:tap, {:share_confirm, a}})
    target = assigns(view).share_confirming[a]
    assert target["workspace_path"] == original["path"]

    dest = Path.join([original["path"], ".handbean", "shared", a])
    File.mkdir_p!(dest)
    File.write!(Path.join(dest, "notes.md"), "shared notes")

    other = %{"id" => "ws-other", "path" => Path.join(root, "other_ws")}
    File.mkdir_p!(other["path"])

    socket = %{
      view.socket
      | assigns:
          view.socket.assigns
          |> Map.put(:workspace, other)
          |> Map.put(:draft, "typed after switch")
          |> Map.put(:chat, nil)
    }

    view = %{view | socket: socket}

    view =
      info(
        view,
        {:share_workspace_result,
         %{
           intake_id: a,
           target: target,
           result: {:ok, [".handbean/shared/#{a}/notes.md"]}
         }}
      )

    assert_receive {:share_rollback, ^a, :ok}, 1_000
    refute File.exists?(dest)
    assert assigns(view).draft == "typed after switch"
    refute MapSet.member?(assigns(view).merged_intake_ids, a)
    refute File.exists?(Path.join([other["path"], ".handbean", "shared", a]))
  end

  test "lost share send ack is visible and does not auto retry", %{view: view} do
    root = share_root!("share_lost")

    {:ok, conv} = Handbean.ConversationStore.create("default")

    id = Ecto.UUID.generate()

    write_share_fixture!(id, %{
      "state" => "send_pending",
      "send_attempt_id" => "never-written",
      "conversation_id" => conv["id"],
      "text" => "x"
    })

    view = info(view, {:share_intake_ready, id, "send_pending"})

    assert notice_text(view) =~
             gettext(
               "Send outcome unknown. Not resent automatically; check the conversation before deciding."
             )

    refute assigns(view).last_send_ack
    assert {:ok, %{"state" => "outcome_unknown"}} = HandbeanProbe.ShareIntake.get(id)
  end

  test "user delivery taps only send typed url or snapshot commands", %{view: view} do
    parent = self()

    install_platform_fake(fn req, _opts ->
      send(parent, {:platform_cmd, req})
      {:ok, :async}
    end)

    workspace = assigns(view).workspace
    File.write!(Path.join(workspace["path"], "report.pdf"), "%PDF")

    view = info(view, {:tap, {:page, :attachments}})
    view = info(view, {:change, :open_url_draft, "file:///tmp/x"})
    view = info(view, {:tap, {:delivery, :open_url}})
    assert assigns(view).notice
    refute_received {:platform_cmd, _}

    view = info(view, {:change, :open_url_draft, "https://example.com/order"})
    view = info(view, {:tap, {:delivery, :open_url}})
    assert_receive {:platform_cmd, url_req}, 1_000
    assert url_req.op == "platform_open_url"
    assert url_req.payload["url"] == "https://example.com/order"
    refute Map.has_key?(url_req.payload, "action")

    view = info(view, {:change, :artifact_path, "report.pdf"})
    view = info(view, {:tap, {:delivery, :share_file}})
    assert_receive {:platform_cmd, export_req}, 1_000
    assert export_req.op == "platform_export"
    assert export_req.payload["relative_path"] == "report.pdf"
    request_id = export_req.request_id

    view =
      info(
        view,
        {:platform, :result, request_id,
         {:ok,
          %{
            "snapshot_id" => "snap-9",
            "owner_request_id" => request_id,
            "display_name" => "report.pdf"
          }}}
      )

    assert_receive {:platform_cmd, share_req}, 1_000
    assert share_req.op == "platform_share_snapshot"
    assert share_req.payload["snapshot_id"] == "snap-9"
    refute Map.has_key?(share_req.payload, "component")

    view =
      info(
        view,
        {:platform, :result, share_req.request_id, {:ok, %{"outcome" => "chooser_presented"}}}
      )

    # Outcome copy is owned by sigil's Intent, not this backend.
    assert notice_text(view) =~ ArtifactDelivery.format_outcome("chooser_presented")
  end

  test "a delivery request past its deadline is cancelled and reported once", %{view: view} do
    parent = self()

    install_platform_fake(fn req, _opts ->
      send(parent, {:platform_cmd, req})
      {:ok, :async}
    end)

    Application.put_env(:handbean_probe, :android_intent_await_ms, 0)
    on_exit(fn -> Application.delete_env(:handbean_probe, :android_intent_await_ms) end)

    view = info(view, {:tap, {:page, :attachments}})
    view = info(view, {:change, :open_url_draft, "https://example.com/slow"})
    view = info(view, {:tap, {:delivery, :open_url}})
    assert_receive {:platform_cmd, %{op: "platform_open_url", request_id: request_id}}, 1_000
    assert PendingRequests.has?(assigns(view).pending_requests, request_id)

    tag = PendingRequests.timeout_message()
    assert_receive {^tag, ^request_id}, 1_000
    view = info(view, {tag, request_id})

    refute PendingRequests.has?(assigns(view).pending_requests, request_id)
    assert_receive {:platform_cmd, %{op: "platform_cancel", payload: payload}}, 1_000
    assert payload["target_request_id"] == request_id

    assert notice_text(view) =~
             gettext("The system operation did not answer in time and was cancelled.")

    # A late host reply for the expired request is dropped without a second notice.
    view = info(view, {:tap, {:page, :attachments}})

    view =
      info(view, {:engine_result, %{request_id: request_id, result: ~s({"outcome":"opened"})}})

    refute (notice_text(view) || "") =~ ArtifactDelivery.format_outcome("opened")
  end

  test "an engine_result whose generation does not match the request is dropped", %{view: view} do
    parent = self()

    install_platform_fake(fn req, _opts ->
      send(parent, {:platform_cmd, req})
      {:ok, :async}
    end)

    view = info(view, {:tap, {:page, :attachments}})
    view = info(view, {:change, :open_url_draft, "https://example.com/gen"})
    view = info(view, {:tap, {:delivery, :open_url}})
    assert_receive {:platform_cmd, %{op: "platform_open_url"} = req}, 1_000

    stale =
      info(
        view,
        {:engine_result,
         %{
           request_id: req.request_id,
           generation: req.generation + 1,
           result: ~s({"outcome":"opened"})
         }}
      )

    refute (notice_text(stale) || "") =~ ArtifactDelivery.format_outcome("opened")
    # The mismatching reply consumed the entry: correlation is one-shot.
    refute PendingRequests.has?(assigns(stale).pending_requests, req.request_id)

    fresh =
      info(
        view,
        {:engine_result,
         %{
           request_id: req.request_id,
           generation: req.generation,
           result: ~s({"outcome":"opened"})
         }}
      )

    assert notice_text(fresh) =~ ArtifactDelivery.format_outcome("opened")
  end

  test "host directory picker opens the in-app folder browser and lists off-screen", %{
    view: view,
    dir: dir
  } do
    File.mkdir_p!(Path.join(dir, "picker-fixture"))
    Application.put_env(:handbean_probe, :directory_picker_screen, self())
    on_exit(fn -> Application.delete_env(:handbean_probe, :directory_picker_screen) end)
    # Same wiring as HandbeanProbe.App: the host key points at the probe picker.
    Handbean.Host.put!(
      Map.put(
        Application.get_env(:handbean, :host),
        :directory_picker,
        HandbeanProbe.DirectoryPicker
      )
    )

    assert Handbean.Host.request_directory_picker(%{source: :web}) == :ok
    assert_receive {:directory_picker, %{source: :web}} = request

    # Listing the root runs under TaskSupervisor; the browser renders as
    # loading until the reply is dispatched.
    {:noreply, socket} = HomeScreen.handle_info(request, view.socket)
    loading = %{view | socket: socket}
    assert assigns(loading).page == :workspace
    assert %{mode: :browse, browser: %{loading?: true, entries: []}} = assigns(loading).workspaces
    assert text(loading) =~ gettext("Loading…")

    view = settle(loading)
    assert %{browser: %{loading?: false}} = assigns(view).workspaces
    refute text(view) =~ gettext("Loading…")
    assert "picker-fixture" in Enum.map(assigns(view).workspaces.browser.entries, & &1.name)
    assert text(view) =~ "picker-fixture"
  end

  test "directory picker is unavailable without a screen" do
    Application.put_env(:handbean_probe, :directory_picker_screen, :no_such_screen_process)
    on_exit(fn -> Application.delete_env(:handbean_probe, :directory_picker_screen) end)
    assert HandbeanProbe.DirectoryPicker.request_directory_picker(%{}) == {:error, :unavailable}
  end

  describe "mount locale" do
    setup do
      previous_env = Application.get_env(:handbean_probe, :locale)
      previous_locale = Gettext.get_locale()

      on_exit(fn ->
        if previous_env,
          do: Application.put_env(:handbean_probe, :locale, previous_env),
          else: Application.delete_env(:handbean_probe, :locale)

        Gettext.put_locale(previous_locale)
      end)

      :ok
    end

    test "defaults to zh_CN when nothing is configured" do
      Application.delete_env(:handbean_probe, :locale)
      view = settle(mount_screen(HomeScreen))
      assert Gettext.get_locale(HandbeanProbe.Gettext) == HandbeanProbe.Gettext.default_locale()

      assert text(view) =~
               Gettext.with_locale("zh_CN", fn -> gettext("Start a new conversation") end)
    end

    test "renders English when :locale is configured as en" do
      Application.put_env(:handbean_probe, :locale, "en")
      view = settle(mount_screen(HomeScreen))
      assert Gettext.get_locale(HandbeanProbe.Gettext) == "en"
      assert text(view) =~ "Start a new conversation"

      refute text(view) =~
               Gettext.with_locale("zh_CN", fn -> gettext("Start a new conversation") end)

      view = info(view, {:tap, {:page, :attachments}})
      assert text(view) =~ "Open in system browser"
    end

    test "unknown locale values fall back to the default" do
      Application.put_env(:handbean_probe, :locale, "fr")
      assert HandbeanProbe.Gettext.locale() == HandbeanProbe.Gettext.default_locale()
      Application.put_env(:handbean_probe, :locale, :en)
      assert HandbeanProbe.Gettext.locale() == "en"
      Application.put_env(:handbean_probe, :locale, "zh-CN")
      assert HandbeanProbe.Gettext.locale() == "zh_CN"
    end
  end

  # Full msgid; the notice is matched as a whole so translation edits stay in one place.
  defp send_failed,
    do: gettext("Send failed. Check the model configuration and network, then try again.")

  defp seed_input_models(view) do
    :ok =
      Handbean.Agent.ModelConfig.write_config(%{
        "defaultProvider" => "stepfun",
        "defaultModel" => "step-router-v1",
        "providers" => %{
          "stepfun" => %{
            "api" => "stepfun-step-plan",
            "apiKey" => "fixture-key",
            "baseUrl" => "https://example.invalid/v1",
            "models" => [
              %{"id" => "step-router-v1", "name" => "Step Router v1", "input" => ["text"]},
              %{
                "id" => "step-3.7-flash",
                "name" => "Step 3.7 Flash",
                "input" => ["text", "image"]
              }
            ]
          }
        }
      })

    models = ModelSettings.load(assigns(view).workspace)
    %{view | socket: Mob.Socket.assign(view.socket, :models, models)}
  end

  defmodule IOSAdapter do
    @behaviour HandbeanProbe.Platform.IOS.Adapter

    def open_url(url) do
      send(pid(), {:open_url, url})
      reply()
    end

    def share_text(text) do
      send(pid(), {:share_text, text})
      reply()
    end

    def pick_images do
      send(pid(), :pick_images)
      reply()
    end

    def present_file(path, mode) do
      send(pid(), {:present_file, path, mode})
      reply()
    end

    defp pid, do: Application.get_env(:handbean_probe, :ios_test_pid, self())
    defp reply, do: Application.get_env(:handbean_probe, :ios_adapter_reply, :ok)
  end

  defp install_platform_fake(fun) do
    Application.put_env(:handbean_probe, :platform_fake, fun)
    on_exit(fn -> Application.delete_env(:handbean_probe, :platform_fake) end)
  end

  # Isolated durable share FIFO for one test; removed from the env on exit.
  defp share_root!(prefix) do
    root = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    Application.put_env(:handbean_probe, :share_intake_root, root)
    on_exit(fn -> Application.delete_env(:handbean_probe, :share_intake_root) end)
    root
  end

  defp write_share_fixture!(id, rec) do
    dir = Path.join(HandbeanProbe.ShareIntake.root(), id)
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "manifest.json"),
      Jason.encode!(
        Map.merge(%{"intake_id" => id, "updated_at" => System.system_time(:millisecond)}, rec)
      )
    )
  end

  defp release_turn(turn) do
    assert_receive {:provider_turn, ^turn, provider}, 5_000
    send(provider, {:provider_continue, turn})
  end

  defp await_approval(runner, attempts \\ 100)
  defp await_approval(_, 0), do: flunk("Runner did not enter awaiting_approval")

  defp await_approval(runner, attempts) do
    if :sys.get_state(runner).status != :awaiting_approval do
      receive do
      after
        10 -> await_approval(runner, attempts - 1)
      end
    end
  end

  defp new_provider(workspace) do
    ModelSettings.action(:add_provider, ModelSettings.load(workspace), workspace)
    |> ModelSettings.change(:name, "test")
    |> ModelSettings.change(:base_url, "https://example.com/v1")
    |> ModelSettings.change(:api_key, "fixture-key-not-real")
  end

  defp new_model(workspace) do
    state =
      case ModelSettings.load(workspace) do
        %{providers: providers} = loaded ->
          if Enum.any?(providers, &(&1.id == "test")) do
            %{loaded | selected_provider: "test"}
          else
            ModelSettings.action(:save_provider, new_provider(workspace), workspace)
          end
      end

    state
    |> then(&ModelSettings.action({:select_provider, "test"}, &1, workspace))
    |> then(&ModelSettings.action(:add_model, &1, workspace))
    |> ModelSettings.change(:model, "native-model")
    |> ModelSettings.change(:name, "Native Model")
  end

  # Dispatch one message, then deliver every off-screen task reply it caused.
  defp composer_generation(view),
    do: PendingRequests.generation(assigns(view).pending_requests, :composer)

  defp info(view, message) do
    {:noreply, socket} = HomeScreen.handle_info(message, view.socket)
    settle(%{view | socket: socket})
  end

  defp notice_text(view), do: HandbeanProbe.HomeScreen.Notice.text(assigns(view).notice)

  defp write_native_models!(base_url) do
    assert :ok =
             Handbean.Agent.ModelConfig.write_config(%{
               "defaultProvider" => "fixture",
               "defaultModel" => "native-model",
               "providers" => %{
                 "fixture" => %{
                   "api" => "openai-chat-completions",
                   "apiKey" => "fixture-key",
                   "baseUrl" => base_url,
                   "models" => [%{"id" => "native-model", "name" => "Fixture"}]
                 }
               }
             })
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
