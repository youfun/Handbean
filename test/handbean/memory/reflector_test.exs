defmodule Handbean.Memory.ReflectorTest.Provider do
  @behaviour Handbean.Agent.Provider

  alias Handbean.Agent.Message

  @impl true
  def complete(messages, tools, config) do
    if pid = config[:notify] do
      send(pid, {:reflector_request, messages, tools, config})
    end

    case config[:response] do
      {:error, reason} ->
        {:error, reason}

      {:raise, reason} ->
        raise reason

      {:tool_call, name} ->
        {:ok,
         %{
           stop_reason: :tool_use,
           messages: [
             Message.tool_use([%{type: "tool_use", id: "tool-1", name: name, input: %{}}])
           ],
           usage: %{}
         }}

      :block ->
        send(config[:notify], {:reflector_provider_blocked, self()})

        receive do
          :continue ->
            {:ok,
             %{
               stop_reason: :end_turn,
               messages: [Message.assistant(~s({"type":"ignore","reason":"released"}))],
               usage: %{}
             }}
        end

      {:messages, response_messages} ->
        {:ok, %{stop_reason: :end_turn, messages: response_messages, usage: %{}}}

      text when is_binary(text) ->
        {:ok,
         %{
           stop_reason: :end_turn,
           messages: [Message.assistant(text)],
           usage: %{input_tokens: 10, output_tokens: 10}
         }}
    end
  end
end

defmodule Handbean.Memory.ReflectorTest.FailingAuditStore do
  @behaviour Handbean.ConversationTranscriptStore

  alias Handbean.ConversationTranscriptStore.ConversationStore

  @impl true
  def list(conversation_id, opts),
    do: ConversationStore.list(conversation_id, Keyword.delete(opts, :transcript_store))

  @impl true
  def append(_conversation_id, _entry, _opts), do: {:error, :forced_audit_failure}

  @impl true
  def update(_conversation_id, _entry_id, _patch, _opts), do: {:error, :unsupported}

  @impl true
  def delete(_conversation_id, _entry_id, _opts), do: {:error, :unsupported}

  @impl true
  def replace_all(_conversation_id, _entries, _opts), do: {:error, :unsupported}
end

