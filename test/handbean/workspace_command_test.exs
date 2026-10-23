defmodule Handbean.WorkspaceCommandTest do
  use Handbean.DataCase, async: false

  alias Handbean.{Attachments.History, ConversationStore, ConversationTranscriptStore}
  alias Handbean.Agent.{CandidateQueue, Message, OperationReceipt}
  alias Handbean.Agent.CliAgent.{Binding, Registry}
  alias Handbean.PubSub.Session
  alias Handbean.WorkspaceCommand
  alias Handbean.WorkspaceCommand.AgentResponse

  defmodule CommandCli do
    @behaviour Handbean.Agent.CliAgent

    alias Handbean.Agent.CliAgent.Session

    @impl true
    def id, do: "workspace-command-cli"

    @impl true
    def available?, do: true

    @impl true
    def list_models(_opts), do: {:ok, []}

    @impl true
    def capabilities, do: %{session_resume: true, streaming: true, interrupt: true}

    @impl true
    def start_session(opts) do
      {:ok,
       %Session{
         backend: id(),
         cwd: Keyword.fetch!(opts, :cwd),
         session_id: Keyword.get(opts, :session_id) || "command-cli-session"
       }}
    end

    @impl true
    def send_message(session, input, on_event) do
      if owner = Application.get_env(:handbean, :workspace_command_cli_test_owner) do
        send(owner, {:workspace_command_cli_input, input})

        if Application.get_env(:handbean, :workspace_command_cli_block?, false) do
          send(owner, {:workspace_command_cli_blocked, self()})

          receive do
            :release -> :ok
          end
        end
      end

      events = [
        {:text_delta, "CLI observed command result"},
        {:turn_end, %{stop_reason: :end_turn, session_id: session.session_id}}
      ]

      Enum.each(events, on_event)
      {:ok, session, events}
    end

    @impl true
    def interrupt(_session), do: :ok

    @impl true
    def update_model(session, _opts), do: {:ok, session}

    @impl true
    def stop_session(_session), do: :ok
  end

  setup do
    suffix = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "handbean_workspace_command_#{suffix}")
    storage = Path.join(root, "workspaces.json")
    workspace_path = Path.join(root, "workspace")
    File.mkdir_p!(workspace_path)

    previous_host = Application.fetch_env(:handbean, :host)
    previous_file = Application.fetch_env(:handbean, :workspaces_file)
    previous_env = System.get_env("HANDBEAN_WORKSPACES_FILE")

    Application.put_env(:handbean, :host, %{
      data_dir: root,
      shell: true,
      shell_isolation: :none
    })

    Application.put_env(:handbean, :workspaces_file, storage)
    System.put_env("HANDBEAN_WORKSPACES_FILE", storage)

    {:ok, workspace} = Handbean.WorkspaceStore.add(workspace_path, name: "Commands")
    {:ok, conversation} = ConversationStore.create(workspace["id"], title: "Command test")

    on_exit(fn ->
      restore_config(:host, previous_host)
      restore_config(:workspaces_file, previous_file)
      restore_env("HANDBEAN_WORKSPACES_FILE", previous_env)
      File.rm_rf!(root)
    end)

    {:ok, conversation: conversation, workspace_path: workspace_path}
  end

  test "parse reserves every leading exclamation message for direct commands" do
    assert :not_command = WorkspaceCommand.parse("git status")
    assert {:ok, "git status"} = WorkspaceCommand.parse("  !  git status  ")
    assert {:error, :empty_command} = WorkspaceCommand.parse("!")
    assert {:error, :empty_command} = WorkspaceCommand.parse("!   \n")
  end

  test "response recovery rejects a checkout owned by another workspace", context do
    other_path = Path.join(Path.dirname(context.workspace_path), "other-workspace")
    File.mkdir_p!(other_path)
    {:ok, _other_workspace} = Handbean.WorkspaceStore.add(other_path, name: "Other")

    {:ok, mismatched} =
      ConversationStore.create(context.conversation["workspace_id"],
        title: "Mismatched checkout",
        checkout_path: other_path
      )

    assert {:error, :not_workspace_conversation} =
             AgentResponse.deliver(mismatched["id"], %{"id" => "delayed-response"})

    assert Elixir.Registry.lookup(Handbean.AgentRunRegistry, mismatched["id"]) == []
  end

  test "persists both entries before executing in the conversation checkout", context do
    owner = self()

    executor = fn command, execution_context, _timeout ->
      entries = transcript(context.conversation["id"])
      send(owner, {:executed, command, execution_context, entries})
      {:ok, "clean\n", %{exit_code: 0, timed_out: false}}
    end

    responder = fn conversation_id, entry ->
      send(owner, {:response_admitted, entry, transcript(conversation_id)})
      {:ok, %{action: :started}}
    end

    assert {:ok, %{state: :started, entries: [user_entry, tool_entry]}} =
             WorkspaceCommand.submit(context.conversation["id"], "git status",
               operation_id: "persist-first",
               source: :test,
               executor: executor,
               responder: responder
             )

    assert user_entry["role"] == "user"
    assert user_entry["content"] == "!git status"
    assert user_entry["direct_command"] == true
    assert tool_entry["tool_status"] == "running"
    assert tool_entry["direct_command"] == true

    assert_receive {:executed, "git status", execution_context, persisted}, 1_000

    {:ok, canonical_workspace_path} =
      Handbean.RepoIdentity.canonical_directory(context.workspace_path)

    assert execution_context.working_directory == canonical_workspace_path
    assert Enum.map(persisted, & &1["id"]) == [user_entry["id"], tool_entry["id"]]

    assert eventually(fn ->
             [_, terminal] = transcript(context.conversation["id"])
             terminal["tool_status"] == "done" and terminal["output"] == "clean\n"
           end)

    assert_receive {:response_admitted, terminal, persisted_terminal}, 1_000
    assert terminal["tool_status"] == "done"
    assert Enum.at(persisted_terminal, 1)["agent_response_status"] == "pending"
  end

  test "a fixed operation id is idempotent and never replays", context do
    owner = self()

    executor = fn _command, _execution_context, _timeout ->
      send(owner, :executed_once)
      {:ok, "ok", %{exit_code: 0}}
    end

    responder = fn _conversation_id, _entry ->
      send(owner, :responded_once)
      {:ok, %{action: :started}}
    end

    opts = [
      operation_id: "same-operation",
      source: :test,
      executor: executor,
      responder: responder
    ]

    assert {:ok, %{state: :started}} =
             WorkspaceCommand.submit(context.conversation["id"], "pwd", opts)

    assert_receive :executed_once, 1_000
    assert_receive :responded_once, 1_000

    assert eventually(fn ->
             Enum.at(transcript(context.conversation["id"]), 1)["tool_status"] == "done"
           end)

    assert {:ok, %{state: :existing}} =
             WorkspaceCommand.submit(context.conversation["id"], "pwd", opts)

    assert {:error, :idempotency_conflict} =
             WorkspaceCommand.submit(context.conversation["id"], "whoami", opts)

    refute_receive :executed_once, 100
    refute_receive :responded_once, 100
    assert length(transcript(context.conversation["id"])) == 2
  end

  test "terminal persistence retries returned errors without replaying the command", context do
    owner = self()
    {counter, persister} = retrying_terminal_persister(:return_error)

    assert {:ok, %{state: :started}} =
             WorkspaceCommand.submit(context.conversation["id"], "pwd",
               operation_id: "retry-returned-error",
               executor: fn _, _, _ ->
                 send(owner, :executed_with_returned_error)
                 {:ok, "once", %{exit_code: 0}}
               end,
               terminal_persister: persister,
               responder: fn _, _ -> {:ok, %{action: :started}} end
             )

    assert_receive :executed_with_returned_error, 1_000

    assert eventually(fn ->
             terminal = Enum.at(transcript(context.conversation["id"]), 1)
             terminal["tool_status"] == "done" and terminal["output"] == "once"
           end)

    assert Agent.get(counter, & &1) == 2
    refute_receive :executed_with_returned_error, 100
  end

  test "terminal persistence retries raised exceptions without replaying the command", context do
    owner = self()
    {counter, persister} = retrying_terminal_persister(:raise)

    assert {:ok, %{state: :started}} =
             WorkspaceCommand.submit(context.conversation["id"], "pwd",
               operation_id: "retry-raised-error",
               executor: fn _, _, _ ->
                 send(owner, :executed_with_raised_error)
                 {:ok, "once", %{exit_code: 0}}
               end,
               terminal_persister: persister,
               responder: fn _, _ -> {:ok, %{action: :started}} end
             )

    assert_receive :executed_with_raised_error, 1_000

    assert eventually(fn ->
             terminal = Enum.at(transcript(context.conversation["id"]), 1)
             terminal["tool_status"] == "done" and terminal["output"] == "once"
           end)

    assert Agent.get(counter, & &1) == 2
    refute_receive :executed_with_raised_error, 100
  end

  test "a worker launch failure terminalizes the accepted intent without running the executor",
       context do
    owner = self()

    assert {:ok, %{state: :failed}} =
             WorkspaceCommand.submit(context.conversation["id"], "pwd",
               operation_id: "worker-start-failure",
               worker_starter: fn _fun -> raise "injected launch failure" end,
               executor: fn _, _, _ -> send(owner, :unexpected_executor) end,
               responder: fn _, _ -> {:ok, %{action: :started}} end
             )

    assert eventually(fn ->
             terminal = Enum.at(transcript(context.conversation["id"]), 1)

             terminal["tool_status"] == "error" and
               terminal["tool_error"] =~ "injected launch failure"
           end)

    refute_receive :unexpected_executor, 100
  end

  test "allows only one direct command per conversation", context do
    owner = self()

    executor = fn _command, _execution_context, _timeout ->
      send(owner, {:worker, self()})

      receive do
        :finish -> {:ok, "done", %{exit_code: 0}}
      end
    end

    assert {:ok, %{state: :started}} =
             WorkspaceCommand.submit(context.conversation["id"], "first",
               operation_id: "first-operation",
               executor: executor,
               responder: fn _, _ -> {:ok, %{action: :started}} end
             )

    assert_receive {:worker, worker}, 1_000

    assert {:error, :busy} =
             WorkspaceCommand.submit(context.conversation["id"], "second",
               operation_id: "second-operation",
               executor: executor
             )

    send(worker, :finish)

    assert eventually(fn ->
             Enum.at(transcript(context.conversation["id"]), 1)["tool_status"] == "done"
           end)
  end

  test "an Agent admission failure leaves the durable result pending for recovery", context do
    assert {:ok, %{state: :started}} =
             WorkspaceCommand.submit(context.conversation["id"], "pwd",
               operation_id: "pending-response",
               executor: fn _, _, _ -> {:ok, "workspace", %{exit_code: 0}} end,
               responder: fn _, _ -> {:error, :busy} end
             )

    assert eventually(fn ->
             terminal = Enum.at(transcript(context.conversation["id"]), 1)

             terminal["tool_status"] == "done" and
               terminal["agent_response_status"] == "pending" and
               terminal["agent_response_error"] == ":busy"
           end)

    assert {:ok, pending} =
             ConversationTranscriptStore.pending_workspace_command_responses()

    assert Enum.any?(pending, fn {conversation_id, entry} ->
             conversation_id == context.conversation["id"] and
               entry["id"] == "workspace-command-tool-pending-response"
           end)
  end

  test "a queue-full Agent delivery keeps its attempt id and recovers after capacity returns",
       context do
    conversation_id = context.conversation["id"]

    assert {:ok, _session} = Session.start_or_get(session_id: conversation_id)

    assert {:ok, queue} =
             CandidateQueue.start_link(session_id: conversation_id, owner: self(), max_size: 1)

    assert :ok = Session.attach_run(conversation_id, self(), queue, run_id: "capacity-run")
    assert :ok = CandidateQueue.enqueue(queue, "occupied", deliver_as: :follow_up)

    on_exit(fn ->
      if Process.alive?(queue), do: GenServer.stop(queue)
      Handbean.SessionSupervisor.stop_session(conversation_id)
    end)

    request_id = "crashed-reserved-response-attempt"

    assert {:ok, entry} =
             ConversationTranscriptStore.append(conversation_id, %{
               "id" => "capacity-response-result",
               "role" => "tool",
               "content_type" => "tool",
               "tool_name" => "bash",
               "tool_status" => "done",
               "input" => %{"command" => "pwd"},
               "output" => context.workspace_path,
               "details" => %{"exit_code" => 0},
               "direct_command" => true,
               "command_operation_id" => "capacity-response-operation",
               "consumption" => "pending",
               "agent_response_status" => "pending",
               "agent_response_request_id" => request_id
             })

    message = %Message{
      role: :user,
      content: AgentResponse.observation(entry),
      id: entry["id"]
    }

    fingerprint = OperationReceipt.fingerprint({conversation_id, message, :follow_up})
    assert :ok = OperationReceipt.reserve({:message, conversation_id}, request_id, fingerprint)

    send(Process.whereis(WorkspaceCommand), :recover_agent_responses)

    assert eventually(fn ->
             entry =
               transcript(conversation_id)
               |> Enum.find(&(&1["id"] == "capacity-response-result"))

             is_binary(entry["agent_response_request_id"]) and
               entry["agent_response_status"] == "pending" and
               entry["agent_response_error"] == ":queue_full"
           end)

    pending_entry =
      transcript(conversation_id)
      |> Enum.find(&(&1["id"] == "capacity-response-result"))

    assert pending_entry["agent_response_request_id"] == request_id
    assert :error = OperationReceipt.lookup({:message, conversation_id}, request_id)
    assert [_occupied] = CandidateQueue.drain_follow_up(queue)

    send(Process.whereis(WorkspaceCommand), :recover_agent_responses)

    assert eventually(fn ->
             entry =
               transcript(conversation_id)
               |> Enum.find(&(&1["id"] == "capacity-response-result"))

             entry["agent_response_request_id"] == request_id and
               entry["agent_response_status"] == "accepted"
           end)

    assert {:ok, %{"status" => "completed", "receipt" => receipt}} =
             OperationReceipt.lookup({:message, conversation_id}, request_id)

    assert Handbean.Utils.SafeMap.get_any(receipt, "run_id", :run_id) == "capacity-run"

    assert [queued] = CandidateQueue.get_messages(queue)
    assert queued.message.id == "capacity-response-result"

    assert :ok =
             CandidateQueue.enqueue(queue, queued.message,
               deliver_as: :follow_up,
               request_id: request_id,
               run_id: "capacity-run"
             )

    assert [duplicate_guarded] = CandidateQueue.get_messages(queue)
    assert duplicate_guarded.message.id == "capacity-response-result"
  end

  test "recovery redelivers a receipt accepted by an older run to the current run", context do
    conversation_id = context.conversation["id"]
    old_request_id = "old-run-response-attempt"

    assert :ok =
             OperationReceipt.reserve(
               {:message, conversation_id},
               old_request_id,
               "old-run-fixture"
             )

    assert :ok =
             OperationReceipt.complete(
               {:message, conversation_id},
               old_request_id,
               %{action: :enqueued, run_id: "run-a"}
             )

    assert {:ok, _entry} =
             ConversationTranscriptStore.append(conversation_id, %{
               "id" => "old-run-response-result",
               "role" => "tool",
               "content_type" => "tool",
               "tool_name" => "bash",
               "tool_status" => "done",
               "input" => %{"command" => "pwd"},
               "output" => context.workspace_path,
               "details" => %{"exit_code" => 0},
               "direct_command" => true,
               "command_operation_id" => "old-run-response-operation",
               "consumption" => "pending",
               "agent_response_status" => "accepted",
               "agent_response_request_id" => old_request_id
             })

    assert {:ok, _session} = Session.start_or_get(session_id: conversation_id)
    assert {:ok, queue} = CandidateQueue.start_link(session_id: conversation_id, owner: self())
    assert :ok = Session.attach_run(conversation_id, self(), queue, run_id: "run-b")

    on_exit(fn ->
      if Process.alive?(queue), do: GenServer.stop(queue)
      Handbean.SessionSupervisor.stop_session(conversation_id)
    end)

    send(Process.whereis(WorkspaceCommand), :recover_agent_responses)

    assert eventually(fn ->
             entry =
               transcript(conversation_id)
               |> Enum.find(&(&1["id"] == "old-run-response-result"))

             is_binary(entry["agent_response_request_id"]) and
               entry["agent_response_request_id"] != old_request_id and
               entry["agent_response_status"] == "accepted"
           end)

    entry =
      transcript(conversation_id)
      |> Enum.find(&(&1["id"] == "old-run-response-result"))

    assert {:ok, %{"status" => "completed", "receipt" => receipt}} =
             OperationReceipt.lookup(
               {:message, conversation_id},
               entry["agent_response_request_id"]
             )

    assert Handbean.Utils.SafeMap.get_any(receipt, "run_id", :run_id) == "run-b"
    assert Enum.any?(CandidateQueue.get_messages(queue), &(&1.message.id == entry["id"]))
  end

  test "a consumed direct observation cannot be claimed by response recovery", context do
    conversation_id = context.conversation["id"]

    assert {:ok, entry} =
             ConversationTranscriptStore.append(conversation_id, %{
               "id" => "consumed-before-response-recovery",
               "role" => "tool",
               "content_type" => "tool",
               "tool_name" => "bash",
               "tool_status" => "done",
               "direct_command" => true,
               "consumption" => "pending",
               "agent_response_status" => "pending"
             })

    assert {:ok, claimed} =
             ConversationTranscriptStore.claim_workspace_command_response(
               conversation_id,
               entry["id"],
               "first-response-attempt"
             )

    assert claimed["agent_response_request_id"] == "first-response-attempt"

    assert :ok =
             ConversationTranscriptStore.consume(
               conversation_id,
               [entry["id"]],
               %{"consumption" => "consumed", "consumed_run_id" => "completed-run"}
             )

    assert {:error, :already_consumed} =
             ConversationTranscriptStore.claim_workspace_command_response(
               conversation_id,
               entry["id"],
               "duplicate-response-attempt"
             )
  end

  test "cold recovery restores the durable CLI owner and consumes its direct observation",
       context do
    conversation_id = context.conversation["id"]
    previous_session_store_enabled = Application.fetch_env(:handbean, :session_store_enabled?)
    Application.put_env(:handbean, :session_store_enabled?, true)
    :ok = Registry.register(CommandCli)
    Application.put_env(:handbean, :workspace_command_cli_test_owner, self())

    on_exit(fn ->
      Registry.reset()
      restore_config(:session_store_enabled?, previous_session_store_enabled)
      Application.delete_env(:handbean, :workspace_command_cli_test_owner)
    end)

    binding =
      Binding.put(conversation_id, %{
        backend: CommandCli.id(),
        session_id: "persisted-command-cli-session",
        cwd: context.workspace_path,
        model: "cli-model",
        reasoning_effort: "high"
      })

    assert binding.backend == CommandCli.id()
    session_pid = Handbean.PubSub.Session.whereis(conversation_id)
    assert is_pid(session_pid)
    assert Handbean.PubSub.Session.snapshot(conversation_id).extension_state != %{}

    ref = Process.monitor(session_pid)
    Process.exit(session_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^session_pid, _reason}, 1_000
    assert Binding.get(conversation_id) == nil

    {:ok, entry} =
      ConversationTranscriptStore.append(conversation_id, %{
        "id" => "cold-cli-direct-result",
        "role" => "tool",
        "content_type" => "tool",
        "tool_name" => "bash",
        "tool_status" => "done",
        "input" => %{"command" => "pwd"},
        "output" => context.workspace_path,
        "details" => %{"exit_code" => 0},
        "direct_command" => true,
        "command_operation_id" => "cold-cli-operation",
        "consumption" => "pending",
        "agent_response_status" => "pending"
      })

    assert {:ok, %{action: :started}} = AgentResponse.deliver(conversation_id, entry)

    assert_receive {:workspace_command_cli_input, message}, 1_000
    assert message.content =~ "The user directly executed a workspace command"

    assert eventually(fn ->
             terminal =
               transcript(conversation_id)
               |> Enum.find(&(&1["id"] == "cold-cli-direct-result"))

             terminal["consumption"] == "consumed"
           end)

    assert eventually(fn -> match?(%{status: :idle}, Binding.get(conversation_id)) end)
    assert :ok = Handbean.SessionSupervisor.stop_session(conversation_id)
  end

  test "CLI new-run request identity suppresses the same observation as a racing follow-up",
       context do
    conversation_id = context.conversation["id"]
    request_id = "cli-initial-request"
    entry_id = "cli-initial-entry"
    :ok = Registry.register(CommandCli)
    Application.put_env(:handbean, :workspace_command_cli_test_owner, self())
    Application.put_env(:handbean, :workspace_command_cli_block?, true)

    on_exit(fn ->
      Registry.reset()
      Application.delete_env(:handbean, :workspace_command_cli_test_owner)
      Application.delete_env(:handbean, :workspace_command_cli_block?)
    end)

    Binding.put(conversation_id, %{
      backend: CommandCli.id(),
      session_id: "initial-dedupe-cli-session",
      cwd: context.workspace_path,
      model: "cli-model",
      reasoning_effort: "high"
    })

    {:ok, entry} =
      ConversationTranscriptStore.append(conversation_id, %{
        "id" => entry_id,
        "role" => "tool",
        "content_type" => "tool",
        "tool_name" => "bash",
        "tool_status" => "done",
        "input" => %{"command" => "pwd"},
        "output" => context.workspace_path,
        "details" => %{"exit_code" => 0},
        "direct_command" => true,
        "command_operation_id" => "cli-initial-operation",
        "agent_response_request_id" => request_id,
        "consumption" => "pending",
        "agent_response_status" => "pending"
      })

    assert {:ok, %{action: :started, run_id: run_id}} =
             AgentResponse.deliver(conversation_id, entry)

    assert_receive {:workspace_command_cli_blocked, cli_task}, 1_000

    assert {:ok, %{queue_pid: queue_pid}} = Handbean.Agent.Runner.status(conversation_id)

    assert :ok =
             CandidateQueue.enqueue(queue_pid, AgentResponse.observation(entry),
               request_id: request_id,
               message_id: entry_id,
               run_id: run_id,
               deliver_as: :follow_up,
               persist_candidate?: false
             )

    assert [] = CandidateQueue.drain_follow_up(queue_pid)
    send(cli_task, :release)
    assert eventually(fn -> match?(%{status: :idle}, Binding.get(conversation_id)) end)
    assert :ok = Handbean.SessionSupervisor.stop_session(conversation_id)
  end

  test "conversation deletion stops a running direct command without invoking its responder",
       context do
    owner = self()

    executor = fn _command, _execution_context, _timeout ->
      send(owner, {:deletion_worker, self()})

      receive do
        :never -> {:ok, "unexpected", %{exit_code: 0}}
      end
    end

    assert {:ok, %{state: :started}} =
             WorkspaceCommand.submit(context.conversation["id"], "long-running",
               operation_id: "delete-operation",
               executor: executor,
               responder: fn _, _ -> send(owner, :unexpected_response) end
             )

    assert_receive {:deletion_worker, worker}, 1_000
    ref = Process.monitor(worker)

    assert {:ok, [conversation_id]} =
             ConversationStore.request_delete(context.conversation["id"])

    assert conversation_id == context.conversation["id"]
    assert_receive {:DOWN, ^ref, :process, ^worker, _reason}, 1_000
    refute WorkspaceCommand.active?(conversation_id)
    refute_receive :unexpected_response, 50
  end

  test "unsupported hosts reject without persisting or invoking an executor", context do
    owner = self()
    host = Application.fetch_env!(:handbean, :host)
    Application.put_env(:handbean, :host, Map.put(host, :shell, false))

    assert {:error, :not_available} =
             WorkspaceCommand.submit(context.conversation["id"], "pwd",
               executor: fn _, _, _ -> send(owner, :unexpected_execution) end
             )

    refute_receive :unexpected_execution, 50
    assert transcript(context.conversation["id"]) == []
  end

  test "free conversations reject without persisting or invoking the model path" do
    {:ok, conversation} = ConversationStore.create_free(title: "Free")

    assert {:error, :not_workspace_conversation} =
             WorkspaceCommand.submit(conversation["id"], "pwd",
               executor: fn _, _, _ -> flunk("executor must not run") end
             )

    assert transcript(conversation["id"]) == []
  end

  test "recovery excludes direct commands from Agent runs and terminalizes them without replay",
       context do
    conversation_id = context.conversation["id"]

    {:ok, [_user, tool]} =
      ConversationTranscriptStore.append_many(conversation_id, [
        %{
          "id" => "recovery-user",
          "role" => "user",
          "content_type" => "user_msg",
          "content" => "!touch marker",
          "direct_command" => true
        },
        %{
          "id" => "recovery-tool",
          "role" => "tool",
          "content_type" => "tool",
          "tool_name" => "bash",
          "tool_status" => "running",
          "input" => %{"command" => "touch marker"},
          "direct_command" => true
        }
      ])

    refute Enum.any?(
             Handbean.ConversationTranscriptStore.ConversationStore.unfinished_runs(),
             fn {unfinished_conversation_id, _run_id} ->
               unfinished_conversation_id == conversation_id
             end
           )

    assert {:ok, [^conversation_id]} =
             ConversationTranscriptStore.interrupt_workspace_commands("interrupted for restart")

    terminal = Enum.find(transcript(conversation_id), &(&1["id"] == tool["id"]))
    assert terminal["tool_status"] == "error"
    assert terminal["tool_error"] == "interrupted for restart"
  end

  test "model history hides running records and restores one labeled terminal observation",
       context do
    conversation_id = context.conversation["id"]

    {:ok, [_, tool_entry]} =
      ConversationTranscriptStore.append_many(conversation_id, [
        %{
          "id" => "history-user",
          "role" => "user",
          "content_type" => "message",
          "content" => "!pwd",
          "direct_command" => true
        },
        %{
          "id" => "history-tool",
          "role" => "tool",
          "content_type" => "tool",
          "tool_name" => "bash",
          "tool_status" => "running",
          "input" => %{"command" => "pwd"},
          "direct_command" => true
        }
      ])

    assert History.to_messages(
             transcript(conversation_id),
             context.workspace_path,
             conversation_id
           ) == []

    {:ok, _} =
      ConversationTranscriptStore.update(conversation_id, tool_entry["id"], %{
        "tool_status" => "done",
        "output" => context.workspace_path,
        "details" => %{"exit_code" => 0}
      })

    assert [message] =
             History.to_messages(
               transcript(conversation_id),
               context.workspace_path,
               conversation_id
             )

    assert message.role == :user
    assert message.content =~ "The user directly executed a workspace command"
    assert message.content =~ "Command: pwd"
    assert message.content =~ context.workspace_path
  end

  defp retrying_terminal_persister(first_failure) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    persister = fn conversation_id, operation_id, _result, duration ->
      attempt = Agent.get_and_update(counter, fn value -> {value + 1, value + 1} end)

      case {first_failure, attempt} do
        {:return_error, 1} ->
          {:error, :injected}

        {:raise, 1} ->
          raise "injected transcript failure"

        _ ->
          ConversationTranscriptStore.update(
            conversation_id,
            "workspace-command-tool-#{operation_id}",
            %{
              "tool_status" => "done",
              "tool_error" => nil,
              "output" => "once",
              "details" => %{"exit_code" => 0},
              "consumption" => "pending",
              "agent_response_status" => "pending",
              "tool_duration_ms" => duration,
              "completed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
            }
          )
      end
    end

    {counter, persister}
  end

  defp transcript(conversation_id) do
    {:ok, entries} = ConversationTranscriptStore.list(conversation_id)
    entries
  end

  defp eventually(fun, attempts \\ 40)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      receive do
      after
        10 -> eventually(fun, attempts - 1)
      end
    end
  end

  defp eventually(_fun, 0), do: false

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp restore_config(key, {:ok, value}), do: Application.put_env(:handbean, key, value)
  defp restore_config(key, :error), do: Application.delete_env(:handbean, key)
end
