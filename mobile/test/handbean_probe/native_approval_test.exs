defmodule HandbeanProbe.NativeApprovalTest do
  @moduledoc """
  `NativeApproval.decide/4` against a real Runner in `awaiting_approval`.

  The screen-level flow lives in `home_screen_test.exs`; this file holds the
  behaviour guards from the tech-debt plan (WP1 / WP4).
  """

  use ExUnit.Case, async: false

  alias Handbean.Agent.Coordinator
  alias Handbean.ConversationTranscriptStore
  alias Handbean.PubSub.Session
  alias HandbeanProbe.{NativeApproval, NativeChat}

  @source Path.expand("../../lib/handbean_probe/native_approval.ex", __DIR__)

  defmodule ApprovalProvider do
    @behaviour Handbean.Agent.Provider
    alias Handbean.Agent.Message

    def complete(messages, _tools, _config) do
      if Enum.any?(messages, &(&1.role == :tool_result)) do
        {:ok,
         %{
           stop_reason: :end_turn,
           messages: [Message.assistant("approval finished")],
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
                 id: "approval-0",
                 name: "write",
                 input: %{"file_path" => "approval.txt", "content" => "write-0"}
               }
             ])
           ],
           usage: %{input_tokens: 1, output_tokens: 1}
         }}
      end
    end

    def stream(messages, tools, config, _callback), do: complete(messages, tools, config)
  end

  setup do
    path =
      Path.join(System.tmp_dir!(), "native_approval_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(path, ".handbean"))
    previous_host = Application.get_env(:handbean, :host)
    previous_home = System.get_env("HOME")
    Handbean.Host.put!(%{data_dir: path, shell: false, mcp: false})
    System.put_env("HOME", path)

    {:ok, workspace} = Handbean.WorkspaceStore.add(path, name: "Approval fixture")

    File.write!(
      Handbean.WorkspaceSettings.path(path),
      Jason.encode!(%{"tools" => %{"default_mode" => "prompt"}})
    )

    {:ok, conversation} =
      Handbean.ConversationStore.create(workspace["id"], permission_mode: "prompt")

    id = conversation["id"]
    :ok = Session.subscribe(id)

    {:ok, %{run_pid: runner}} =
      Coordinator.add_message(id, "approval fixture",
        provider: ApprovalProvider,
        provider_config: %{},
        source: :native,
        model: "fixture",
        streaming: false,
        workspace_path: path,
        tools: [Handbean.Tool.Builtin.Write],
        max_turns: 4
      )

    on_exit(fn ->
      Coordinator.cancel(id)
      HandbeanProbe.RuntimeCleanup.stop!()

      if previous_host,
        do: Application.put_env(:handbean, :host, previous_host),
        else: Application.delete_env(:handbean, :host)

      if previous_home, do: System.put_env("HOME", previous_home), else: System.delete_env("HOME")
      File.rm_rf(path)
    end)

    assert_receive {:agent_event, %{kind: :tool_approval_requested}}, 5_000
    await_approval(runner)

    chat = NativeChat.load(conversation)
    assert chat.pending_approval
    assert is_integer(chat.approval_seq)

    %{chat: chat, workspace: workspace, path: path}
  end

  test "deny/once resumes the Runner without writing the file", %{
    chat: chat,
    workspace: workspace,
    path: path
  } do
    assert :ok = NativeApproval.decide(chat, workspace, :deny, :once)

    assert_receive {:agent_event,
                    %{kind: :message_delta, payload: %{chunk: "approval finished"}}},
                   5_000

    refute File.exists?(Path.join(path, "approval.txt"))
  end

  # WP1/WP4 behaviour guard: `decide/4` must not reload the whole transcript.
  # The merge that reintroduced the reload is the reason this file exists.
  # `decide/4` runs in the caller, so a call trace on this process catches any
  # transcript loader it reaches for, whether or not it is spelled `NativeChat.load`.
  test "decide/4 does not reload the transcript through NativeChat.load", %{
    chat: chat,
    workspace: workspace
  } do
    refute File.read!(@source) =~ "NativeChat.load",
           "native_approval.ex must not call NativeChat.load (WP4)"

    # Positive control: the trace must see a real reload, or the guard is void.
    transcript_loaders = [
      {NativeChat, :load, :_},
      {ConversationTranscriptStore, :list, :_},
      {Handbean.ConversationStore, :load_messages, :_},
      {Handbean.ConversationStore, :load_messages_result, :_}
    ]

    assert [{NativeChat, :load, _} | _] =
             traced_calls(transcript_loaders, fn -> NativeChat.load(chat.conversation) end)

    calls =
      traced_calls(transcript_loaders, fn ->
        assert :ok = NativeApproval.decide(chat, workspace, :deny, :once)
      end)

    assert calls == [], "decide/4 reloaded transcript state: #{inspect(calls)}"
  end

  test "decide/4 refuses when the Runner is no longer awaiting approval", %{
    chat: chat,
    workspace: workspace,
    path: path
  } do
    assert :ok = NativeApproval.decide(chat, workspace, :deny, :once)

    assert_receive {:agent_event,
                    %{kind: :message_delta, payload: %{chunk: "approval finished"}}},
                   5_000

    # The screen still holds the old pending batch; the Runner has moved on.
    assert {:error, :not_awaiting_approval} =
             NativeApproval.decide(chat, workspace, :approve, :always)

    {:ok, settings} = Handbean.WorkspaceSettings.load(path)
    refute "write(approval.txt)" in (settings["tools"]["allow"] || [])
  end

  test "decide/4 remembers the rule only after the Runner resumed", %{
    chat: chat,
    workspace: workspace,
    path: path
  } do
    assert :ok = NativeApproval.decide(chat, workspace, :approve, :always)

    {:ok, settings} = Handbean.WorkspaceSettings.load(path)
    assert "write(approval.txt)" in settings["tools"]["allow"]

    assert_receive {:agent_event,
                    %{kind: :message_delta, payload: %{chunk: "approval finished"}}},
                   5_000

    assert File.read!(Path.join(path, "approval.txt")) == "write-0"
  end

  test "decide/4 reports rule_not_saved when the workspace rule cannot be written", %{
    chat: chat,
    path: path
  } do
    # A regular file where the workspace root should be: `.handbean/` cannot be created.
    blocker = Path.join(path, "blocker")
    File.write!(blocker, "")

    assert {:ok, :rule_not_saved} =
             NativeApproval.decide(chat, %{"path" => blocker}, :deny, :always)

    assert_receive {:agent_event,
                    %{kind: :message_delta, payload: %{chunk: "approval finished"}}},
                   5_000

    refute File.exists?(Path.join(path, "approval.txt"))
  end

  describe "render/3 for an Android-only batch" do
    @android_batch %{
      conversation: %{"id" => "conv-android"},
      approval_seq: 7,
      pending_approval: %{
        "action_requests" => [
          %{
            "tool_call_id" => "a1",
            "tool_name" => "open_url",
            "arguments" => %{"url" => "https://example.com"}
          }
        ]
      }
    }

    test "offers session and always scopes like every other tool" do
      tags = approval_tags(NativeApproval.render(@android_batch, nil))

      assert {:approval, "conv-android", 7, :deny, :once} in tags
      assert {:approval, "conv-android", 7, :deny, :always} in tags
      assert {:approval, "conv-android", 7, :approve, :once} in tags
      assert {:approval, "conv-android", 7, :approve, :session} in tags
      assert {:approval, "conv-android", 7, :approve, :always} in tags
    end

    test "hides allow scopes until file snapshots are pinned" do
      pending = %{
        "action_requests" => [
          %{"tool_call_id" => "f1", "tool_name" => "share_file", "arguments" => %{}}
        ]
      }

      chat = %{@android_batch | pending_approval: pending}

      not_ready = approval_tags(NativeApproval.render(chat, nil, %{}))
      refute Enum.any?(not_ready, &match?({:approval, _, _, :approve, _}, &1))
      assert {:approval, "conv-android", 7, :deny, :always} in not_ready

      ready = approval_tags(NativeApproval.render(chat, nil, %{"f1" => %{snapshot_id: "s1"}}))
      assert {:approval, "conv-android", 7, :approve, :session} in ready
      assert {:approval, "conv-android", 7, :approve, :always} in ready
    end

    defp approval_tags(node) do
      node
      |> nodes()
      |> Enum.flat_map(fn %{props: props} ->
        case props[:on_tap] do
          {_pid, {:approval, _, _, _, _} = tag} -> [tag]
          _ -> []
        end
      end)
    end

    defp nodes(%{children: children} = node), do: [node | Enum.flat_map(children, &nodes/1)]
    defp nodes(_), do: []
  end

  # WP2: android_* tools must honor remembered approvals like every other tool.
  defmodule AndroidOpenUrlProvider do
    @behaviour Handbean.Agent.Provider
    alias Handbean.Agent.Message

    def complete(messages, _tools, _config) do
      if Enum.any?(messages, &(&1.role == :tool_result)) do
        {:ok,
         %{
           stop_reason: :end_turn,
           messages: [Message.assistant("android finished")],
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
                 id: "android-open-0",
                 name: "open_url",
                 input: %{"url" => "https://example.com/doc"}
               }
             ])
           ],
           usage: %{input_tokens: 1, output_tokens: 1}
         }}
      end
    end

    def stream(messages, tools, config, _callback), do: complete(messages, tools, config)
  end

  describe "remembered android approvals feed ToolPolicy" do
    alias Handbean.Permissions.ToolPolicy

    @android_call %{
      id: "android-open-1",
      name: "open_url",
      input: %{"url" => "https://example.com/doc"}
    }

    setup %{path: path, workspace: workspace} do
      # Full access: the strongest case — the intent still asks until remembered.
      File.write!(
        Handbean.WorkspaceSettings.path(path),
        Jason.encode!(%{"tools" => %{"default_mode" => "auto"}})
      )

      {:ok, conversation} =
        Handbean.ConversationStore.create(workspace["id"], permission_mode: "prompt")

      id = conversation["id"]
      :ok = Session.subscribe(id)

      {:ok, %{run_pid: runner}} =
        Coordinator.add_message(id, "open the doc",
          provider: AndroidOpenUrlProvider,
          provider_config: %{},
          source: :native,
          model: "fixture",
          streaming: false,
          workspace_path: path,
          tools: [Handbean.Tool.Builtin.OpenUrl],
          max_turns: 3
        )

      on_exit(fn -> Coordinator.cancel(id) end)

      assert_receive {:agent_event, %{kind: :tool_approval_requested, payload: payload}}, 5_000

      assert [request] = payload[:action_requests] || payload["action_requests"]
      assert (request[:tool_name] || request["tool_name"]) == "open_url"
      await_approval(runner)

      android_chat = NativeChat.load(conversation)
      assert android_chat.pending_approval

      %{android_chat: android_chat}
    end

    test "decide/4 :always makes the same android tool auto on the next call", %{
      android_chat: chat,
      workspace: workspace,
      path: path
    } do
      assert ToolPolicy.from_workspace(path) |> ToolPolicy.decision(@android_call) == :prompt

      assert NativeApproval.decide(chat, workspace, :approve, :always) == :ok

      {:ok, settings} = Handbean.WorkspaceSettings.load(path)
      assert "open_url" in settings["tools"]["allow"]

      assert ToolPolicy.from_workspace(path) |> ToolPolicy.decision(@android_call) == :auto

      # Only the approved tool is remembered; sibling intents keep asking.
      assert ToolPolicy.from_workspace(path)
             |> ToolPolicy.decision(%{id: "f1", name: "open_file", input: %{}}) ==
               :prompt

      assert_receive {:agent_event,
                      %{kind: :message_delta, payload: %{chunk: "android finished"}}},
                     5_000
    end

    test "workspace allow rule also unlocks android intents in safe mode", %{path: path} do
      File.write!(
        Handbean.WorkspaceSettings.path(path),
        Jason.encode!(%{"tools" => %{"default_mode" => "prompt"}})
      )

      call = %{id: "s1", name: "share_file", input: %{"path" => "a.pdf"}}
      assert ToolPolicy.from_workspace(path) |> ToolPolicy.decision(call) == :prompt

      assert :ok = Handbean.WorkspaceSettings.append_tool_rule(path, :allow, "share_file")
      assert ToolPolicy.from_workspace(path) |> ToolPolicy.decision(call) == :auto
    end
  end

  # Runs `fun` in the test process with call tracing on `modules`. A process
  # cannot be its own tracer, so a collector receives the trace messages and
  # hands back the `{module, function, args}` calls once `fun` returns.
  defp traced_calls(targets, fun) do
    me = self()

    collector =
      spawn_link(fn ->
        collect = fn collect, acc ->
          receive do
            {:flush, from} -> send(from, {:traced_calls, Enum.reverse(acc)})
            {:trace, ^me, :call, mfa} -> collect.(collect, [mfa | acc])
            _ -> collect.(collect, acc)
          end
        end

        collect.(collect, [])
      end)

    Enum.each(targets, &:erlang.trace_pattern(&1, true, [:local]))
    :erlang.trace(me, true, [:call, {:tracer, collector}])

    try do
      fun.()
    after
      :erlang.trace(me, false, [:call])
      Enum.each(targets, &:erlang.trace_pattern(&1, false, [:local]))
    end

    send(collector, {:flush, me})
    assert_receive {:traced_calls, calls}
    calls
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
end
