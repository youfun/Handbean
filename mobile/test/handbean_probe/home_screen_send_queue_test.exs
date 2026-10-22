defmodule HandbeanProbe.HomeScreenSendQueueTest do
  use HandbeanProbe.HomeScreenCase

  alias Handbean.PubSub.AgentEvent
  alias HandbeanWeb.WorkspaceHelper
  alias HandbeanProbe.HomeScreenCase.ProviderFixture
  alias HandbeanProbe.NativeChat

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

  test "standard native host rejects direct workspace commands before model or conversation creation",
       %{
         view: view
       } do
    view = info(view, {:change, :draft, "  !git status"})
    operation_id = assigns(view).workspace_command_intent.operation_id
    view = info(view, {:tap, :send})

    assert assigns(view).chat == nil
    assert assigns(view).draft == "  !git status"
    assert assigns(view).workspace_command_intent.operation_id == operation_id

    assert notice_text(view) =~
             gettext("Direct workspace commands are not supported on this device.")

    view = info(view, {:tap, :send})
    assert assigns(view).workspace_command_intent.operation_id == operation_id

    view = info(view, {:change, :draft, "!pwd"})
    assert assigns(view).workspace_command_intent.operation_id != operation_id

    assert Handbean.ConversationStore.list_for_workspace("default") == []
    refute_receive {:provider_request, _, _}, 50
  end

  test "failed first direct command send keeps its new conversation and operation id", %{
    view: view,
    dir: dir
  } do
    workspace_path = Path.join(dir, "direct-command-workspace")
    File.mkdir_p!(workspace_path)
    {:ok, workspace} = Handbean.WorkspaceStore.add(workspace_path, name: "Direct commands")
    view = info(view, {:tap, {:workspace, workspace["id"]}})

    host = Application.fetch_env!(:handbean, :host)
    Handbean.Host.put!(host |> Map.put(:shell, true) |> Map.put(:shell_isolation, :none))

    owner = self()

    executor = fn _command, _execution_context, _timeout ->
      send(owner, {:workspace_command_blocked, self()})

      receive do
        :finish -> {:ok, "finished", %{exit_code: 0}}
      end
    end

    conversation_ids =
      Enum.map(1..8, fn index ->
        {:ok, conversation} =
          Handbean.ConversationStore.create(assigns(view).workspace["id"],
            title: "Blocking command #{index}"
          )

        assert {:ok, %{state: :started}} =
                 Handbean.WorkspaceCommand.submit(conversation["id"], "blocking-#{index}",
                   operation_id: "native-blocking-#{index}",
                   executor: executor,
                   responder: fn _, _ -> {:ok, %{action: :started}} end
                 )

        conversation["id"]
      end)

    on_exit(fn -> Enum.each(conversation_ids, &Handbean.WorkspaceCommand.cancel/1) end)

    for _ <- 1..8, do: assert_receive({:workspace_command_blocked, _worker}, 1_000)

    view = info(view, {:change, :draft, "!pwd"})
    operation_id = assigns(view).workspace_command_intent.operation_id
    assert assigns(view).workspace_command_intent.conversation_id == nil

    view = info(view, {:tap, :send})
    conversation_id = assigns(view).chat.conversation["id"]

    assert assigns(view).draft == "!pwd"
    assert assigns(view).workspace_command_intent.operation_id == operation_id
    assert assigns(view).workspace_command_intent.conversation_id == conversation_id

    assert notice_text(view) =~
             gettext("A direct command is already running for this conversation.")

    assert length(Handbean.ConversationStore.list_for_workspace(assigns(view).workspace["id"])) ==
             9

    view = info(view, {:tap, :send})

    assert assigns(view).chat.conversation["id"] == conversation_id
    assert assigns(view).workspace_command_intent.operation_id == operation_id

    assert length(Handbean.ConversationStore.list_for_workspace(assigns(view).workspace["id"])) ==
             9
  end

  test "review generation does not reinterpret an exclamation draft as a direct command", %{
    view: view
  } do
    view =
      view
      |> info({:change, :draft, "!git status"})
      |> info({:change, :review_place, "Cafe"})
      |> info({:change, :review_feeling, "Quiet and bright"})
      |> info({:tap, :toggle_composer_mode})
      |> info({:tap, :generate_review})

    refute notice_text(view) =~
             gettext("Direct workspace commands are not supported on this device.")

    assert length(Handbean.ConversationStore.list_for_workspace("default")) == 1
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
end