defmodule Handbean.Memory.ReflectorTest do
  use Handbean.DataCase, async: false

  alias Handbean.Agent.{CompactionCheckpoint, Message}
  alias Handbean.ConversationTranscriptStore
  alias Handbean.Memory.{MemoryStore, Reflector}

  @provider Handbean.Memory.ReflectorTest.Provider
  @failing_audit_store Handbean.Memory.ReflectorTest.FailingAuditStore

  setup do
    workspace_id = "reflector-workspace-#{System.unique_integer([:positive])}"

    {:ok, conversation} =
      Handbean.ConversationStore.create(workspace_id,
        title: "Reflector test",
        checkout_path: File.cwd!()
      )

    %{conversation_id: conversation["id"], workspace_id: workspace_id}
  end

  describe "run/2 and run/3" do
    test "stores one workspace-only short-term candidate and an atomic audit", context do
      checkpoint = put_checkpoint(context.conversation_id, "Remember the naming convention")
      before = DateTime.utc_now()

      response =
        json(%{
          "type" => "candidate",
          "kind" => "preference",
          "content" => "The user prefers descriptive snake_case names"
        })

      assert {:ok, {:candidate, engram}} =
               Reflector.run(context.conversation_id, checkpoint, opts(context, response))

      assert engram.content == "The user prefers descriptive snake_case names"
      assert engram.kind == :preference
      assert engram.short_term
      assert engram.metadata["scope"] == "workspace"
      assert engram.metadata["workspace_id"] == context.workspace_id
      assert engram.metadata["privacy_mode"] == "local_only"
      refute Map.has_key?(engram.metadata, "source")
      refute Map.has_key?(engram.metadata, "conversation_id")
      refute Map.has_key?(engram.metadata, "checkpoint_id")

      assert {:ok, [event]} =
               MemoryStore.provenance(engram.id,
                 workspace_id: context.workspace_id,
                 scope: :workspace,
                 privacy_mode: :local_only
               )

      assert event.actor == :reflector
      assert event.kind == :created
      assert event.metadata["checkpoint_id"] == checkpoint["id"]

      assert [%{relation: :coverage, source_kind: :checkpoint, status: :available} = source] =
               event.sources

      assert source.conversation_id == context.conversation_id
      assert source.start.entry_id == checkpoint["first_entry_id"]
      assert source.end.entry_id == checkpoint["covered_through_id"]
      assert DateTime.diff(engram.expires_at, before, :hour) in 167..168

      audit = audit_entry(context.conversation_id, checkpoint)
      assert audit["content_type"] == "memory_reflection"
      assert audit["message_type"] == "internal"
      assert audit["role"] == "internal"
      assert audit["outcome"] == "candidate"
      assert audit["content"] == "Created a short-term memory candidate"
      assert audit["engram_id"] == engram.id
      assert audit["kind"] == "preference"
    end

    test "builds a bounded prompt from only the persisted summary and active scoped engrams",
         context do
      raw_marker = "RAW-MESSAGE-MUST-NOT-REACH-REFLECTOR"
      other_marker = "OTHER-WORKSPACE-MEMORY-MUST-NOT-LEAK"
      current_marker = "CURRENT-WORKSPACE-ACTIVE-MEMORY"
      summary_tail = "SUMMARY-PAST-THE-BOUND"

      {:ok, _} =
        ConversationTranscriptStore.append(context.conversation_id, %{
          "id" => "raw-user-entry",
          "role" => "user",
          "content_type" => "message",
          "message_type" => "message",
          "content" => raw_marker
        })

      {:ok, _} =
        MemoryStore.learn("#{other_marker} durable project convention", :rule,
          memory_scope: :workspace,
          workspace_id: "different-workspace",
          privacy_mode: :local_only,
          short_term: false
        )

      for index <- 1..45 do
        {:ok, _} =
          MemoryStore.learn(
            "bounded-memory-#{index}-" <> String.duplicate("x", 700),
            :fact,
            memory_scope: :workspace,
            workspace_id: context.workspace_id,
            privacy_mode: :local_only,
            short_term: false
          )
      end

      {:ok, _} =
        MemoryStore.learn("#{current_marker} durable project convention", :rule,
          memory_scope: :workspace,
          workspace_id: context.workspace_id,
          privacy_mode: :local_only,
          short_term: false
        )

      summary = String.duplicate("s", 13_000) <> summary_tail
      checkpoint = put_checkpoint(context.conversation_id, summary)

      assert {:ok, :ignored} =
               Reflector.run(
                 context.conversation_id,
                 checkpoint,
                 opts(context, json(%{"type" => "ignore", "reason" => "No new durable fact"})) ++
                   [
                     provider_config: %{
                       provider_module: @provider,
                       notify: self(),
                       response: json(%{"type" => "ignore", "reason" => "No new durable fact"}),
                       provider_state: %{secret: "state-must-not-leak"},
                       previous_response_id: "prior-response",
                       built_in_tools: [%{name: "web_search"}],
                       web_search: true,
                       x_search: %{allowed_domains: ["example.com"]},
                       stream: true,
                       on_chunk: fn _ -> :ok end
                     }
                   ]
               )

      assert_receive {:reflector_request, [%Message{role: :user, content: prompt}], [], config}
      assert String.length(prompt) < 26_000
      assert prompt =~ current_marker
      assert prompt =~ ~r/"id":\d+/
      refute prompt =~ other_marker
      refute prompt =~ raw_marker
      refute prompt =~ summary_tail
      refute prompt =~ "state-must-not-leak"
      refute Map.has_key?(config, :provider_state)
      refute Map.has_key?(config, :previous_response_id)
      refute Map.has_key?(config, :built_in_tools)
      refute Map.has_key?(config, :web_search)
      refute Map.has_key?(config, :x_search)
      assert config.system_prompt =~ "Return exactly one JSON object"
      assert config.stream == false
      assert config.use_previous_response_id == false
      assert config.max_tokens == 512
      assert config.max_output_tokens == 512
      assert config.temperature == 0
    end

    test "reuses Runner's resolved provider config when only its bare model id is present",
         context do
      checkpoint = put_checkpoint(context.conversation_id, "Runner-shaped reflection summary")
      response = json(%{"type" => "ignore", "reason" => "Nothing durable"})

      run_opts =
        opts(context, response,
          model: "reflector-test-model",
          om: %{reflector_enabled: true}
        )

      assert {:ok, :ignored} =
               Reflector.run(context.conversation_id, checkpoint, run_opts)

      assert_receive {:reflector_request, [%Message{}], [], config}
      assert config.model == "reflector-test-model"
    end

    test "loads the latest checkpoint by default and an explicit persisted checkpoint by id",
         context do
      first = put_checkpoint(context.conversation_id, "first persisted summary")
      second = put_checkpoint(context.conversation_id, "second persisted summary")
      response = json(%{"type" => "ignore", "reason" => "Nothing durable"})

      assert {:ok, :ignored} =
               Reflector.run(context.conversation_id, first["id"], opts(context, response))

      assert audit_entry(context.conversation_id, first)["outcome"] == "ignore"

      assert {:ok, :ignored} = Reflector.run(context.conversation_id, opts(context, response))
      assert audit_entry(context.conversation_id, second)["outcome"] == "ignore"
    end

    test "reloads the checkpoint from persistence instead of trusting a caller-supplied summary",
         context do
      checkpoint = put_checkpoint(context.conversation_id, "PERSISTED-SUMMARY-MARKER")
      forged = %{checkpoint | "summary" => "FORGED-RAW-SUMMARY"}
      response = json(%{"type" => "ignore", "reason" => "Nothing durable"})

      assert {:ok, :ignored} =
               Reflector.run(context.conversation_id, forged, opts(context, response))

      assert_receive {:reflector_request, [%Message{content: prompt}], [], _config}
      assert prompt =~ "PERSISTED-SUMMARY-MARKER"
      refute prompt =~ "FORGED-RAW-SUMMARY"
    end

    test "rejects free conversations and mismatched workspace identities before provider use",
         context do
      checkpoint = put_checkpoint(context.conversation_id, "workspace summary")
      response = json(%{"type" => "ignore", "reason" => "Nothing durable"})

      assert {:error, :scope_mismatch} =
               Reflector.run(
                 context.conversation_id,
                 checkpoint,
                 opts(context, response, workspace_id: "wrong-workspace")
               )

      refute_receive {:reflector_request, _, _, _}

      {:ok, free} = Handbean.ConversationStore.create_free(title: "Free thread")
      free_checkpoint = put_checkpoint(free["id"], "free summary")

      assert {:error, :workspace_required} =
               Reflector.run(free["id"], free_checkpoint, opts(context, response))

      refute_receive {:reflector_request, _, _, _}
    end
  end

  describe "strict decision handling" do
    test "a valid ignore is audited without writing memory", context do
      checkpoint = put_checkpoint(context.conversation_id, "A generic completed task")
      before_count = count_memories(context.workspace_id)

      assert {:ok, :ignored} =
               Reflector.run(
                 context.conversation_id,
                 checkpoint,
                 opts(
                   context,
                   json(%{"type" => "ignore", "reason" => "Only transient task details"})
                 )
               )

      assert count_memories(context.workspace_id) == before_count
      audit = audit_entry(context.conversation_id, checkpoint)
      assert audit["outcome"] == "ignore"
      assert audit["reason"] == "Only transient task details"
    end

    test "policy rejection is audited without writing memory", context do
      checkpoint = put_checkpoint(context.conversation_id, "Potential credential material")
      before_count = count_memories(context.workspace_id)

      response =
        json(%{
          "type" => "candidate",
          "kind" => "fact",
          "content" => "api_key = sk-this-must-never-be-stored-123456789"
        })

      assert {:ok, {:rejected, reason}} =
               Reflector.run(context.conversation_id, checkpoint, opts(context, response))

      assert reason =~ "sensitive"
      assert count_memories(context.workspace_id) == before_count
      audit = audit_entry(context.conversation_id, checkpoint)
      assert audit["outcome"] == "policy_rejected"
      refute Handbean.JSON.encode!(audit) =~ "sk-this-must-never-be-stored"
    end

    test "an active exact duplicate is audited and not inserted", context do
      content = "The project requires deterministic scoped memory writes"

      {:ok, existing} =
        MemoryStore.learn(content, :rule,
          memory_scope: :workspace,
          workspace_id: context.workspace_id,
          privacy_mode: :local_only,
          short_term: false
        )

      checkpoint = put_checkpoint(context.conversation_id, "The same rule was confirmed")

      response =
        json(%{
          "type" => "candidate",
          "kind" => "rule",
          "content" => "  The project requires  deterministic scoped memory writes  "
        })

      assert {:ok, {:duplicate, duplicate}} =
               Reflector.run(context.conversation_id, checkpoint, opts(context, response))

      assert duplicate.id == existing.id
      assert count_memories(context.workspace_id) == 1
      audit = audit_entry(context.conversation_id, checkpoint)
      assert audit["outcome"] == "duplicate"
      assert audit["content"] == "Skipped a duplicate memory candidate"
      assert audit["engram_id"] == existing.id
    end

    test "malformed, fenced, prose-wrapped, and extra-key JSON do not audit or write", context do
      checkpoint = put_checkpoint(context.conversation_id, "Strict JSON summary")
      before_count = count_memories(context.workspace_id)

      invalid_responses = [
        "not json",
        "```json\n{\"type\":\"ignore\",\"reason\":\"none\"}\n```",
        "Result: {\"type\":\"ignore\",\"reason\":\"none\"}",
        json(%{"type" => "ignore", "reason" => "none", "extra" => true}),
        json(%{"type" => "candidate", "kind" => "unknown", "content" => "durable content"})
      ]

      for response <- invalid_responses do
        assert {:error, _reason} =
                 Reflector.run(context.conversation_id, checkpoint, opts(context, response))

        assert is_nil(find_audit(context.conversation_id, checkpoint))
        assert count_memories(context.workspace_id) == before_count
      end
    end

    test "accepts one strict JSON text block alongside provider reasoning metadata", context do
      checkpoint = put_checkpoint(context.conversation_id, "Reasoned strict JSON summary")

      response_message =
        Message.assistant([
          %{type: "responses_reasoning", id: "reasoning-1", summary: []},
          %{type: "text", text: json(%{"type" => "ignore", "reason" => "No durable memory"})}
        ])

      assert {:ok, :ignored} =
               Reflector.run(
                 context.conversation_id,
                 checkpoint,
                 opts(context, {:messages, [response_message]})
               )

      assert audit_entry(context.conversation_id, checkpoint)["outcome"] == "ignore"
    end

    test "provider errors, exceptions, and tool calls do not audit or write", context do
      checkpoint = put_checkpoint(context.conversation_id, "Provider failure summary")
      before_count = count_memories(context.workspace_id)

      for response <- [
            {:error, :unavailable},
            {:raise, "provider exploded"},
            {:tool_call, "read"}
          ] do
        assert {:error, _reason} =
                 Reflector.run(context.conversation_id, checkpoint, opts(context, response))

        assert is_nil(find_audit(context.conversation_id, checkpoint))
        assert count_memories(context.workspace_id) == before_count
      end
    end

    test "a completed audit makes repeated checkpoint runs idempotent", context do
      checkpoint = put_checkpoint(context.conversation_id, "No durable memory")
      response = json(%{"type" => "ignore", "reason" => "No durable memory"})

      assert {:ok, :ignored} =
               Reflector.run(context.conversation_id, checkpoint, opts(context, response))

      flush_reflector_requests()

      assert {:ok, :already_reflected} =
               Reflector.run(context.conversation_id, checkpoint, opts(context, response))

      refute_receive {:reflector_request, _, _, _}, 50

      assert Enum.count(entries(context.conversation_id), &(&1["id"] == audit_id(checkpoint))) ==
               1
    end

    test "candidate and audit roll back together when the audit store fails", context do
      checkpoint = put_checkpoint(context.conversation_id, "A durable rollback convention")
      before_count = count_memories(context.workspace_id)

      response =
        json(%{
          "type" => "candidate",
          "kind" => "rule",
          "content" => "All reflector candidate writes must remain atomic with their audit"
        })

      run_opts =
        opts(context, response) ++ [transcript_store: @failing_audit_store]

      assert {:error, {:audit_write, :forced_audit_failure}} =
               Reflector.run(context.conversation_id, checkpoint, run_opts)

      assert count_memories(context.workspace_id) == before_count
      assert is_nil(find_audit(context.conversation_id, checkpoint))
    end
  end

  describe "asynchronous APIs" do
    test "maybe_trigger defaults off and honors explicit runtime opt-in", context do
      checkpoint = put_checkpoint(context.conversation_id, "Automatic reflection summary")
      response = json(%{"type" => "ignore", "reason" => "No durable memory"})

      assert :disabled =
               Reflector.maybe_trigger(
                 context.conversation_id,
                 checkpoint,
                 opts(context, response)
               )

      refute_receive {:reflector_request, _, _, _}, 50
      assert is_nil(find_audit(context.conversation_id, checkpoint))

      assert :disabled =
               Reflector.maybe_trigger(
                 context.conversation_id,
                 checkpoint,
                 opts(context, response, reflector_enabled: true)
               )

      refute_receive {:reflector_request, _, _, _}, 50

      assert :disabled =
               Reflector.maybe_trigger(
                 context.conversation_id,
                 checkpoint,
                 opts(context, response,
                   builtin_memory_enabled: false,
                   om: %{reflector_enabled: true}
                 )
               )

      refute_receive {:reflector_request, _, _, _}, 50

      assert {:ok, pid} =
               Reflector.maybe_trigger(
                 context.conversation_id,
                 checkpoint,
                 opts(context, response,
                   builtin_memory_enabled: true,
                   om: %{reflector_enabled: true}
                 )
               )

      await_task(pid)
      assert audit_entry(context.conversation_id, checkpoint)["outcome"] == "ignore"
    end

    test "cancelling the reflector task also terminates its in-flight provider child", context do
      checkpoint = put_checkpoint(context.conversation_id, "Cancellation summary")

      assert {:ok, reflector_pid} =
               Reflector.trigger(context.conversation_id, checkpoint["id"], opts(context, :block))

      assert_receive {:reflector_provider_blocked, provider_pid}, 1_000
      provider_ref = Process.monitor(provider_pid)
      Process.exit(reflector_pid, :kill)

      assert_receive {:DOWN, ^provider_ref, :process, ^provider_pid, _reason}, 1_000
      assert is_nil(find_audit(context.conversation_id, checkpoint))
    end

    test "manual trigger reconstructs effective workspace model settings when opts are absent" do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "handbean_reflector_manual_#{System.unique_integer([:positive])}"
        )

      models_path = Path.join(tmp_dir, "models.json")
      settings_path = Path.join(tmp_dir, ".handbean/settings.jsonc")
      File.mkdir_p!(Path.dirname(settings_path))

      File.write!(
        models_path,
        json(%{
          "providers" => %{
            "reflector-test" => %{
              "baseUrl" => "http://127.0.0.1",
              "api" => "openai-chat-completions",
              "provider" => "openai-compat",
              "models" => [%{"id" => "reflect-model", "name" => "Reflect model"}]
            }
          }
        })
      )

      File.write!(
        settings_path,
        json(%{
          "model_ai" => %{
            "default_model" => "reflector-test/reflect-model",
            "observational_memory" => %{
              "model" => "reflector-test/reflect-model",
              "reasoning" => "off",
              "reflector_enabled" => true
            }
          }
        })
      )

      old_models_file = System.get_env("HANDBEAN_MODELS_FILE")
      old_test_provider = Application.get_env(:handbean, :test_provider)
      response = json(%{"type" => "ignore", "reason" => "No durable memory"})

      System.put_env("HANDBEAN_MODELS_FILE", models_path)

      Application.put_env(:handbean, :test_provider, %{
        module: @provider,
        scenario: :reflector,
        provider_config: %{provider_module: @provider, notify: self(), response: response}
      })

      on_exit(fn ->
        File.rm_rf(tmp_dir)

        if old_models_file,
          do: System.put_env("HANDBEAN_MODELS_FILE", old_models_file),
          else: System.delete_env("HANDBEAN_MODELS_FILE")

        if old_test_provider,
          do: Application.put_env(:handbean, :test_provider, old_test_provider),
          else: Application.delete_env(:handbean, :test_provider)
      end)

      workspace_id = "manual-settings-#{System.unique_integer([:positive])}"

      {:ok, conversation} =
        Handbean.ConversationStore.create(workspace_id,
          title: "Manual settings",
          checkout_path: tmp_dir
        )

      checkpoint = put_checkpoint(conversation["id"], "Manual settings summary")
      assert {:ok, pid} = Reflector.trigger(conversation["id"])
      await_task(pid)

      assert_receive {:reflector_request, [%Message{}], [], config}
      assert config.model == "reflect-model"
      assert audit_entry(conversation["id"], checkpoint)["outcome"] == "ignore"
    end

    test "manual trigger supports explicit and latest checkpoint loading without opt-in",
         context do
      first = put_checkpoint(context.conversation_id, "First manual summary")
      second = put_checkpoint(context.conversation_id, "Latest manual summary")
      response = json(%{"type" => "ignore", "reason" => "No durable memory"})

      assert {:ok, first_pid} =
               Reflector.trigger(
                 context.conversation_id,
                 first["id"],
                 opts(context, response)
               )

      await_task(first_pid)
      assert audit_entry(context.conversation_id, first)["outcome"] == "ignore"
      assert is_nil(find_audit(context.conversation_id, second))

      assert {:ok, latest_pid} =
               Reflector.trigger(context.conversation_id, :latest, opts(context, response))

      await_task(latest_pid)
      assert audit_entry(context.conversation_id, second)["outcome"] == "ignore"
    end
  end

  defp opts(context, response, overrides \\ []) do
    base = [
      workspace_id: context.workspace_id,
      provider_config: %{
        provider_module: @provider,
        notify: self(),
        response: response,
        model: "reflector-test-model"
      }
    ]

    Keyword.merge(base, overrides)
  end

  defp put_checkpoint(conversation_id, summary) do
    source = %{
      "id" => "checkpoint-source-#{System.unique_integer([:positive])}",
      "content_type" => "user_msg",
      "message_type" => "message",
      "role" => "user",
      "direction" => "inbound",
      "content" => "Source material for the checkpoint"
    }

    assert {:ok, persisted_source} =
             ConversationTranscriptStore.append(conversation_id, source)

    checkpoint = %{
      "id" => "checkpoint-#{System.unique_integer([:positive])}",
      "content_type" => "model_compaction",
      "message_type" => "internal",
      "role" => "internal",
      "direction" => "internal",
      "version" => 1,
      "summary" => summary,
      "first_entry_id" => persisted_source["id"],
      "covered_through_id" => persisted_source["id"],
      "source_count" => 1,
      "source_digest" => CompactionCheckpoint.digest([persisted_source])
    }

    assert {:ok, persisted} =
             ConversationTranscriptStore.append(conversation_id, checkpoint)

    persisted
  end

  defp entries(conversation_id) do
    assert {:ok, entries} = ConversationTranscriptStore.list(conversation_id)
    entries
  end

  defp audit_entry(conversation_id, checkpoint) do
    assert audit = find_audit(conversation_id, checkpoint)
    audit
  end

  defp find_audit(conversation_id, checkpoint) do
    Enum.find(entries(conversation_id), &(&1["id"] == audit_id(checkpoint)))
  end

  defp audit_id(checkpoint), do: "memory-reflection-#{checkpoint["id"]}"

  defp count_memories(workspace_id) do
    MemoryStore.list_engrams(
      workspace_id: workspace_id,
      scope: :workspace,
      privacy_mode: :local_only,
      lifecycle: :all
    )
    |> length()
  end

  defp json(value), do: Handbean.JSON.encode!(value)

  defp await_task(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
  end

  defp flush_reflector_requests do
    receive do
      {:reflector_request, _, _, _} -> flush_reflector_requests()
    after
      0 -> :ok
    end
  end
end
