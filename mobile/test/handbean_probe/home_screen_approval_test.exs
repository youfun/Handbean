defmodule HandbeanProbe.HomeScreenApprovalTest do
  use HandbeanProbe.HomeScreenCase

  alias Handbean.PubSub.AgentEvent
  alias HandbeanProbe.{HomeScreen, NativeApproval}
  alias HandbeanProbe.HomeScreenCase.{ApprovalFileProvider, ApprovalProvider}

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

    {:ok, conversation} =
      Handbean.ConversationStore.create("default", permission_mode: "prompt")

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

      {:ok, c} =
        Handbean.ConversationStore.create("default", permission_mode: "prompt")

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

  test "always-allow resume fails closed when workspace rules become unreadable", %{view: view} do
    workspace = assigns(view).workspace
    path = workspace["path"]
    File.mkdir_p!(Path.join(path, ".handbean"))
    settings_path = Handbean.WorkspaceSettings.path(path)
    original = Jason.encode!(%{"tools" => %{"default_mode" => "prompt"}})
    File.write!(settings_path, original)

    {:ok, c} = Handbean.ConversationStore.create("default", permission_mode: "prompt")
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
    refute File.exists?(Path.join(path, "approval.txt"))
    File.write!(settings_path, original)
  end

  test "decide rejects a missing pending approval" do
    chat = %{conversation: %{"id" => "unused"}, pending_approval: nil}

    assert NativeApproval.decide(chat, %{"path" => "/tmp"}, :approve, :once) ==
             {:error, :not_awaiting_approval}
  end

  test "permission selector persists the current conversation and reloads on mount", %{view: view} do
    view =
      case assigns(view).chat do
        %{conversation: %{"id" => _id}} ->
          view

        _no_conversation ->
          workspace_id = assigns(view).workspace["id"]
          {:ok, conversation} = Handbean.ConversationStore.create(workspace_id)
          info(view, {:tap, {:conversation, conversation["id"]}})
      end

    conversation_id = assigns(view).chat.conversation["id"]
    workspace_path = assigns(view).workspace["path"]
    {:ok, original_settings} = Handbean.WorkspaceSettings.load(workspace_path)

    view = info(view, {:tap, {:page, :permissions}})
    assert text(view) =~ gettext("Tool permissions")
    assert text(view) =~ gettext("Smart approval")
    refute text(view) =~ "Full access"
    view = info(view, {:tap, {:permission_mode, :prompt}})
    assert assigns(view).page == :chat
    assert assigns(view).permission_mode == :prompt
    assert assigns(mount_screen(HomeScreen)).permission_mode == :prompt

    assert {:ok, metadata} = Handbean.ConversationStore.get_metadata(conversation_id)
    assert metadata["permission_mode"] == "prompt"
    assert {:ok, ^original_settings} = Handbean.WorkspaceSettings.load(workspace_path)

    view = info(view, {:tap, {:permission_mode, :yolo}})
    assert assigns(view).permission_mode == :yolo

    view = info(view, {:tap, {:permission_mode, :auto_review}})
    assert assigns(view).permission_mode == :auto_review
    assert assigns(mount_screen(HomeScreen)).permission_mode == :auto_review
    assert {:ok, metadata} = Handbean.ConversationStore.get_metadata(conversation_id)
    assert metadata["permission_mode"] == "auto_review"
    assert {:ok, ^original_settings} = Handbean.WorkspaceSettings.load(workspace_path)

    view =
      info(
        view,
        {:conversation_permission_mode_changed, conversation_id, :prompt, nil, 0}
      )

    assert assigns(view).permission_mode == :auto_review
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

    {:ok, conversation} =
      Handbean.ConversationStore.create("default", permission_mode: "prompt")

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
end
