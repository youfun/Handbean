defmodule Handbean.Agent.TranscriptPersistenceTest do
  use Handbean.DataCase, async: false

  alias Handbean.Agent.TranscriptPersistence

  test "message consumption failures are returned rather than acknowledged" do
    {:ok, conversation} = Handbean.ConversationStore.create("default", timeline: [])
    id = conversation["id"]

    assert {:ok, _} =
             TranscriptPersistence.append_inbound(id, "pending", transcript_id: "pending")

    for event <- [{:run_start, %{}}, {:candidate_message_injected, %{message_ids: ["pending"]}}] do
      opts = [
        transcript_store: __MODULE__.FailingStore,
        origin: :test,
        transcript_id: "pending",
        run_id: "consumption"
      ]

      assert {:error, :eacces} =
               TranscriptPersistence.handle_event(
                 id,
                 event,
                 Keyword.put(opts, :fail_operation, :update)
               )

      assert :ok = TranscriptPersistence.handle_event(id, event, opts)
    end

    assert [%{"consumption" => "consumed", "consumed_run_id" => "consumption"}] =
             Handbean.ConversationStore.load_messages(id)
  end

  test "an explicit failed run cannot finalize partial text as completed without an error string" do
    for status <- [:error, "error", :timeout, "timeout"] do
      {:ok, conversation} = Handbean.ConversationStore.create("default", timeline: [])
      id = conversation["id"]
      opts = [run_id: "failed-run"]
      assert :ok = TranscriptPersistence.handle_event(id, {:run_start, %{}}, opts)

      assert :ok =
               TranscriptPersistence.handle_event(id, {:message_delta, %{chunk: "partial"}}, opts)

      assert :ok = TranscriptPersistence.handle_event(id, {:run_end, %{status: status}}, opts)

      assistant =
        Enum.find(Handbean.ConversationStore.load_messages(id), &(&1["role"] == "assistant"))

      assert assistant["status"] == "error"
    end
  end

  test "stop notice persistence failure is returned and retry remains possible" do
    {:ok, conversation} = Handbean.ConversationStore.create("default", timeline: [])
    id = conversation["id"]
    opts = [transcript_store: __MODULE__.FailingStore, run_id: "stop-notice"]
    assert :ok = TranscriptPersistence.handle_event(id, {:run_start, %{}}, opts)

    assert {:error, :enospc} =
             TranscriptPersistence.handle_event(
               id,
               {:run_end, %{status: :max_turns, turns: 4}},
               Keyword.put(opts, :fail_operation, :append)
             )

    assert [] = Handbean.ConversationStore.load_messages(id)

    assert :ok =
             TranscriptPersistence.handle_event(
               id,
               {:run_end, %{status: :max_turns, turns: 4}},
               opts
             )

    assert [%{"content_type" => "system_msg"}] = Handbean.ConversationStore.load_messages(id)
  end

  test "explicit failed and interrupted tool status is durable even without an error string" do
    {:ok, conversation} = Handbean.ConversationStore.create("default", timeline: [])
    id = conversation["id"]

    for status <- [:failed, "failed", :interrupted, "interrupted"] do
      tool_use_id = "#{status}-#{System.unique_integer([:positive])}"

      assert :ok =
               TranscriptPersistence.handle_event(
                 id,
                 {:tool_end, %{tool_use_id: tool_use_id, tool: "bash", status: status}}
               )
    end

    entries = Handbean.ConversationStore.load_messages(id)
    assert length(entries) == 4
    assert Enum.all?(entries, &(&1["tool_status"] == "error"))
  end

  defmodule FailingStore do
    alias Handbean.ConversationTranscriptStore.ConversationStore, as: Store

    def append(id, entry, opts) do
      if opts[:fail_operation] == :append,
        do: {:error, :enospc},
        else: Store.append(id, entry, opts)
    end

    def update(id, entry_id, patch, opts) do
      case opts[:fail_operation] do
        :update ->
          {:error, :eacces}

        :queued ->
          # The journal synced the record, but clearing its intent failed.
          {:ok, _} = Store.update(id, entry_id, patch, opts)
          {:error, {:queued, :eacces}}

        _ ->
          Store.update(id, entry_id, patch, opts)
      end
    end
  end

  defmodule TestDelivery do
    @behaviour Handbean.Delivery

    @impl true
    def deliver(entry, opts) do
      send(Keyword.fetch!(opts, :notify), {:delivered, entry})
      :ok
    end
  end

  defmodule ApprovalFinalProvider do
    @behaviour Handbean.Agent.Provider

    @impl true
    def complete(_messages, _tools, _config) do
      {:ok,
       %{
         stop_reason: :end_turn,
         messages: [Handbean.Agent.Message.assistant("Approval finished")],
         usage: %{input_tokens: 3, output_tokens: 7}
       }}
    end

    @impl true
    def stream(messages, tools, config, _on_chunk), do: complete(messages, tools, config)
  end

  setup do
    old_home = System.get_env("HOME")

    home_dir =
      Path.join(
        System.tmp_dir!(),
        "sigil_agent_transcript_home_#{System.unique_integer([:positive])}"
      )

    System.put_env("HOME", home_dir)

    on_exit(fn ->
      if old_home, do: System.put_env("HOME", old_home), else: System.delete_env("HOME")
      if File.exists?(home_dir), do: File.rm_rf!(home_dir)
    end)

    :ok
  end

  test "codex commentary and final_answer persist as separate assistant messages" do
    {:ok, conversation} = Handbean.ConversationStore.create("default", timeline: [])
    id = conversation["id"]

    :ok = TranscriptPersistence.handle_event(id, {:run_start, %{}}, [])

    :ok =
      TranscriptPersistence.handle_event(
        id,
        {:message_delta, %{chunk: "Hello! ", phase: "commentary", output_index: 0}},
        []
      )

    :ok =
      TranscriptPersistence.handle_event(
        id,
        {:message_delta,
         %{chunk: "What can I help you with?", phase: "commentary", output_index: 0}},
        []
      )

    :ok =
      TranscriptPersistence.handle_event(
        id,
        {:message_delta,
         %{chunk: "Hello! How can I help?", phase: "final_answer", output_index: 1}},
        []
      )

    assert :ok = TranscriptPersistence.handle_event(id, {:run_end, %{status: :completed}}, [])

    assert [
             %{
               "content" => "Hello! What can I help you with?",
               "phase" => "commentary",
               "status" => "completed"
             },
             %{
               "content" => "Hello! How can I help?",
               "phase" => "final_answer",
               "status" => "completed"
             }
           ] = Handbean.ConversationStore.load_messages(id)
  end

  test "approval resume finalizes durable assistant and automatically collapses preceding work" do
    alias Handbean.Agent.{Config, Message, State, Turn}

    {:ok, conversation} = Handbean.ConversationStore.create("default", timeline: [])
    id = conversation["id"]
    on_event = &TranscriptPersistence.handle_event(id, &1)
    on_event.({:run_start, %{model: "fake"}})
    on_event.({:message_delta, %{chunk: "I will run a command"}})
    on_event.({:tool_start, %{tool_use_id: "approval-1", tool: "bash", input: %{command: "pwd"}}})
    on_event.({:run_end, %{status: :interrupted}})

    state =
      State.init(
        %Config{
          provider: ApprovalFinalProvider,
          model: "fake",
          max_turns: 5,
          provider_config: %{}
        },
        "check"
      )
      |> State.append_messages([
        Message.tool_use([
          %{type: "tool_use", id: "approval-1", name: "bash", input: %{"command" => "pwd"}}
        ])
      ])
      |> Map.merge(%{
        status: :interrupted,
        turn: 1,
        interrupt_data: %{hitl_tool_call_ids: ["approval-1"]}
      })

    result =
      Turn.resume_after_tool_approval(
        state,
        [%{"tool_call_id" => "approval-1", "action" => "deny"}],
        on_event: on_event
      )

    assert result.status == :completed
    entries = Handbean.ConversationStore.load_messages(id)
    final = Enum.find(entries, &(&1["content"] == "Approval finished"))
    assert final["phase"] == "final"
    assert final["status"] == "completed"
  end

  test "failed append preserves the buffer and does not complete or deliver the reply" do
    {:ok, conversation} = Handbean.ConversationStore.create("default", timeline: [])
    id = conversation["id"]

    opts = [
      transcript_store: FailingStore,
      delivery: TestDelivery,
      delivery_opts: [notify: self()]
    ]

    :ok = TranscriptPersistence.handle_event(id, {:run_start, %{}}, opts)

    assert_raise RuntimeError, ~r/Assistant transcript persistence failed.*enospc/, fn ->
      TranscriptPersistence.handle_event(
        id,
        {:message_delta, %{chunk: "first second"}},
        Keyword.put(opts, :fail_operation, :append)
      )
    end

    assert [] = Handbean.ConversationStore.load_messages(id)
    refute_received {:delivered, _}

    :ok = TranscriptPersistence.handle_event(id, {:message_delta, %{chunk: " third"}}, opts)
    assert :ok = TranscriptPersistence.handle_event(id, {:run_end, %{status: :completed}}, opts)

    assert [%{"content" => "first second third", "status" => "completed", "phase" => "final"}] =
             Handbean.ConversationStore.load_messages(id)

    assert_received {:delivered, %{"delivery_delta" => "first second third"}}
    refute_received {:delivered, _}
  end

  test "a queued delta transfers buffer ownership and cannot be appended twice" do
    {:ok, conversation} = Handbean.ConversationStore.create("default", timeline: [])
    id = conversation["id"]
    opts = [transcript_store: FailingStore]
    :ok = TranscriptPersistence.handle_event(id, {:run_start, %{}}, opts)
    :ok = TranscriptPersistence.handle_event(id, {:message_delta, %{chunk: "saved"}}, opts)

    assert_raise RuntimeError, ~r/queued/, fn ->
      TranscriptPersistence.handle_event(
        id,
        {:message_delta, %{chunk: " queued"}},
        Keyword.put(opts, :fail_operation, :queued)
      )
    end

    :ok = TranscriptPersistence.handle_event(id, {:message_delta, %{chunk: " later"}}, opts)
    assert [%{"content" => "saved queued later"}] = Handbean.ConversationStore.load_messages(id)
  end

  test "failed update retains only unsaved deltas and cannot advance the tool boundary" do
    {:ok, conversation} = Handbean.ConversationStore.create("default", timeline: [])
    id = conversation["id"]

    opts = [
      transcript_store: FailingStore,
      delivery: TestDelivery,
      delivery_opts: [notify: self()]
    ]

    :ok = TranscriptPersistence.handle_event(id, {:run_start, %{}}, opts)
    :ok = TranscriptPersistence.handle_event(id, {:message_delta, %{chunk: "saved"}}, opts)
    :ok = TranscriptPersistence.handle_event(id, {:turn_end, %{}}, opts)
    assert_received {:delivered, %{"delivery_delta" => "saved"}}
    tool_event = {:tool_start, %{tool: "read", tool_use_id: "read-1", input: %{}}}

    assert_raise RuntimeError, ~r/Assistant transcript persistence failed.*eacces/, fn ->
      TranscriptPersistence.handle_event(
        id,
        {:message_delta, %{chunk: " pending"}},
        Keyword.put(opts, :fail_operation, :update)
      )
    end

    assert [%{"content" => "saved", "status" => "streaming"}] =
             Handbean.ConversationStore.load_messages(id)

    refute_received {:delivered, _}
    :ok = TranscriptPersistence.handle_event(id, {:message_delta, %{chunk: " later"}}, opts)
    assert :ok = TranscriptPersistence.handle_event(id, tool_event, opts)

    assert [
             %{"content" => "saved pending later", "phase" => "commentary"},
             %{"id" => "tool-read-1"}
           ] = Handbean.ConversationStore.load_messages(id)

    assert_received {:delivered, %{"delivery_delta" => " pending later"}}
    refute_received {:delivered, _}
  end

  test "persists assistant deltas without a LiveView process" do
    {:ok, conversation} =
      Handbean.ConversationStore.create("default",
        timeline: [
          %{
            "id" => "msg-user-1",
            "content_type" => "user_msg",
            "role" => "user",
            "content" => "hello"
          }
        ]
      )

    conversation_id = conversation["id"]

    TranscriptPersistence.handle_event(conversation_id, {:run_start, %{model: "test"}})

    TranscriptPersistence.handle_event(
      conversation_id,
      {:message_delta, %{chunk: "assistant "}}
    )

    TranscriptPersistence.handle_event(conversation_id, {:message_delta, %{chunk: "reply"}})
    TranscriptPersistence.handle_event(conversation_id, {:run_end, %{status: "completed"}})

    messages = Handbean.ConversationStore.load_messages(conversation_id)

    assert Enum.any?(messages, &match?(%{"role" => "user", "content" => "hello"}, &1))

    assert Enum.any?(
             messages,
             &match?(%{"role" => "assistant", "content" => "assistant reply"}, &1)
           )
  end

  test "persists each message_delta before acknowledging it" do
    {:ok, conversation} = Handbean.ConversationStore.create("default", timeline: [])
    conversation_id = conversation["id"]

    TranscriptPersistence.handle_event(conversation_id, {:run_start, %{model: "test"}})

    TranscriptPersistence.handle_event(
      conversation_id,
      {:message_delta, %{chunk: "delayed write"}}
    )

    messages = Handbean.ConversationStore.load_messages(conversation_id)

    assert Enum.any?(
             messages,
             &match?(%{"role" => "assistant", "content" => "delayed write"}, &1)
           )
  end

  test "run_end finalizes already durable text" do
    {:ok, conversation} = Handbean.ConversationStore.create("default", timeline: [])
    conversation_id = conversation["id"]

    TranscriptPersistence.handle_event(conversation_id, {:run_start, %{model: "test"}})

    TranscriptPersistence.handle_event(
      conversation_id,
      {:message_delta, %{chunk: "first "}}
    )

    TranscriptPersistence.handle_event(
      conversation_id,
      {:message_delta, %{chunk: "second"}}
    )

    # Text is durable even before the final boundary.
    messages_before = Handbean.ConversationStore.load_messages(conversation_id)

    assert Enum.any?(
             messages_before,
             &match?(%{"role" => "assistant"}, &1)
           )

    # run_end marks the reply completed.
    TranscriptPersistence.handle_event(conversation_id, {:run_end, %{status: "completed"}})

    messages_after = Handbean.ConversationStore.load_messages(conversation_id)

    assert Enum.any?(
             messages_after,
             &match?(%{"role" => "assistant", "content" => "first second"}, &1)
           )
  end

  test "flushes buffered text at tool_start boundary" do
    {:ok, conversation} = Handbean.ConversationStore.create("default", timeline: [])
    conversation_id = conversation["id"]

    TranscriptPersistence.handle_event(conversation_id, {:run_start, %{model: "test"}})

    TranscriptPersistence.handle_event(
      conversation_id,
      {:message_delta, %{chunk: "assistant text"}}
    )

    # tool_start triggers flush of pending assistant text
    TranscriptPersistence.handle_event(
      conversation_id,
      {:tool_start, %{tool_use_id: "tu_1", tool: "bash", input: %{}}}
    )

    messages = Handbean.ConversationStore.load_messages(conversation_id)

    assert Enum.any?(
             messages,
             &match?(%{"role" => "assistant", "content" => "assistant text"}, &1)
           )
  end

  test "thinking_delta does not trigger transcript flush" do
    {:ok, conversation} = Handbean.ConversationStore.create("default", timeline: [])
    conversation_id = conversation["id"]

    TranscriptPersistence.handle_event(conversation_id, {:run_start, %{model: "test"}})

    # Buffer some text
    TranscriptPersistence.handle_event(
      conversation_id,
      {:message_delta, %{chunk: "keep buffered"}}
    )

    # Send a thinking_delta — should NOT flush the buffer
    TranscriptPersistence.handle_event(
      conversation_id,
      {:thinking_delta, %{chunk: "thinking text"}}
    )

    messages = Handbean.ConversationStore.load_messages(conversation_id)

    # Thinking must not alter the already persisted visible text.
    assert Enum.any?(
             messages,
             &match?(%{"role" => "assistant", "content" => "keep buffered"}, &1)
           )
  end

  test "thinking_delta raw string variant does not trigger flush" do
    {:ok, conversation} = Handbean.ConversationStore.create("default", timeline: [])
    conversation_id = conversation["id"]

    TranscriptPersistence.handle_event(conversation_id, {:run_start, %{model: "test"}})

    TranscriptPersistence.handle_event(
      conversation_id,
      {:message_delta, %{chunk: "unflushed"}}
    )

    # Anthropic-style thinking_delta (raw string, not map)
    TranscriptPersistence.handle_event(
      conversation_id,
      {:thinking_delta, "raw thinking string"}
    )

    messages = Handbean.ConversationStore.load_messages(conversation_id)

    assert Enum.any?(
             messages,
             &match?(%{"role" => "assistant", "content" => "unflushed"}, &1)
           )
  end

  test "persists provider reasoning that arrives after streamed assistant text" do
    {:ok, conversation} = Handbean.ConversationStore.create("default", timeline: [])
    conversation_id = conversation["id"]
    opts = [run_id: "reasoning-stream"]

    reasoning = %{
      type: "responses_reasoning",
      provider_context: %{
        provider: "openai",
        api: "openai_responses",
        model: "gpt-5.2"
      },
      item: %{
        "type" => "reasoning",
        "id" => "rs_stream",
        "encrypted_content" => "opaque"
      }
    }

    assert :ok = TranscriptPersistence.handle_event(conversation_id, {:run_start, %{}}, opts)

    assert :ok =
             TranscriptPersistence.handle_event(
               conversation_id,
               {:message_delta, %{chunk: "visible"}},
               opts
             )

    assert :ok =
             TranscriptPersistence.handle_event(
               conversation_id,
               {:provider_items, %{items: [reasoning]}},
               opts
             )

    assert :ok =
             TranscriptPersistence.handle_event(
               conversation_id,
               {:run_end, %{status: :completed}},
               opts
             )

    assistant =
      conversation_id
      |> Handbean.ConversationStore.load_messages()
      |> Enum.find(&(&1["role"] == "assistant"))

    assert assistant["content_blocks"] == [
             %{
               "type" => "responses_reasoning",
               "provider_context" => %{
                 "provider" => "openai",
                 "api" => "openai_responses",
                 "model" => "gpt-5.2"
               },
               "item" => %{
                 "type" => "reasoning",
                 "id" => "rs_stream",
                 "encrypted_content" => "opaque"
               }
             }
           ]
  end

  test "persists and restores provider reasoning from a tool-only assistant turn" do
    {:ok, conversation} = Handbean.ConversationStore.create("default", timeline: [])
    conversation_id = conversation["id"]
    opts = [run_id: "reasoning-tool"]

    reasoning = %{
      type: "responses_reasoning",
      provider_context: %{
        provider: "openai",
        api: "openai_responses",
        model: "gpt-5.2"
      },
      item: %{"type" => "reasoning", "encrypted_content" => "tool-opaque"}
    }

    assert :ok = TranscriptPersistence.handle_event(conversation_id, {:run_start, %{}}, opts)

    assert :ok =
             TranscriptPersistence.handle_event(
               conversation_id,
               {:provider_items, %{items: [reasoning]}},
               opts
             )

    assert :ok =
             TranscriptPersistence.handle_event(
               conversation_id,
               {:tool_start, %{tool_use_id: "read-1", tool: "read", input: %{file_path: "a"}}},
               opts
             )

    assert :ok =
             TranscriptPersistence.handle_event(
               conversation_id,
               {:tool_end, %{tool_use_id: "read-1", tool: "read", output: "ok"}},
               opts
             )

    tool =
      conversation_id
      |> Handbean.ConversationStore.load_messages()
      |> Enum.find(&(&1["id"] == "tool-read-1"))

    assert [%{"type" => "responses_reasoning"}] = tool["content_blocks"]

    assert [assistant, result] =
             Handbean.Attachments.History.to_messages(tool, nil, conversation_id)

    assert [
             %{"type" => "responses_reasoning"},
             %{type: "tool_use", id: "read-1"}
           ] = assistant.content

    assert [%{type: "tool_result", tool_use_id: "read-1"}] = result.content
  end

  test "does not persist provider thinking wrappers as assistant text" do
    {:ok, conversation} = Handbean.ConversationStore.create("default", timeline: [])
    conversation_id = conversation["id"]

    TranscriptPersistence.handle_event(conversation_id, {:run_start, %{model: "test"}})

    TranscriptPersistence.handle_event(
      conversation_id,
      {:message_delta, %{chunk: "Before "}}
    )

    TranscriptPersistence.handle_event(
      conversation_id,
      {:message_delta, %{chunk: "<think>hidden</think><think>reasoning</think>"}}
    )

    TranscriptPersistence.handle_event(
      conversation_id,
      {:message_delta, %{chunk: " after"}}
    )

    TranscriptPersistence.handle_event(conversation_id, {:run_end, %{status: "completed"}})

    messages = Handbean.ConversationStore.load_messages(conversation_id)
    assistant = Enum.find(messages, &(&1["role"] == "assistant"))

    assert assistant["content"] == "Before  after"
    refute assistant["content"] =~ "<think>"
    refute assistant["content"] =~ "hidden"
    refute assistant["content"] =~ "reasoning"
  end

  test "persists tool start and end as internal transcript records" do
    {:ok, conversation} = Handbean.ConversationStore.create("default", timeline: [])
    conversation_id = conversation["id"]

    TranscriptPersistence.handle_event(conversation_id, {:run_start, %{model: "test"}})

    TranscriptPersistence.handle_event(
      conversation_id,
      {:tool_start, %{tool_use_id: "toolu_1", tool: "read", input: %{file_path: "a.txt"}}}
    )

    TranscriptPersistence.handle_event(
      conversation_id,
      {:tool_end, %{tool_use_id: "toolu_1", tool: "read", duration_ms: 12}}
    )

    messages = Handbean.ConversationStore.load_messages(conversation_id)

    assert %{
             "id" => "tool-toolu_1",
             "message_type" => "tool",
             "direction" => "internal",
             "tool_name" => "read",
             "tool_duration_ms" => 12,
             "tool_status" => "done"
           } = tool = Enum.find(messages, &(&1["id"] == "tool-toolu_1"))

    refute Map.has_key?(tool, "tool")
    refute Map.has_key?(tool, "status")
    refute Map.has_key?(tool, "duration_ms")
    refute Map.has_key?(tool, "error")
  end

  test "a nameless tool_end keeps the name recorded at tool_start" do
    {:ok, conversation} = Handbean.ConversationStore.create("default", timeline: [])
    conversation_id = conversation["id"]

    assert :ok =
             TranscriptPersistence.handle_event(
               conversation_id,
               {:tool_start,
                %{
                  tool_use_id: "WrxcLFl8Z",
                  tool: "Execute",
                  input: %{command: "git status"}
                }}
             )

    assert :ok =
             TranscriptPersistence.handle_event(
               conversation_id,
               {:tool_end, %{tool_use_id: "WrxcLFl8Z", output: " M lib/app.ex"}}
             )

    [entry] = Handbean.ConversationStore.load_messages(conversation_id)
    assert entry["tool_name"] == "Execute"
    assert entry["tool_status"] == "done"
    assert entry["output"] =~ "lib/app.ex"
  end

  test "tool_end without a prior start still records a placeholder name" do
    {:ok, conversation} = Handbean.ConversationStore.create("default", timeline: [])
    conversation_id = conversation["id"]

    assert :ok =
             TranscriptPersistence.handle_event(
               conversation_id,
               {:tool_end, %{tool_use_id: "orphan-1", output: "done"}}
             )

    [entry] = Handbean.ConversationStore.load_messages(conversation_id)
    assert entry["id"] == "tool-orphan-1"
    assert entry["tool_name"] == "unknown"
    assert entry["tool_status"] == "done"
  end

  test "persists invalid UTF-8 in a tool error without crashing the run" do
    {:ok, conversation} = Handbean.ConversationStore.create("default", timeline: [])
    conversation_id = conversation["id"]

    assert :ok =
             TranscriptPersistence.handle_event(
               conversation_id,
               {:tool_start, %{tool_use_id: "invalid-error", tool: "bash", input: %{}}}
             )

    assert :ok =
             TranscriptPersistence.handle_event(
               conversation_id,
               {:tool_end,
                %{tool_use_id: "invalid-error", tool: "bash", error: <<"failed", 0xFF>>}}
             )

    [entry] = Handbean.ConversationStore.load_messages(conversation_id)
    assert entry["tool_status"] == "error"
    assert entry["tool_error"] == "failed�"
  end

  test "redacts sensitive tool inputs before writing durable history" do
    {:ok, conversation} = Handbean.ConversationStore.create("default", timeline: [])

    TranscriptPersistence.handle_event(
      conversation["id"],
      {:tool_start,
       %{
         tool_use_id: "secret-input",
         tool: "git",
         input: %{
           "action" => "push",
           "password" => "fixture-secret",
           "nested" => %{token: "nested-secret"}
         }
       }}
    )

    [entry] = Handbean.ConversationStore.load_messages(conversation["id"])
    assert entry["input"]["action"] == "push"
    assert entry["input"]["password"] == "[REDACTED]"
    assert entry["input"]["nested"]["token"] == "[REDACTED]"
  end

  test "marks assistant message as completed on run_end" do
    {:ok, conversation} = Handbean.ConversationStore.create("default", timeline: [])
    conversation_id = conversation["id"]

    TranscriptPersistence.handle_event(conversation_id, {:run_start, %{model: "test"}})

    TranscriptPersistence.handle_event(
      conversation_id,
      {:message_delta, %{chunk: "hello world"}}
    )

    TranscriptPersistence.handle_event(conversation_id, {:run_end, %{status: "completed"}})

    messages = Handbean.ConversationStore.load_messages(conversation_id)
    assistant = Enum.find(messages, &(&1["role"] == "assistant"))

    assert assistant, "expected an assistant message in the transcript"

    assert assistant["status"] == "completed",
           "expected assistant status to be 'completed', got: #{inspect(assistant["status"])}"
  end

  test "append_inbound mints a new id when the transcript id is already used" do
    {:ok, conversation} = Handbean.ConversationStore.create("default", timeline: [])
    conversation_id = conversation["id"]

    assert {:ok, %{"id" => "msg-user-13", "content" => "original"}} =
             TranscriptPersistence.append_inbound(conversation_id, "original",
               transcript_id: "msg-user-13",
               message_id: "msg-user-13",
               inbound_id: "msg-user-13",
               source: :live_view,
               deliver_as: :new_run
             )

    assert {:ok, persisted} =
             TranscriptPersistence.append_inbound(
               conversation_id,
               %Handbean.Agent.Message{
                 role: :user,
                 content: "macos 中间可以可以去掉？",
                 id: "msg-user-13"
               },
               transcript_id: "msg-user-13",
               message_id: "msg-user-13",
               inbound_id: "msg-user-13",
               source: :live_view,
               deliver_as: :new_run
             )

    assert persisted["id"] != "msg-user-13"
    assert persisted["content"] == "macos 中间可以可以去掉？"
    assert persisted["inbound_id"] == persisted["id"]

    messages = Handbean.ConversationStore.load_messages(conversation_id)
    assert Enum.map(messages, & &1["content"]) == ["original", "macos 中间可以可以去掉？"]
  end

  test "append_inbound records delivery and interrupts_work from deliver_as" do
    {:ok, conversation} = Handbean.ConversationStore.create("default", timeline: [])
    conversation_id = conversation["id"]

    assert {:ok, new_run} =
             TranscriptPersistence.append_inbound(conversation_id, "start",
               source: :cli,
               deliver_as: :new_run
             )

    assert {:ok, steer} =
             TranscriptPersistence.append_inbound(conversation_id, "steer me",
               source: :cli,
               deliver_as: :steer
             )

    assert {:ok, follow_up} =
             TranscriptPersistence.append_inbound(conversation_id, "later",
               source: :cli,
               deliver_as: :follow_up
             )

    assert {:ok, default_idle} =
             TranscriptPersistence.append_inbound(conversation_id, "no deliver_as", source: :cli)

    assert new_run["delivery"] == "new_run"
    assert new_run["interrupts_work"] == false
    assert steer["delivery"] == "steer"
    assert steer["interrupts_work"] == true
    assert follow_up["delivery"] == "follow_up"
    assert follow_up["interrupts_work"] == false
    assert default_idle["delivery"] == "new_run"
    assert default_idle["interrupts_work"] == false

    persisted = Handbean.ConversationStore.load_messages(conversation_id)

    assert Enum.map(persisted, &{&1["content"], &1["delivery"], &1["interrupts_work"]}) == [
             {"start", "new_run", false},
             {"steer me", "steer", true},
             {"later", "follow_up", false},
             {"no deliver_as", "new_run", false}
           ]
  end

  test "history reconstruction drops delivery metadata from provider messages" do
    entry = %{
      "role" => "user",
      "content" => "hello",
      "delivery" => "steer",
      "interrupts_work" => true,
      "metadata" => %{"source" => "cli", "delivery" => "steer"}
    }

    assert [%Handbean.Agent.Message{role: :user, content: "hello"} = message] =
             Handbean.Attachments.History.to_messages(entry, nil, "conv-delivery")

    refute Map.has_key?(Map.from_struct(message), :delivery)
    refute Map.has_key?(Map.from_struct(message), :interrupts_work)
    refute Map.has_key?(Map.from_struct(message), :metadata)
  end

  test "marks unfinished tools as error on run_end with error" do
    {:ok, conversation} = Handbean.ConversationStore.create("default", timeline: [])
    conversation_id = conversation["id"]

    TranscriptPersistence.handle_event(conversation_id, {:run_start, %{model: "test"}})

    # Start a tool but never send tool_end (simulating a crash)
    TranscriptPersistence.handle_event(
      conversation_id,
      {:tool_start, %{tool_use_id: "toolu_crash", tool: "bash", input: %{command: "bad"}}}
    )

    # run_end with error (simulating crash before tool_end)
    TranscriptPersistence.handle_event(
      conversation_id,
      {:run_end, %{status: "error", error: "nxdomain"}}
    )

    messages = Handbean.ConversationStore.load_messages(conversation_id)
    tool = Enum.find(messages, &(&1["id"] == "tool-toolu_crash"))

    assert tool, "expected the tool entry in the transcript"

    assert tool["tool_status"] == "error",
           "expected tool_status to be error, got: #{inspect(tool["tool_status"])}"
  end

  test "run_end cancelled scans durable running tools without process-local tracking" do
    {:ok, conversation} = Handbean.ConversationStore.create("default", timeline: [])
    conversation_id = conversation["id"]
    run_id = "run-cancel-#{System.unique_integer([:positive])}"
    opts = [run_id: run_id]

    task =
      Task.async(fn ->
        TranscriptPersistence.handle_event(
          conversation_id,
          {:run_start, %{model: "test"}},
          opts
        )

        TranscriptPersistence.handle_event(
          conversation_id,
          {:tool_start,
           %{tool_use_id: "toolu_hold", tool: "bash", input: %{command: "sleep 30"}}},
          opts
        )
      end)

    Task.await(task)

    refute Process.get({Handbean.Agent.TranscriptPersistence, :running_tools, conversation_id})

    TranscriptPersistence.handle_event(
      conversation_id,
      {:run_end, %{status: "cancelled", turns: 0}},
      opts
    )

    tool =
      Enum.find(
        Handbean.ConversationStore.load_messages(conversation_id),
        &(&1["id"] == "tool-toolu_hold")
      )

    assert tool["tool_status"] == "cancelled"
  end

  test "run_end cancelled only patches the same run and keeps terminal tool statuses" do
    {:ok, conversation} = Handbean.ConversationStore.create("default", timeline: [])
    conversation_id = conversation["id"]
    opts_a = [run_id: "run-a"]
    opts_b = [run_id: "run-b"]

    TranscriptPersistence.handle_event(conversation_id, {:run_start, %{model: "test"}}, opts_a)

    TranscriptPersistence.handle_event(
      conversation_id,
      {:tool_start, %{tool_use_id: "a-running", tool: "bash", input: %{command: "hold"}}},
      opts_a
    )

    TranscriptPersistence.handle_event(
      conversation_id,
      {:tool_start, %{tool_use_id: "a-done", tool: "read", input: %{path: "a.txt"}}},
      opts_a
    )

    TranscriptPersistence.handle_event(
      conversation_id,
      {:tool_end, %{tool_use_id: "a-done", tool: "read", output: "ok"}},
      opts_a
    )

    TranscriptPersistence.handle_event(
      conversation_id,
      {:tool_start, %{tool_use_id: "a-error", tool: "bash", input: %{command: "bad"}}},
      opts_a
    )

    TranscriptPersistence.handle_event(
      conversation_id,
      {:tool_end, %{tool_use_id: "a-error", tool: "bash", error: "failed"}},
      opts_a
    )

    TranscriptPersistence.handle_event(
      conversation_id,
      {:tool_start, %{tool_use_id: "a-cancelled", tool: "bash", input: %{command: "x"}}},
      opts_a
    )

    TranscriptPersistence.handle_event(
      conversation_id,
      {:tool_end, %{tool_use_id: "a-cancelled", tool: "bash", status: :cancelled}},
      opts_a
    )

    TranscriptPersistence.handle_event(conversation_id, {:run_start, %{model: "test"}}, opts_b)

    TranscriptPersistence.handle_event(
      conversation_id,
      {:tool_start, %{tool_use_id: "b-running", tool: "bash", input: %{command: "other"}}},
      opts_b
    )

    TranscriptPersistence.handle_event(
      conversation_id,
      {:run_end, %{status: :cancelled, turns: 0}},
      opts_a
    )

    messages = Handbean.ConversationStore.load_messages(conversation_id)
    by_id = Map.new(messages, &{&1["id"], &1})

    assert by_id["tool-a-running"]["tool_status"] == "cancelled"
    assert by_id["tool-a-done"]["tool_status"] == "done"
    assert by_id["tool-a-error"]["tool_status"] == "error"
    assert by_id["tool-a-cancelled"]["tool_status"] == "cancelled"
    assert by_id["tool-b-running"]["tool_status"] == "running"
  end

  test "run_end interrupted does not cancel running tools" do
    {:ok, conversation} = Handbean.ConversationStore.create("default", timeline: [])
    conversation_id = conversation["id"]
    opts = [run_id: "run-interrupt"]

    TranscriptPersistence.handle_event(conversation_id, {:run_start, %{model: "test"}}, opts)

    TranscriptPersistence.handle_event(
      conversation_id,
      {:tool_start, %{tool_use_id: "approval-running", tool: "bash", input: %{command: "pwd"}}},
      opts
    )

    TranscriptPersistence.handle_event(conversation_id, {:run_end, %{status: :interrupted}}, opts)

    tool =
      Enum.find(
        Handbean.ConversationStore.load_messages(conversation_id),
        &(&1["id"] == "tool-approval-running")
      )

    assert tool["tool_status"] == "running"

    assert {:ok, %{input_tokens: 0, output_tokens: 0}} =
             Handbean.ConversationStore.get_token_usage(conversation_id)
  end

  test "terminal run_end records usage once and interrupted does not" do
    {:ok, conversation} = Handbean.ConversationStore.create("default", timeline: [])
    conversation_id = conversation["id"]
    opts = [run_id: "run-usage"]

    usage = %{
      input_tokens: 9,
      output_tokens: 2,
      cache_read_input_tokens: 5,
      cache_creation_input_tokens: 3,
      total_input_tokens: 14
    }

    assert :ok =
             TranscriptPersistence.handle_event(
               conversation_id,
               {:run_end, %{status: :interrupted, usage: %{input_tokens: 4, output_tokens: 1}}},
               opts
             )

    assert {:ok, %{input_tokens: 0}} = Handbean.ConversationStore.get_token_usage(conversation_id)

    assert :ok =
             TranscriptPersistence.handle_event(
               conversation_id,
               {:run_end, %{status: :completed, usage: usage}},
               opts
             )

    assert :ok =
             TranscriptPersistence.handle_event(
               conversation_id,
               {:run_end, %{status: :completed, usage: usage}},
               opts
             )

    assert {:ok,
            %{
              input_tokens: 9,
              output_tokens: 2,
              cache_read_tokens: 5,
              cache_write_tokens: 3,
              total_input_tokens: 14,
              usage_incomplete: false
            }} = Handbean.ConversationStore.get_token_usage(conversation_id)
  end

  test "terminal stop notices are written once" do
    {:ok, conversation} = Handbean.ConversationStore.create("default", timeline: [])
    conversation_id = conversation["id"]
    opts = [run_id: "run-stop"]

    for status <- [:max_turns, :stalled, :budget_exceeded, :halted] do
      assert :ok =
               TranscriptPersistence.handle_event(
                 conversation_id,
                 {:run_end, %{status: status, turns: 4, evidence: "same grep"}},
                 opts
               )
    end

    assert :ok =
             TranscriptPersistence.handle_event(
               conversation_id,
               {:run_end, %{status: :max_turns, turns: 4}},
               opts
             )

    stops =
      conversation_id
      |> Handbean.ConversationStore.load_messages()
      |> Enum.filter(&(&1["id"] == "msg-run-stop-run-stop"))

    assert [%{"content" => content}] = stops
    assert content =~ "轮上限"
  end
end
