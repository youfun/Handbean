defmodule Handbean.ConversationCollaborationCreationTest do
  use Handbean.DataCase, async: false

  alias Handbean.ConversationCollaborationSupport, as: Support
  alias Handbean.ConversationCollaborationSupport.HoldProvider
  alias Handbean.{ConversationStore, ConversationTranscriptStore, Conversations}
  alias Handbean.Conversations.Collaboration

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

  setup do
    Support.setup()
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

  test "current model inherits the caller's effective reasoning when omitted", c do
    File.write!(
      System.get_env("HANDBEAN_MODELS_FILE"),
      ~s({"providers":{"fake":{"baseUrl":"http://localhost","api":"openai-chat-completions","apiKey":"fake","models":[{"id":"fake-model","name":"Fake","reasoning":true,"reasoningLevels":["low","max"],"defaultReasoning":"low"}]}}})
    )

    context = %{
      c.context
      | conversation_run_opts: Keyword.put(c.opts, :reasoning_level, "max")
    }

    assert {:ok, receipt} =
             Collaboration.create(
               %{
                 "title" => "Deep audit",
                 "message" => "Keep the caller reasoning",
                 "request_id" => "current-reasoning",
                 "model" => "current"
               },
               context
             )

    assert receipt.model == "current"
    assert receipt.reasoning_level == "max"
    assert_receive {:held, _, _provider_config}, 2_000
    assert {:ok, status} = Handbean.Agent.Runner.status(receipt.conversation)
    state = :sys.get_state(status.run_pid)
    assert Handbean.Agent.Config.from_opts(state.opts).reasoning_level == "max"

    assert {:ok, meta} = ConversationStore.get_metadata(receipt.conversation)
    assert meta["selected_reasoning_level"] == "max"
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
    File.write!(System.get_env("HANDBEAN_MODELS_FILE"), Support.catalog())
    previous = Application.fetch_env(:handbean, :test_provider)

    on_exit(fn ->
      case previous do
        {:ok, provider} -> Application.put_env(:handbean, :test_provider, provider)
        :error -> Application.delete_env(:handbean, :test_provider)
      end
    end)

    Application.put_env(:handbean, :test_provider, %{module: __MODULE__.CaptureProvider})
    Process.register(self(), :conversation_model_capture)

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
end
