defmodule Handbean.ThreadCollaborationTest do
  use Handbean.DataCase, async: false
  alias Handbean.{ConversationStore, ConversationTranscriptStore, Threads}
  alias Handbean.Threads.Collaboration

  defmodule FailingInboundStore do
    def append(_conversation_id, _entry, _opts), do: {:error, :eisdir}
  end

  defmodule CaptureProvider do
    @behaviour Handbean.Agent.Provider

    def complete(_messages, _tools, config) do
      if pid = Process.whereis(:thread_model_capture), do: send(pid, {:captured, config, self()})

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
      send(config.notify, {:held, self(), config})

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
      thread_run_opts: opts
    }

    on_exit(fn ->
      for m <- ConversationStore.list_metadata("ws"),
          do: Handbean.Agent.Coordinator.cancel(m["id"])

      for {key, value} <- env,
          do: if(value, do: System.put_env(key, value), else: System.delete_env(key))

      File.rm_rf!(home)
    end)

    %{source: source["id"], target: target["id"], context: context, opts: opts}
  end

  test "Coordinator sends once, preserves trusted origin, defaults steer and allows explicit follow_up",
       c do
    {:ok, ack} = Handbean.Agent.Coordinator.add_message(c.target, "Human task", c.opts)
    assert_receive {:held, _, _}, 2000

    assert {:ok, %{state: "running", current_run: run}} =
             Threads.status(%{"thread" => c.target}, c.context)

    assert run == ack.run_id
    :sys.replace_state(ack.run_pid, &%{&1 | status: :awaiting_approval})

    assert {:ok, %{state: "awaiting_approval"}} =
             Threads.status(%{"thread" => c.target}, c.context)

    :sys.replace_state(ack.run_pid, &%{&1 | status: :running})
    input = %{"thread" => c.target, "message" => "Report", "request_id" => "same"}
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
    inbound = Enum.filter(entries, &(get_in(&1, ["origin", "kind"]) == "thread"))
    assert length(inbound) == 2
    assert Enum.map(inbound, & &1["delivery"]) == ["steer", "follow_up"]
    assert hd(inbound)["origin"]["conversation_id"] == c.source
    assert hd(inbound)["origin"]["run_id"] == "source-run"
    assert hd(inbound)["id"] == first.message_id
    assert hd(inbound)["consumption"] == "pending"

    Handbean.Agent.TranscriptPersistence.handle_event(
      c.target,
      {:candidate_message_injected, %{message_ids: [first.message_id]}},
      []
    )

    {:ok, entries} = ConversationTranscriptStore.list(c.target)
    assert Enum.find(entries, &(&1["id"] == first.message_id))["consumption"] == "consumed"
  end

  test "new delegated runtime is read-only, unbounded, knows its creator and ends silently", c do
    context = Map.put(c.context, :tool_call_id, "create-tool")

    {:ok, receipt} =
      Collaboration.create(
        %{"title" => "Audit", "message" => "Read only", "request_id" => "audit"},
        context
      )

    assert receipt.delivery == "started"
    assert_receive {:held, provider, config}, 2000
    refute Map.has_key?(config, :max_tokens)
    {:ok, status} = Handbean.Agent.Runner.status(receipt.thread)
    state = :sys.get_state(status.run_pid)
    refute state.opts[:max_turns] == 3
    assert state.opts[:delegated_read_only]
    assert state.opts[:created_by_conversation_id] == c.source

    agent_config = Handbean.Agent.Config.from_opts(state.opts)
    assert agent_config.context.thread_handoff_id == receipt.handoff_id
    assert agent_config.context.thread_origin_conversation_id == c.source
    assert agent_config.context.created_by_conversation_id == c.source
    assert agent_config.system_prompt =~ "created_by_conversation_id: #{c.source}"
    assert agent_config.system_prompt =~ "active_origin_conversation_id: #{c.source}"

    assert agent_config.system_prompt =~ "Finishing this run does not send a message"

    assert {:ok, meta} = ConversationStore.get_metadata(receipt.thread)
    assert meta["parent_conversation_id"] == c.source
    assert meta["parent_run_id"] == "source-run"
    assert meta["parent_tool_call_id"] == "create-tool"
    refute Map.has_key?(meta["collaboration"], "parent")
    refute Map.has_key?(meta["collaboration"], "handoff_id")

    assert {:ok, child_entries} = ConversationTranscriptStore.list(receipt.thread)
    [initial_task] = Enum.filter(child_entries, &(get_in(&1, ["origin", "kind"]) == "thread"))
    assert initial_task["content"] =~ "Source conversation_id: #{c.source}"
    assert initial_task["content"] =~ "Handoff_id: #{receipt.handoff_id}"

    {:ok, parent_entries_before} = ConversationTranscriptStore.list(c.source)

    assert :ok =
             Collaboration.completed(receipt.thread, %{status: :completed}, run_id: "child-run")

    {:ok, parent_entries_after} = ConversationTranscriptStore.list(c.source)
    assert parent_entries_after == parent_entries_before

    assert {:ok, %{last_result: "completed"}} =
             Threads.status(%{"thread" => receipt.thread}, c.context)

    send(provider, :release)
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

    assert {:ok, meta} = ConversationStore.get_metadata(receipt.thread)
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

    assert {:ok, meta} = ConversationStore.get_metadata(receipt.thread)
    assert get_in(meta, ["collaboration", "read_only"])
    refute get_in(meta, ["collaboration", "approval"])
    refute get_in(meta, ["collaboration", "provider"])
    refute get_in(meta, ["collaboration", "model"])
  end

  test "inbound persistence failure is uncertain, retained and never dispatched twice", c do
    context = %{
      c.context
      | thread_run_opts: Keyword.put(c.opts, :transcript_store, FailingInboundStore)
    }

    input = %{"thread" => c.target, "message" => "Must survive", "request_id" => "fail"}
    assert {:ok, %{delivery: "delivery_unknown"}} = Collaboration.send_message(input, context)
    assert {:ok, %{delivery: "delivery_unknown"}} = Collaboration.send_message(input, context)
    refute_receive {:held, _, _}, 100
    assert {:ok, []} = ConversationTranscriptStore.list(c.target)
  end

  test "blank optional handoff starts a new exchange and matches an omitted-field retry", c do
    input = %{
      "thread" => c.target,
      "message" => "Coordinate work",
      "request_id" => "blank-handoff"
    }

    assert {:ok, receipt} =
             Collaboration.send_message(Map.put(input, "handoff_id", ""), c.context)

    assert {:ok, ^receipt} = Collaboration.send_message(input, c.context)
    assert String.starts_with?(receipt.handoff_id, "handoff-")
    assert_receive {:held, _, _}, 2000

    assert {:ok, entries} = ConversationTranscriptStore.list(c.source)
    assert Enum.count(entries, &(&1["content_type"] == "thread_handoff")) == 1
  end

  test "independent handoffs, replies and retries preserve their exact association", c do
    {:ok, first} =
      Collaboration.create(
        %{"title" => "Audit", "message" => "ALPHA request", "request_id" => "alpha"},
        c.context
      )

    assert_receive {:held, _, _}, 2000
    input = %{"thread" => first.thread, "message" => "BETA request", "request_id" => "beta"}
    {:ok, second} = Collaboration.send_message(input, c.context)
    assert first.handoff_id != second.handoff_id
    assert {:ok, ^second} = Collaboration.send_message(input, c.context)

    child_context = %{c.context | conversation_id: first.thread}

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
    {:ok, child_entries} = ConversationTranscriptStore.list(first.thread)
    assert Enum.count(parent_entries, &(&1["content_type"] == "thread_handoff")) == 2

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
               %{input | "thread" => c.target, "request_id" => "wrong-peer"}
               |> Map.put("handoff_id", first.handoff_id),
               c.context
             )

    assert {:error, :idempotency_conflict} =
             Collaboration.send_message(Map.put(input, "handoff_id", first.handoff_id), c.context)
  end

  test "a child can explicitly message any authorized thread and receive its reply", c do
    {:ok, child} =
      Collaboration.create(
        %{"title" => "Audit", "message" => "First", "request_id" => "first"},
        c.context
      )

    assert_receive {:held, _, _}, 2000
    {:ok, parent_entries_before} = ConversationTranscriptStore.list(c.source)
    child_context = %{c.context | conversation_id: child.thread, run_id: "child-run"}

    assert {:ok, outbound} =
             Collaboration.send_message(
               %{
                 "thread" => c.target,
                 "message" => "Question for an unrelated thread",
                 "request_id" => "child-to-target"
               },
               child_context
             )

    assert_receive {:held, _, _}, 2000
    assert {:ok, target_status} = Handbean.Agent.Runner.status(c.target)

    target_agent_config =
      target_status.run_pid |> :sys.get_state() |> then(&Handbean.Agent.Config.from_opts(&1.opts))

    assert target_agent_config.context.thread_origin_conversation_id == child.thread
    refute Map.has_key?(target_agent_config.context, :created_by_conversation_id)
    assert target_agent_config.system_prompt =~ "active_origin_conversation_id: #{child.thread}"

    assert {:ok, target_entries} = ConversationTranscriptStore.list(c.target)

    assert Enum.any?(target_entries, fn entry ->
             entry["content"] =~ "Source conversation_id: #{child.thread}" and
               entry["content"] =~ "Handoff_id: #{outbound.handoff_id}"
           end)

    target_context = %{c.context | conversation_id: c.target, run_id: "target-run"}

    assert {:ok, reply} =
             Collaboration.send_message(
               %{
                 "thread" => child.thread,
                 "message" => "Direct answer",
                 "request_id" => "target-to-child",
                 "handoff_id" => outbound.handoff_id
               },
               target_context
             )

    assert reply.handoff_id == outbound.handoff_id
    {:ok, parent_entries_after} = ConversationTranscriptStore.list(c.source)
    assert parent_entries_after == parent_entries_before

    assert {:ok, child_entries} = ConversationTranscriptStore.list(child.thread)

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
    {:ok, meta} = ConversationStore.get_metadata(receipt.thread)
    assert get_in(meta, ["collaboration", "read_only"]) == false
    refute get_in(meta, ["collaboration", "approval"])
    child = %{c.context | conversation_id: receipt.thread}
    assert Collaboration.tool_allowed?("write", child)
    assert Collaboration.tool_allowed?("edit", child)
    assert Collaboration.tool_allowed?("bash", child)
    {:ok, status} = Handbean.Agent.Runner.status(receipt.thread)
    state = :sys.get_state(status.run_pid)
    refute state.opts[:delegated_read_only]
    refute state.opts[:delegated_approval]

    assert {:error, :idempotency_conflict} =
             Collaboration.create(
               %{"title" => "Patch", "message" => "Edit", "request_id" => "write"},
               c.context
             )
  end

  test "create_thread does not take a per-child approval", c do
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
    Process.register(self(), :thread_model_capture)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:handbean, :test_provider, previous),
        else: Application.delete_env(:handbean, :test_provider)

      if Process.whereis(:thread_model_capture) == self(),
        do: Process.unregister(:thread_model_capture)
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
    assert {:ok, meta} = ConversationStore.get_metadata(receipt.thread)
    assert meta["selected_model"] == "other/other-model"
    {:ok, status} = Handbean.Agent.Runner.status(receipt.thread)
    opts = :sys.get_state(status.run_pid).opts
    assert opts[:model] == "other-model"
    refute opts[:provider] == HoldProvider
    refute opts[:delegated_approval]
  end

  defp catalog do
    ~s({"providers":{"fake":{"baseUrl":"http://localhost","api":"openai-chat-completions","apiKey":"fake","models":[{"id":"fake-model","name":"Fake"}]},"other":{"baseUrl":"http://127.0.0.1:9","api":"openai-chat-completions","apiKey":"other-key","provider":"openai-compat","models":[{"id":"other-model","name":"Other"}]}}})
  end
end
