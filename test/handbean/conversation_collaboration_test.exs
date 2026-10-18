defmodule Handbean.ConversationCollaborationTest do
  use Handbean.DataCase, async: false
  alias Handbean.{ConversationStore, ConversationTranscriptStore, Conversations}
  alias Handbean.Conversations.Collaboration

  defmodule FailingInboundStore do
    def append(_conversation_id, _entry, _opts), do: {:error, :eisdir}
  end

  defmodule CaptureProvider do
    @behaviour Handbean.Agent.Provider

    def complete(_messages, _tools, config) do
      if pid = Process.whereis(:conversation_model_capture),
        do: send(pid, {:captured, config, self()})

      receive do
        :release -> :ok
      end

      {:ok,
       %{
         stop_reason: :end_turn,
         messages: [Handbean.Agent.Message.assistant("ok")],
         usage: %{input_tokens: 1, output_tokens: 1},
         response_metadata: %{}
       }}
    end

    def stream(messages, tools, config, _chunk), do: complete(messages, tools, config)
  end

  defmodule HoldProvider do
    @behaviour Handbean.Agent.Provider
    def complete(_messages, _tools, config) do
      notify = config[:notify] || Process.whereis(:conversation_hold_capture)
      if is_pid(notify), do: send(notify, {:held, self(), config})

      receive do
        :release -> :ok
      end

      {:ok,
       %{
         stop_reason: :end_turn,
         messages: [Handbean.Agent.Message.assistant("Audited safely")],
         usage: %{input_tokens: 1, output_tokens: 1},
         response_metadata: %{}
       }}
    end

    def stream(messages, tools, config, _chunk), do: complete(messages, tools, config)
  end

  setup do
    home = Path.join(System.tmp_dir!(), "handoffs-#{Ecto.UUID.generate()}")
    File.mkdir_p!(home)
    env = Map.new(~w(HOME HANDBEAN_MODELS_FILE), &{&1, System.get_env(&1)})
    System.put_env("HOME", home)
    models = Path.join(home, "models.json")

    File.write!(
      models,
      ~s({"providers":{"fake":{"baseUrl":"http://localhost","api":"openai-chat-completions","apiKey":"fake","models":[{"id":"fake-model","name":"Fake"}]}}})
    )

    System.put_env("HANDBEAN_MODELS_FILE", models)
    previous_test_provider = Application.get_env(:handbean, :test_provider)
    Application.put_env(:handbean, :test_provider, %{module: __MODULE__.HoldProvider})
    test_pid = self()
    hold_capture = spawn(fn -> forward_hold_messages(test_pid) end)
    Process.register(hold_capture, :conversation_hold_capture)
    {:ok, source} = ConversationStore.create("ws")
    {:ok, target} = ConversationStore.create("ws")

    opts = [
      workspace_path: home,
      model: "fake/fake-model",
      provider: HoldProvider,
      provider_config: %{notify: self()},
      tools: [],
      source: :cli,
      workspace_id: "ws",
      streaming: false
    ]

    context = %{
      conversation_id: source["id"],
      workspace_id: "ws",
      run_id: "source-run",
      conversation_run_opts: opts
    }

    on_exit(fn ->
      settle_runtime!("ws")

      for {key, value} <- env,
          do: if(value, do: System.put_env(key, value), else: System.delete_env(key))

      if Process.alive?(hold_capture), do: Process.exit(hold_capture, :kill)

      if previous_test_provider,
        do: Application.put_env(:handbean, :test_provider, previous_test_provider),
        else: Application.delete_env(:handbean, :test_provider)

      File.rm_rf!(home)
    end)

    %{source: source["id"], target: target["id"], context: context, opts: opts}
  end

  test "Coordinator sends once, preserves trusted origin, defaults steer and allows explicit follow_up",
       c do
    {:ok, ack} = Handbean.Agent.Coordinator.add_message(c.target, "Human task", c.opts)
    assert_receive {:held, _, _}, 2000

    assert {:ok, %{state: "running", current_run: run}} =
             Conversations.status(%{"conversation" => c.target}, c.context)

    assert run == ack.run_id
    :sys.replace_state(ack.run_pid, &%{&1 | status: :awaiting_approval})

    assert {:ok, %{state: "awaiting_approval"}} =
             Conversations.status(%{"conversation" => c.target}, c.context)

    :sys.replace_state(ack.run_pid, &%{&1 | status: :running})
    input = %{"conversation" => c.target, "message" => "Report", "request_id" => "same"}
    tasks = for _ <- 1..4, do: Task.async(fn -> Collaboration.send_message(input, c.context) end)
    receipts = Enum.map(tasks, &Task.await/1)
    assert Enum.all?(receipts, &match?({:ok, %{delivery: "enqueued"}}, &1))
    {:ok, first} = hd(receipts)

    assert {:ok, %{delivery: "enqueued"}} =
             Collaboration.send_message(
               %{input | "request_id" => "later"} |> Map.put("deliver_as", "follow_up"),
               c.context
             )

    {:ok, entries} = ConversationTranscriptStore.list(c.target)
    inbound = Enum.filter(entries, &(get_in(&1, ["origin", "kind"]) == "conversation"))
    assert length(inbound) == 2
    assert Enum.map(inbound, & &1["delivery"]) == ["steer", "follow_up"]
    assert hd(inbound)["origin"]["conversation_id"] == c.source
    assert hd(inbound)["origin"]["run_id"] == "source-run"
    assert hd(inbound)["id"] == first.message_id
    assert hd(inbound)["origin"]["purpose"] == "request"
    assert hd(inbound)["origin"]["expect_report"]
    assert hd(inbound)["consumption"] == "pending"

    Handbean.Agent.TranscriptPersistence.handle_event(
      c.target,
      {:candidate_message_injected, %{message_ids: [first.message_id]}},
      []
    )

    {:ok, entries} = ConversationTranscriptStore.list(c.target)
    assert Enum.find(entries, &(&1["id"] == first.message_id))["consumption"] == "consumed"
  end

  test "new delegated runtime is read-only, unbounded, knows its creator and reports by consumed request",
       c do
    context = Map.put(c.context, :tool_call_id, "create-tool")

    {:ok, receipt} =
      Collaboration.create(
        %{"title" => "Audit", "message" => "Read only", "request_id" => "audit"},
        context
      )

    assert receipt.delivery == "started"
    assert_receive {:held, provider, config}, 2000
    refute Map.has_key?(config, :max_tokens)
    {:ok, status} = Handbean.Agent.Runner.status(receipt.conversation)
    state = :sys.get_state(status.run_pid)
    refute state.opts[:max_turns] == 3
    assert state.opts[:delegated_read_only]
    assert state.opts[:created_by_conversation_id] == c.source

    agent_config = Handbean.Agent.Config.from_opts(state.opts)
    assert agent_config.context.handoff_id == receipt.handoff_id
    assert agent_config.context.origin_conversation_id == c.source
    assert agent_config.context.created_by_conversation_id == c.source
    assert agent_config.system_prompt =~ "created_by_conversation_id: #{c.source}"
    assert agent_config.system_prompt =~ "active_origin_conversation_id: #{c.source}"

    assert agent_config.system_prompt =~ "automatic terminal report"
    assert agent_config.system_prompt =~ "purpose: result"

    assert {:ok, meta} = ConversationStore.get_metadata(receipt.conversation)
    assert meta["parent_conversation_id"] == c.source
    assert meta["parent_run_id"] == "source-run"
    assert meta["parent_tool_call_id"] == "create-tool"
    refute Map.has_key?(meta["collaboration"], "parent")
    refute Map.has_key?(meta["collaboration"], "handoff_id")

    assert {:ok, child_entries} = ConversationTranscriptStore.list(receipt.conversation)

    [initial_task] =
      Enum.filter(child_entries, &(get_in(&1, ["origin", "kind"]) == "conversation"))

    assert initial_task["content"] =~ "Source conversation_id: #{c.source}"
    assert initial_task["content"] =~ "Handoff_id: #{receipt.handoff_id}"

    {:ok, parent_entries_before} = ConversationTranscriptStore.list(c.source)

    assert :ok =
             Collaboration.completed(receipt.conversation, %{status: :completed},
               run_id: "child-run"
             )

    {:ok, parent_entries_after} = ConversationTranscriptStore.list(c.source)
    assert parent_entries_after == parent_entries_before

    assert {:ok, %{last_result: "completed"}} =
             Conversations.status(%{"conversation" => receipt.conversation}, c.context)

    supervisor_ref = Process.monitor(status.run_supervisor)
    send(provider, :release)
    assert_receive {:DOWN, ^supervisor_ref, :process, _, _}, 2_000
  end

  test "current model is the explicit spelling of inherited model", c do
    input = %{
      "title" => "Audit",
      "message" => "Use the caller model",
      "request_id" => "current-model",
      "model" => "current"
    }

    assert {:ok, receipt} = Collaboration.create(input, c.context)
    assert receipt.model == "current"
    assert receipt.mode == "read_only"
    assert_receive {:held, _, config}, 2000
    assert config.model == "fake-model"

    assert {:ok, ^receipt} =
             Collaboration.create(Map.delete(input, "model"), c.context)

    assert {:ok, meta} = ConversationStore.get_metadata(receipt.conversation)
    assert meta["selected_model"] == "fake/fake-model"
    refute get_in(meta, ["collaboration", "provider"])
    refute get_in(meta, ["collaboration", "model"])
  end

  test "provider-filled safe defaults still inherit the current model", c do
    input = %{
      "title" => "Audit",
      "message" => "Use the caller model",
      "request_id" => "provider-defaults",
      "mode" => "read_only",
      "model" => ""
    }

    assert {:ok, receipt} = Collaboration.create(input, c.context)
    assert_receive {:held, _, config}, 2000
    assert config.model == "fake-model"

    assert {:ok, meta} = ConversationStore.get_metadata(receipt.conversation)
    assert get_in(meta, ["collaboration", "read_only"])
    refute get_in(meta, ["collaboration", "approval"])
    refute get_in(meta, ["collaboration", "provider"])
    refute get_in(meta, ["collaboration", "model"])
  end

  test "inbound persistence failure is uncertain, retained and never dispatched twice", c do
    context = %{
      c.context
      | conversation_run_opts: Keyword.put(c.opts, :transcript_store, FailingInboundStore)
    }

    input = %{"conversation" => c.target, "message" => "Must survive", "request_id" => "fail"}
    assert {:ok, %{delivery: "delivery_unknown"}} = Collaboration.send_message(input, context)
    assert {:ok, %{delivery: "delivery_unknown"}} = Collaboration.send_message(input, context)
    refute_receive {:held, _, _}, 100
    assert {:ok, []} = ConversationTranscriptStore.list(c.target)
  end

  test "blank optional handoff starts a new exchange and matches an omitted-field retry", c do
    input = %{
      "conversation" => c.target,
      "message" => "Coordinate work",
      "request_id" => "blank-handoff"
    }

    assert {:ok, receipt} =
             Collaboration.send_message(Map.put(input, "handoff_id", ""), c.context)

    assert {:ok, ^receipt} = Collaboration.send_message(input, c.context)

    assert {:error, :idempotency_conflict} =
             Collaboration.send_message(Map.put(input, "purpose", "notification"), c.context)

    assert {:error, :invalid_input} =
             Collaboration.send_message(
               %{input | "request_id" => "invalid-purpose"} |> Map.put("purpose", "bogus"),
               c.context
             )

    assert String.starts_with?(receipt.handoff_id, "handoff-")
    assert_receive {:held, _, _}, 2000

    assert {:ok, entries} = ConversationTranscriptStore.list(c.source)
    assert Enum.count(entries, &(&1["content_type"] == "conversation_handoff")) == 1
  end

  test "independent handoffs, replies and retries preserve their exact association", c do
    {:ok, first} =
      Collaboration.create(
        %{"title" => "Audit", "message" => "ALPHA request", "request_id" => "alpha"},
        c.context
      )

    assert_receive {:held, _, _}, 2000

    input = %{
      "conversation" => first.conversation,
      "message" => "BETA request",
      "request_id" => "beta"
    }

    {:ok, second} = Collaboration.send_message(input, c.context)
    assert first.handoff_id != second.handoff_id
    assert {:ok, ^second} = Collaboration.send_message(input, c.context)

    child_context = %{c.context | conversation_id: first.conversation}

    for {receipt, label} <- [{first, "ALPHA"}, {second, "BETA"}] do
      reply = %{
        "message" => "#{label} result",
        "request_id" => "#{label}-result",
        "handoff_id" => receipt.handoff_id
      }

      assert {:ok, result} = Collaboration.reply(reply, child_context)
      assert result.handoff_id == receipt.handoff_id
      assert {:ok, ^result} = Collaboration.reply(reply, child_context)
    end

    {:ok, parent_entries} = ConversationTranscriptStore.list(c.source)
    {:ok, child_entries} = ConversationTranscriptStore.list(first.conversation)
    assert Enum.count(parent_entries, &(&1["content_type"] == "conversation_handoff")) == 2

    for {receipt, label} <- [{first, "ALPHA"}, {second, "BETA"}] do
      [request] =
        Enum.filter(child_entries, &(get_in(&1, ["origin", "handoff_id"]) == receipt.handoff_id))

      assert request["content"] =~ "#{label} request"

      [result] =
        Enum.filter(parent_entries, &(get_in(&1, ["origin", "handoff_id"]) == receipt.handoff_id))

      assert result["content"] =~ "#{label} result"
      assert result["origin"]["important"]
    end

    assert {:error, :invalid_handoff_id} =
             Collaboration.send_message(
               Map.put(input, "request_id", "forged") |> Map.put("handoff_id", "invented"),
               c.context
             )

    assert {:error, :invalid_handoff_id} =
             Collaboration.send_message(
               %{input | "conversation" => c.target, "request_id" => "wrong-peer"}
               |> Map.put("handoff_id", first.handoff_id),
               c.context
             )

    assert {:error, :idempotency_conflict} =
             Collaboration.send_message(Map.put(input, "handoff_id", first.handoff_id), c.context)
  end

  test "a child can explicitly message any authorized conversation and receive its reply", c do
    {:ok, child} =
      Collaboration.create(
        %{"title" => "Audit", "message" => "First", "request_id" => "first"},
        c.context
      )

    assert_receive {:held, _, _}, 2000
    {:ok, parent_entries_before} = ConversationTranscriptStore.list(c.source)
    child_context = %{c.context | conversation_id: child.conversation, run_id: "child-run"}

    assert {:ok, outbound} =
             Collaboration.send_message(
               %{
                 "conversation" => c.target,
                 "message" => "Question for an unrelated conversation",
                 "request_id" => "child-to-target"
               },
               child_context
             )

    assert_receive {:held, _, _}, 2000
    assert {:ok, target_status} = Handbean.Agent.Runner.status(c.target)

    target_agent_config =
      target_status.run_pid |> :sys.get_state() |> then(&Handbean.Agent.Config.from_opts(&1.opts))

    assert target_agent_config.context.origin_conversation_id == child.conversation
    refute Map.has_key?(target_agent_config.context, :created_by_conversation_id)

    assert target_agent_config.system_prompt =~
             "active_origin_conversation_id: #{child.conversation}"

    assert {:ok, target_entries} = ConversationTranscriptStore.list(c.target)

    assert Enum.any?(target_entries, fn entry ->
             entry["content"] =~ "Source conversation_id: #{child.conversation}" and
               entry["content"] =~ "Handoff_id: #{outbound.handoff_id}"
           end)

    target_context = %{c.context | conversation_id: c.target, run_id: "target-run"}

    assert {:ok, reply} =
             Collaboration.send_message(
               %{
                 "conversation" => child.conversation,
                 "message" => "Direct answer",
                 "request_id" => "target-to-child",
                 "handoff_id" => outbound.handoff_id
               },
               target_context
             )

    assert reply.handoff_id == outbound.handoff_id
    {:ok, parent_entries_after} = ConversationTranscriptStore.list(c.source)
    assert parent_entries_after == parent_entries_before

    assert {:ok, child_entries} = ConversationTranscriptStore.list(child.conversation)

    assert Enum.any?(child_entries, fn entry ->
             entry["content"] =~ "Direct answer" and
               entry["content"] =~ "Source conversation_id: #{c.target}" and
               get_in(entry, ["origin", "conversation_id"]) == c.target and
               get_in(entry, ["origin", "handoff_id"]) == outbound.handoff_id
           end)
  end

  test "write mode edits the shared workspace and follows workspace permission mode", c do
    {:ok, receipt} =
      Collaboration.create(
        %{"title" => "Patch", "message" => "Edit", "request_id" => "write", "mode" => "write"},
        c.context
      )

    assert_receive {:held, _, _}, 2000
    {:ok, meta} = ConversationStore.get_metadata(receipt.conversation)
    assert get_in(meta, ["collaboration", "read_only"]) == false
    refute get_in(meta, ["collaboration", "approval"])
    child = %{c.context | conversation_id: receipt.conversation}
    assert Collaboration.tool_allowed?("write", child)
    assert Collaboration.tool_allowed?("edit", child)
    assert Collaboration.tool_allowed?("bash", child)
    {:ok, status} = Handbean.Agent.Runner.status(receipt.conversation)
    state = :sys.get_state(status.run_pid)
    refute state.opts[:delegated_read_only]
    refute state.opts[:delegated_approval]

    assert {:error, :idempotency_conflict} =
             Collaboration.create(
               %{"title" => "Patch", "message" => "Edit", "request_id" => "write"},
               c.context
             )
  end

  test "create_conversation does not take a per-child approval", c do
    assert {:error, :invalid_input} =
             Collaboration.create(
               %{
                 "title" => "Patch",
                 "message" => "Edit",
                 "request_id" => "yolo",
                 "mode" => "write",
                 "approval" => "yolo"
               },
               c.context
             )
  end

  test "a selected catalog model resolves its own provider config", c do
    File.write!(System.get_env("HANDBEAN_MODELS_FILE"), catalog())
    previous = Application.get_env(:handbean, :test_provider)
    Application.put_env(:handbean, :test_provider, %{module: __MODULE__.CaptureProvider})
    Process.register(self(), :conversation_model_capture)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:handbean, :test_provider, previous),
        else: Application.delete_env(:handbean, :test_provider)

      if Process.whereis(:conversation_model_capture) == self(),
        do: Process.unregister(:conversation_model_capture)
    end)

    before = length(ConversationStore.list_metadata("ws"))

    assert {:error, message} =
             Collaboration.create(
               %{
                 "title" => "Other",
                 "message" => "Nope",
                 "request_id" => "missing-model",
                 "model" => "other/missing"
               },
               c.context
             )

    assert message =~ "not available"
    assert message =~ "list_models"
    assert length(ConversationStore.list_metadata("ws")) == before

    assert {:error, :invalid_input} =
             Collaboration.create(
               %{
                 "title" => "Other",
                 "message" => "Nope",
                 "request_id" => "half",
                 "provider" => "other"
               },
               c.context
             )

    {:ok, receipt} =
      Collaboration.create(
        %{
          "title" => "Other",
          "message" => "Use other",
          "request_id" => "other",
          "model" => "other/other-model",
          "mode" => "write"
        },
        c.context
      )

    assert_receive {:captured, config, _provider}, 2000
    refute Map.has_key?(config, :notify)
    assert config[:provider_key] == "other"
    assert config[:api_key] == "other-key"
    refute_received {:held, _, _}
    assert {:ok, meta} = ConversationStore.get_metadata(receipt.conversation)
    assert meta["selected_model"] == "other/other-model"
    {:ok, status} = Handbean.Agent.Runner.status(receipt.conversation)
    opts = :sys.get_state(status.run_pid).opts
    assert opts[:model] == "other-model"
    refute opts[:provider] == HoldProvider
    refute opts[:delegated_approval]
  end

  test "target wakeup rebuilds model, identity, checkout and permission from target facts", c do
    File.write!(System.get_env("HANDBEAN_MODELS_FILE"), catalog())

    source_checkout =
      Path.join(c.context.conversation_run_opts[:workspace_path], "source-checkout")

    target_checkout =
      Path.join(c.context.conversation_run_opts[:workspace_path], "target-checkout")

    for path <- [source_checkout, target_checkout] do
      File.mkdir_p!(path)
      {_, 0} = System.cmd("git", ["init", "-q", path])
    end

    {:ok, readonly_source} =
      ConversationStore.create("ws",
        checkout_path: source_checkout,
        selected_model: "fake/fake-model",
        collaboration: %{"read_only" => true},
        parent_conversation_id: c.source
      )

    {:ok, writable_target} =
      ConversationStore.create("ws",
        checkout_path: target_checkout,
        selected_model: "other/other-model",
        selected_reasoning_level: "high"
      )

    source_compaction = fn _event -> :source_compaction end
    source_compaction_complete = fn _event -> :source_compaction_complete end
    source_advisor = %{status: :source_only}

    source_opts =
      c.context.conversation_run_opts
      |> Keyword.merge(
        run_id: "leaked-source-run",
        working_directory: source_checkout,
        model: "fake/fake-model",
        delegated_read_only: true,
        created_by_conversation_id: c.source,
        history_messages: [Handbean.Agent.Message.user("source-only history")],
        context: %{source_only_identity: true},
        allowed_tools: [],
        system_prompt: "SOURCE-ONLY SYSTEM PROMPT",
        task_instructions: "SOURCE-ONLY TASK INSTRUCTIONS",
        max_tokens: 1_111,
        max_messages: 2,
        compaction: [reserve_tokens: 7, keep_recent_tokens: 3],
        on_compaction: source_compaction,
        on_compaction_complete: source_compaction_complete,
        until_tool: "source-only-tool",
        skill_paths: ["/source-only-skill"],
        advisor: source_advisor,
        builtin_memory_enabled: false
      )

    source_context = %{
      conversation_id: readonly_source["id"],
      workspace_id: "ws",
      run_id: "leaked-source-run",
      conversation_run_opts: source_opts
    }

    assert {:ok, receipt} =
             Collaboration.send_message(
               %{
                 "conversation" => writable_target["id"],
                 "message" => "Use target runtime facts",
                 "request_id" => "target-facts"
               },
               source_context
             )

    assert_receive {:held, _, config}, 2_000
    {:ok, target_meta} = ConversationStore.get_metadata(writable_target["id"])
    canonical_target_checkout = target_meta["checkout_path"]
    assert config.model == "other-model"
    assert config.working_directory == canonical_target_checkout

    {:ok, status} = Handbean.Agent.Runner.status(receipt.conversation)
    target_opts = :sys.get_state(status.run_pid).opts
    refute target_opts[:run_id] == "leaked-source-run"
    refute target_opts[:delegated_read_only]
    refute target_opts[:created_by_conversation_id]
    refute target_opts[:history_messages] == source_opts[:history_messages]
    refute target_opts[:context] == source_opts[:context]
    refute target_opts[:allowed_tools] == []
    refute target_opts[:system_prompt] == source_opts[:system_prompt]
    refute target_opts[:task_instructions]
    refute target_opts[:max_tokens] == 1_111
    refute target_opts[:max_messages] == 2
    refute target_opts[:compaction] == source_opts[:compaction]
    refute target_opts[:on_compaction] == source_compaction
    refute target_opts[:on_compaction_complete] == source_compaction_complete
    refute target_opts[:until_tool] == "source-only-tool"
    refute target_opts[:skill_paths] == ["/source-only-skill"]
    refute target_opts[:advisor] == source_advisor
    refute target_opts[:builtin_memory_enabled] == false
    assert target_opts[:working_directory] == canonical_target_checkout
    assert target_opts[:model] == "other-model"
    assert target_opts[:provider_config][:provider_key] == "other"
  end

  test "working_directory-only callers resolve models without overriding the target checkout",
       c do
    target_checkout =
      Path.join(c.context.conversation_run_opts[:workspace_path], "wd-only-target")

    File.mkdir_p!(target_checkout)
    {_, 0} = System.cmd("git", ["init", "-q", target_checkout])

    {:ok, target} =
      ConversationStore.create("ws",
        checkout_path: target_checkout,
        selected_model: "fake/fake-model"
      )

    run_opts =
      c.context.conversation_run_opts
      |> Keyword.delete(:workspace_path)
      |> Keyword.put(:working_directory, c.context.conversation_run_opts[:workspace_path])

    context = %{c.context | conversation_run_opts: run_opts}

    assert {:ok, %{delivery: "started"}} =
             Collaboration.send_message(
               %{
                 "conversation" => target["id"],
                 "message" => "Resolve from working directory",
                 "request_id" => "working-directory-only"
               },
               context
             )

    assert_receive {:held, _, config}, 2_000
    assert {:ok, target_meta} = ConversationStore.get_metadata(target["id"])
    assert config.model == "fake-model"
    assert config.working_directory == target_meta["checkout_path"]
  end

  test "progress does not fulfill a request and repeated completion is idempotent", c do
    {:ok, request} =
      Collaboration.send_message(
        %{
          "conversation" => c.target,
          "message" => "Do the work",
          "request_id" => "progress-task"
        },
        c.context
      )

    assert_receive {:held, _, _}, 2_000
    {:ok, target_status} = Handbean.Agent.Runner.status(c.target)
    target_context = %{c.context | conversation_id: c.target, run_id: target_status.run_id}

    assert {:ok, _progress} =
             Collaboration.send_message(
               %{
                 "conversation" => c.source,
                 "message" => "Halfway done",
                 "request_id" => "progress-update",
                 "handoff_id" => request.handoff_id,
                 "purpose" => "progress"
               },
               target_context
             )

    assert_receive {:held, _, _}, 2_000
    {:ok, source_status} = Handbean.Agent.Runner.status(c.source)

    {:ok, _} =
      ConversationTranscriptStore.append(c.target, %{
        "id" => "unique-final",
        "content_type" => "assistant_msg",
        "message_type" => "assistant",
        "role" => "assistant",
        "direction" => "outbound",
        "run_id" => target_status.run_id,
        "phase" => "final",
        "status" => "completed",
        "content" => "UNIQUELY ATTRIBUTABLE FINAL"
      })

    assert :ok =
             Collaboration.completed(c.target, %{status: :completed},
               run_id: target_status.run_id,
               workspace_path: c.context.conversation_run_opts[:workspace_path]
             )

    assert :ok =
             Collaboration.completed(c.target, %{status: :completed},
               run_id: target_status.run_id,
               workspace_path: c.context.conversation_run_opts[:workspace_path]
             )

    {:ok, target_entries} = ConversationTranscriptStore.list(c.target)

    reports =
      Enum.filter(target_entries, fn entry ->
        entry["content_type"] == "conversation_handoff" and entry["automatic_report"] == true
      end)

    assert [report] = reports
    assert report["purpose"] == "result"
    assert report["covered_inbound_ids"] == [request.message_id]
    assert report["content"] =~ "UNIQUELY ATTRIBUTABLE FINAL"

    {:ok, source_entries} = ConversationTranscriptStore.list(c.source)
    automatic = Enum.find(source_entries, &(get_in(&1, ["origin", "automatic_report"]) == true))
    assert get_in(automatic, ["origin", "purpose"]) == "result"
    refute get_in(automatic, ["origin", "expect_report"])

    :ok =
      Handbean.Agent.TranscriptPersistence.handle_event(
        c.source,
        {:candidate_message_injected, %{message_ids: [automatic["id"]]}},
        run_id: source_status.run_id
      )

    outbound_before = Enum.count(source_entries, &(&1["content_type"] == "conversation_handoff"))

    assert :ok =
             Collaboration.completed(c.source, %{status: :completed},
               run_id: source_status.run_id,
               workspace_path: c.context.conversation_run_opts[:workspace_path]
             )

    {:ok, source_entries_after} = ConversationTranscriptStore.list(c.source)

    assert Enum.count(source_entries_after, &(&1["content_type"] == "conversation_handoff")) ==
             outbound_before
  end

  test "reverse requests and results require explicit purpose and cover only requests already consumed",
       c do
    {:ok, handoff} =
      Collaboration.send_message(
        %{"conversation" => c.target, "message" => "Initial task", "request_id" => "round-trip"},
        c.context
      )

    assert_receive {:held, _, _}, 2_000
    {:ok, target_status} = Handbean.Agent.Runner.status(c.target)
    target_context = %{c.context | conversation_id: c.target, run_id: target_status.run_id}

    {:ok, first_question} =
      Collaboration.send_message(
        %{
          "conversation" => c.source,
          "message" => "Need clarification one",
          "request_id" => "clarify-one",
          "handoff_id" => handoff.handoff_id,
          "purpose" => "request"
        },
        target_context
      )

    assert_receive {:held, _, _}, 2_000
    {:ok, source_status} = Handbean.Agent.Runner.status(c.source)
    source_context = %{c.context | run_id: source_status.run_id}

    {:ok, first_answer} =
      Collaboration.send_message(
        %{
          "conversation" => c.target,
          "message" => "First answer",
          "request_id" => "answer-one",
          "handoff_id" => handoff.handoff_id,
          "purpose" => "result"
        },
        source_context
      )

    {:ok, second_question} =
      Collaboration.send_message(
        %{
          "conversation" => c.source,
          "message" => "Need clarification two",
          "request_id" => "clarify-two",
          "handoff_id" => handoff.handoff_id,
          "purpose" => "request"
        },
        target_context
      )

    :ok =
      Handbean.Agent.TranscriptPersistence.handle_event(
        c.source,
        {:candidate_message_injected, %{message_ids: [second_question.message_id]}},
        run_id: source_status.run_id
      )

    {:ok, source_entries} = ConversationTranscriptStore.list(c.source)
    first_result = Enum.find(source_entries, &(&1["id"] == first_answer.message_id))
    assert first_result["covered_inbound_ids"] == [first_question.message_id]
    refute second_question.message_id in first_result["covered_inbound_ids"]

    assert :ok =
             Collaboration.completed(c.source, %{status: :completed},
               run_id: source_status.run_id,
               workspace_path: c.context.conversation_run_opts[:workspace_path]
             )

    {:ok, source_entries} = ConversationTranscriptStore.list(c.source)
    automatic = Enum.find(source_entries, &(&1["automatic_report"] == true))
    assert automatic["covered_inbound_ids"] == [second_question.message_id]
  end

  test "a non-completed terminal status is reported even after an explicit result", c do
    {:ok, request} =
      Collaboration.send_message(
        %{"conversation" => c.target, "message" => "May halt", "request_id" => "halt-task"},
        c.context
      )

    assert_receive {:held, _, _}, 2_000
    {:ok, target_status} = Handbean.Agent.Runner.status(c.target)
    target_context = %{c.context | conversation_id: c.target, run_id: target_status.run_id}

    assert {:ok, _} =
             Collaboration.send_message(
               %{
                 "conversation" => c.source,
                 "message" => "Partial result",
                 "request_id" => "halt-partial",
                 "handoff_id" => request.handoff_id,
                 "purpose" => "result"
               },
               target_context
             )

    assert_receive {:held, _, _}, 2_000

    assert :ok =
             Collaboration.completed(c.target, %{status: :max_turns},
               run_id: target_status.run_id,
               workspace_path: c.context.conversation_run_opts[:workspace_path]
             )

    {:ok, entries} = ConversationTranscriptStore.list(c.target)
    report = Enum.find(entries, &(&1["automatic_report"] == true))
    assert report["purpose"] == "notification"
    assert report["content"] =~ "max_turns"
    refute report["content"] =~ "Partial result"
  end

  test "legacy entries are not retroactively reported and delegated task ownership does not double report",
       c do
    for {id, purpose, expect_report} <- [
          {"legacy-consumed", nil, nil},
          {"delegation-owned", "request", true}
        ] do
      origin =
        %{
          "kind" => "conversation",
          "conversation_id" => c.source,
          "handoff_id" => "historical-handoff"
        }
        |> Map.put("purpose", purpose)
        |> Map.put("expect_report", expect_report)

      {:ok, _} =
        ConversationTranscriptStore.append(c.target, %{
          "id" => id,
          "content_type" => "user_msg",
          "message_type" => "user",
          "role" => "user",
          "direction" => "inbound",
          "content" => id,
          "consumption" => "consumed",
          "consumed_run_id" => id,
          "origin" => origin
        })
    end

    assert :ok =
             Collaboration.completed(c.target, %{status: :completed}, run_id: "legacy-consumed")

    assert :ok =
             Collaboration.completed(c.target, %{status: :completed},
               run_id: "delegation-owned",
               delegated?: true
             )

    {:ok, entries} = ConversationTranscriptStore.list(c.target)
    refute Enum.any?(entries, &(&1["content_type"] == "conversation_handoff"))
  end

  test "an uncertain explicit result is not replayed or replaced by an automatic report", c do
    {:ok, request} =
      Collaboration.send_message(
        %{
          "conversation" => c.target,
          "message" => "Uncertain result task",
          "request_id" => "uncertain-task"
        },
        c.context
      )

    assert_receive {:held, _, _}, 2_000
    {:ok, target_status} = Handbean.Agent.Runner.status(c.target)

    target_context = %{
      c.context
      | conversation_id: c.target,
        run_id: target_status.run_id,
        conversation_run_opts:
          Keyword.put(c.context.conversation_run_opts, :transcript_store, FailingInboundStore)
    }

    result_input = %{
      "conversation" => c.source,
      "message" => "Uncertain explicit result",
      "request_id" => "uncertain-result",
      "handoff_id" => request.handoff_id,
      "purpose" => "result"
    }

    assert {:ok, %{delivery: "delivery_unknown"} = uncertain} =
             Collaboration.send_message(result_input, target_context)

    assert {:ok, ^uncertain} = Collaboration.send_message(result_input, target_context)

    assert :ok =
             Collaboration.completed(c.target, %{status: :completed},
               run_id: target_status.run_id,
               workspace_path: c.context.conversation_run_opts[:workspace_path]
             )

    {:ok, entries} = ConversationTranscriptStore.list(c.target)
    assert Enum.count(entries, &(&1["content_type"] == "conversation_handoff")) == 1
    [reservation] = Enum.filter(entries, &(&1["content_type"] == "conversation_handoff"))
    assert reservation["delivery_status"] == "delivery_unknown"
    assert reservation["covered_inbound_ids"] == [request.message_id]
    refute reservation["automatic_report"]
  end

  test "an unavailable report peer does not delay the source conversation's next run", c do
    assert {:ok, receipt} =
             Collaboration.send_message(
               %{
                 "conversation" => c.target,
                 "message" => "Finish despite unavailable peer",
                 "request_id" => "unavailable-report-peer"
               },
               c.context
             )

    assert_receive {:held, provider, _config}, 2_000
    assert {:ok, status} = Handbean.Agent.Runner.status(receipt.conversation)
    supervisor_ref = Process.monitor(status.run_supervisor)
    assert {:ok, _} = ConversationStore.update_meta(c.source, visibility: "internal")
    send(provider, :release)
    assert_receive {:DOWN, ^supervisor_ref, :process, _, _}, 1_000

    assert {:ok, %{action: :started}} =
             Handbean.Agent.Coordinator.add_message(c.target, "next run", c.opts)

    assert_receive {:held, _, _}, 2_000
  end

  test "timeout report reaches its peer only after the old source run exits", c do
    assert {:ok, request} =
             Collaboration.send_message(
               %{
                 "conversation" => c.target,
                 "message" => "Timeout ordering task",
                 "request_id" => "timeout-ordering"
               },
               c.context
             )

    assert_receive {:held, _, _}, 2_000
    {:ok, status} = Handbean.Agent.Runner.status(c.target)
    old_run_id = status.run_id
    supervisor_ref = Process.monitor(status.run_supervisor)

    # The timer message is the narrowest available test entry point for timeout.
    state = :sys.get_state(status.run_pid)
    send(status.run_pid, {:run_inactivity, state.deadline})

    assert_receive {:held, _, %{conversation_id: conversation_id}}, 2_000
    assert conversation_id == c.source
    assert_receive {:DOWN, ^supervisor_ref, :process, _, _}, 0
    assert {:ok, %{running?: false}} = Handbean.Agent.Coordinator.status(c.target)

    assert {:ok, %{delivery: "started"}} =
             Collaboration.send_message(
               %{
                 "conversation" => c.target,
                 "message" => "Immediate follow-up",
                 "request_id" => "after-timeout",
                 "handoff_id" => request.handoff_id,
                 "purpose" => "request"
               },
               c.context
             )

    assert {:ok, %{run_id: new_run_id, running?: true}} =
             Handbean.Agent.Coordinator.status(c.target)

    assert new_run_id != old_run_id
    assert_receive {:held, _, %{conversation_id: target_id}}, 2_000
    assert target_id == c.target
  end

  test "cancel, timeout and abnormal stop report sanitized status without duplicate task reports",
       c do
    {:ok, timeout_target} = ConversationStore.create("ws", selected_model: "fake/fake-model")
    {:ok, error_target} = ConversationStore.create("ws", selected_model: "fake/fake-model")

    receipts =
      for {target, key} <- [
            {c.target, "cancel-terminal"},
            {timeout_target["id"], "timeout-terminal"},
            {error_target["id"], "error-terminal"}
          ],
          into: %{} do
        {:ok, receipt} =
          Collaboration.send_message(
            %{"conversation" => target, "message" => "terminal task", "request_id" => key},
            c.context
          )

        assert_receive {:held, _, _}, 2_000
        {:ok, status} = Handbean.Agent.Runner.status(target)
        {key, {receipt, status}}
      end

    cancel_id = c.target
    timeout_id = timeout_target["id"]
    error_id = error_target["id"]
    :ok = Phoenix.PubSub.subscribe(Handbean.PubSub, "conversation:updated")

    {cancel_receipt, cancel_status} = receipts["cancel-terminal"]
    cancel_context = %{c.context | conversation_id: c.target, run_id: cancel_status.run_id}

    assert {:ok, _result} =
             Collaboration.send_message(
               %{
                 "conversation" => c.source,
                 "message" => "Result sent before cancellation",
                 "request_id" => "before-cancel-result",
                 "handoff_id" => cancel_receipt.handoff_id,
                 "purpose" => "result"
               },
               cancel_context
             )

    assert_receive {:held, _, _}, 2_000
    cancel_ref = Process.monitor(cancel_status.run_pid)
    assert :ok = Handbean.Agent.Coordinator.cancel(c.target)
    assert_receive {:DOWN, ^cancel_ref, :process, _, _}, 2_000
    assert_receive {:conversation_updated, ^cancel_id}, 2_000

    {_timeout_receipt, timeout_status} = receipts["timeout-terminal"]
    timeout_state = :sys.get_state(timeout_status.run_pid)
    timeout_ref = Process.monitor(timeout_status.run_pid)
    send(timeout_status.run_pid, {:run_inactivity, timeout_state.deadline})
    assert_receive {:DOWN, ^timeout_ref, :process, _, _}, 2_000
    assert_receive {:conversation_updated, ^timeout_id}, 2_000

    {_error_receipt, error_status} = receipts["error-terminal"]
    error_ref = Process.monitor(error_status.run_pid)
    send(error_status.run_pid, {:EXIT, self(), {:secret_provider_error, "do not forward"}})
    assert_receive {:DOWN, ^error_ref, :process, _, _}, 2_000
    assert_receive {:conversation_updated, ^error_id}, 2_000
    {:ok, source_entries} = ConversationTranscriptStore.list(c.source)

    reports =
      Enum.filter(source_entries, &(get_in(&1, ["origin", "automatic_report"]) == true))

    assert length(reports) == 3
    assert Enum.all?(reports, &(get_in(&1, ["origin", "purpose"]) == "notification"))
    assert Enum.any?(reports, &(&1["content"] =~ "cancelled"))
    assert Enum.any?(reports, &(&1["content"] =~ "timeout"))
    assert Enum.any?(reports, &(&1["content"] =~ "error"))
    refute Enum.any?(reports, &(&1["content"] =~ "secret_provider_error"))
  end

  test "one remaining request does not receive unpartitioned final text from a mixed run", c do
    {:ok, peer_b} = ConversationStore.create("ws", selected_model: "fake/fake-model")
    peer_b_context = %{c.context | conversation_id: peer_b["id"], run_id: "peer-b-run"}

    {:ok, from_a} =
      Collaboration.send_message(
        %{"conversation" => c.target, "message" => "A task", "request_id" => "mixed-a"},
        c.context
      )

    assert_receive {:held, _, _}, 2_000
    {:ok, target_status} = Handbean.Agent.Runner.status(c.target)

    {:ok, from_b} =
      Collaboration.send_message(
        %{"conversation" => c.target, "message" => "B task", "request_id" => "mixed-b"},
        peer_b_context
      )

    :ok =
      Handbean.Agent.TranscriptPersistence.handle_event(
        c.target,
        {:candidate_message_injected, %{message_ids: [from_b.message_id]}},
        run_id: target_status.run_id
      )

    {:ok, _} =
      ConversationTranscriptStore.append(c.target, %{
        "id" => "ordinary-user-steer",
        "content_type" => "user_msg",
        "message_type" => "user",
        "role" => "user",
        "direction" => "inbound",
        "content" => "ordinary user input",
        "consumption" => "consumed",
        "consumed_run_id" => target_status.run_id
      })

    {:ok, _} =
      ConversationTranscriptStore.append(c.target, %{
        "id" => "mixed-final",
        "content_type" => "assistant_msg",
        "message_type" => "assistant",
        "role" => "assistant",
        "direction" => "outbound",
        "run_id" => target_status.run_id,
        "phase" => "final",
        "status" => "completed",
        "content" => "PRIVATE UNPARTITIONED FINAL"
      })

    target_context = %{c.context | conversation_id: c.target, run_id: target_status.run_id}

    assert {:ok, _} =
             Collaboration.send_message(
               %{
                 "conversation" => c.source,
                 "message" => "A result",
                 "request_id" => "mixed-a-result",
                 "handoff_id" => from_a.handoff_id,
                 "purpose" => "result"
               },
               target_context
             )

    assert_receive {:held, _, _}, 2_000

    assert :ok =
             Collaboration.completed(c.target, %{status: :completed},
               run_id: target_status.run_id,
               workspace_path: c.context.conversation_run_opts[:workspace_path]
             )

    {:ok, target_entries} = ConversationTranscriptStore.list(c.target)

    [report] =
      Enum.filter(target_entries, fn entry ->
        entry["automatic_report"] == true and entry["handoff_id"] == from_b.handoff_id
      end)

    assert report["content"] =~ "mixed inputs"
    refute report["content"] =~ "PRIVATE UNPARTITIONED FINAL"
  end

  defp settle_runtime!(workspace_id) do
    deadline = System.monotonic_time(:millisecond) + 10_000
    do_settle_runtime!(workspace_id, deadline)
  end

  defp do_settle_runtime!(workspace_id, deadline) do
    ids =
      ConversationStore.list(include_internal?: true)
      |> Enum.filter(&(&1["workspace_id"] == workspace_id))
      |> Enum.map(& &1["id"])

    Enum.each(ids, &cancel_and_wait(&1, deadline))
    await_runtime_tasks!(deadline)

    running = Enum.filter(ids, &running?/1)
    callbacks = Task.Supervisor.children(Handbean.AgentRunTaskSupervisor)

    cond do
      running == [] and callbacks == [] ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        raise "runtime cleanup did not converge: running=#{inspect(running)} callbacks=#{inspect(callbacks)}"

      true ->
        do_settle_runtime!(workspace_id, deadline)
    end
  end

  defp await_runtime_tasks!(deadline) do
    case Task.Supervisor.children(Handbean.AgentRunTaskSupervisor) do
      [] ->
        :ok

      tasks ->
        Enum.each(tasks, &await_process!(&1, deadline, :terminal_callback))
        await_runtime_tasks!(deadline)
    end
  end

  defp cancel_and_wait(id, deadline) do
    case Handbean.Agent.Runner.status(id) do
      {:ok, %{run_supervisor: supervisor} = status} when is_pid(supervisor) ->
        if status.running?, do: Handbean.Agent.Runner.cancel(id)
        await_process!(supervisor, deadline, {:run_supervisor, id})

      _ ->
        :ok
    end
  end

  defp running?(id) do
    match?({:ok, %{running?: true}}, Handbean.Agent.Runner.status(id))
  end

  defp await_process!(pid, deadline, label) do
    ref = Process.monitor(pid)
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        raise "runtime cleanup timed out waiting for #{inspect(label)} pid=#{inspect(pid)}"
    end
  end

  defp forward_hold_messages(test_pid) do
    receive do
      message ->
        send(test_pid, message)
        forward_hold_messages(test_pid)
    end
  end

  defp catalog do
    ~s({"providers":{"fake":{"baseUrl":"http://localhost","api":"openai-chat-completions","apiKey":"fake","models":[{"id":"fake-model","name":"Fake"}]},"other":{"baseUrl":"http://127.0.0.1:9","api":"openai-chat-completions","apiKey":"other-key","provider":"openai-compat","models":[{"id":"other-model","name":"Other"}]}}})
  end
end
