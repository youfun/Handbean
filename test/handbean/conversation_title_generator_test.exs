defmodule Handbean.ConversationTitleGeneratorTest do
  use Handbean.DataCase, async: false

  alias Handbean.ConversationTitleGenerator
  alias Handbean.Agent.Message

  defp isolate_conversation_home! do
    old_home = System.get_env("HOME")

    home_dir =
      Path.join(System.tmp_dir!(), "sigil_title_home_#{System.unique_integer([:positive])}")

    System.put_env("HOME", home_dir)

    on_exit(fn ->
      if old_home, do: System.put_env("HOME", old_home), else: System.delete_env("HOME")
      if File.exists?(home_dir), do: File.rm_rf!(home_dir)
    end)

    home_dir
  end

  # ── Mock provider for synchronous testing ──

  defmodule MockProvider do
    @behaviour Handbean.Agent.Provider

    def complete(_messages, _tool_defs, config) do
      title = Map.get(config, :mock_title, "Test Title")

      {:ok,
       %{
         stop_reason: :end_turn,
         messages: [%Message{role: :assistant, content: title}],
         usage: %{input_tokens: 10, output_tokens: 3}
       }}
    end
  end

  describe "build_title_prompt/1" do
    test "wraps the first user message in a system prompt" do
      prompt = ConversationTitleGenerator.build_title_prompt("Build a REST API with Phoenix")

      assert prompt =~ "concise title"
      assert prompt =~ "Build a REST API with Phoenix"
      assert prompt =~ "2 to 5 words"
      assert prompt =~ "SAME language"
      assert prompt =~ "Do NOT include"
    end

    test "truncates very long first messages" do
      long_msg = String.duplicate("very long message ", 50)
      prompt = ConversationTitleGenerator.build_title_prompt(long_msg)
      # 200 chars of content limit
      assert String.length(long_msg) > 200
      refute prompt =~ String.slice(long_msg, 0..300)
    end
  end

  describe "extract_title/1" do
    test "returns trimmed text from a single-line response" do
      assert {:ok, "Phoenix REST API"} =
               ConversationTitleGenerator.extract_title("Phoenix REST API")
    end

    test "trims whitespace and quotes" do
      assert {:ok, "User Authentication"} =
               ConversationTitleGenerator.extract_title("  \"User Authentication\"  ")
    end

    test "trims trailing period" do
      assert {:ok, "Database Migration Strategy"} =
               ConversationTitleGenerator.extract_title("Database Migration Strategy.")
    end

    test "rejects empty responses" do
      assert {:error, :empty} = ConversationTitleGenerator.extract_title("")
      assert {:error, :empty} = ConversationTitleGenerator.extract_title("   ")
    end

    test "strips generic summary prefixes and capitalizes the rest" do
      assert {:ok, "Build a guide"} =
               ConversationTitleGenerator.extract_title("The user wants to build a guide")

      assert {:ok, "Project analysis"} =
               ConversationTitleGenerator.extract_title("User asks for project analysis")

      assert {:ok, "Setup"} =
               ConversationTitleGenerator.extract_title("This conversation covers setup")
    end

    test "rejects overly long responses (capped at 80 chars)" do
      assert {:ok, title} =
               ConversationTitleGenerator.extract_title(String.duplicate("A", 80))

      assert String.length(title) <= 80
    end
  end

  describe "maybe_generate/4" do
    setup do
      isolate_conversation_home!()
      :ok
    end

    test "skips when conversation has a custom manual title", _ctx do
      {:ok, conv} =
        Handbean.ConversationStore.create("ws_auto",
          id: "conv-manual-title",
          title: "My Custom Title",
          title_source: "manual"
        )

      assert :skip = ConversationTitleGenerator.maybe_generate(conv["id"], "Hello world", %{})
    end

    test "spawns a task when conversation has default title", _ctx do
      {:ok, conv} =
        Handbean.ConversationStore.create("ws_auto",
          id: "conv-default",
          title: "New chat",
          title_source: "manual"
        )

      result =
        ConversationTitleGenerator.maybe_generate(conv["id"], "Hello world", %{
          api_key: "mock-key",
          provider_module: MockProvider
        })

      assert {:ok, pid} = result
      assert is_pid(pid)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
    end

    test "spawns a task for conversation with auto title_source but default title", _ctx do
      {:ok, conv} =
        Handbean.ConversationStore.create("ws_auto",
          id: "conv-auto-default",
          title: "New chat #2",
          title_source: "auto"
        )

      result =
        ConversationTitleGenerator.maybe_generate(conv["id"], "Hello world", %{
          api_key: "mock-key",
          provider_module: MockProvider
        })

      assert {:ok, pid} = result
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
    end

    test "skips when API key is missing", _ctx do
      {:ok, conv} =
        Handbean.ConversationStore.create("ws_auto",
          id: "conv-no-key",
          title: "New chat"
        )

      System.delete_env("OPENAI_API_KEY")
      assert :skip = ConversationTitleGenerator.maybe_generate(conv["id"], "Hello world", %{})
    end

    test "returns :skip when conversation not found", _ctx do
      assert :skip =
               ConversationTitleGenerator.maybe_generate("nonexistent-id", "Hello world", %{})
    end
  end

  describe "do_generate/3 (synchronous, with mock provider)" do
    setup do
      test_id = System.unique_integer([:positive])
      isolate_conversation_home!()

      # Create a conversation with default title
      {:ok, conv} =
        Handbean.ConversationStore.create("ws_sync_test",
          id: "conv-sync-#{test_id}",
          title: "New chat"
        )

      {:ok, conv: conv}
    end

    test "does not overwrite a manual title set after generation started", %{conv: conv} do
      assert {:ok, _} = Handbean.ConversationStore.rename(conv["id"], "用户改过的名字")

      config = %{
        api_key: "mock-key",
        model: "test-model",
        base_url: "http://localhost",
        api: :openai,
        mock_title: "Phoenix API Builder",
        provider_module: MockProvider
      }

      ConversationTitleGenerator.do_generate(conv["id"], "Build a REST API", config)

      {:ok, updated} = Handbean.ConversationStore.get(conv["id"])
      assert updated["title"] == "用户改过的名字"
      assert updated["title_source"] == "manual"
    end

    test "updates conversation title after successful generation", %{conv: conv} do
      config = %{
        api_key: "mock-key",
        model: "test-model",
        base_url: "http://localhost",
        api: :openai,
        mock_title: "Phoenix API Builder",
        # Inject mock provider module for testing
        provider_module: MockProvider
      }

      # Call do_generate directly (synchronous)
      ConversationTitleGenerator.do_generate(conv["id"], "Build a REST API", config)

      {:ok, updated} = Handbean.ConversationStore.get(conv["id"])
      assert updated["title"] == "Phoenix API Builder"
      assert updated["title_source"] == "auto"
    end

    test "falls back to message truncation when response is empty", %{conv: conv} do
      config = %{
        api_key: "mock-key",
        model: "test-model",
        base_url: "http://localhost",
        api: :openai,
        mock_title: "",
        provider_module: MockProvider
      }

      ConversationTitleGenerator.do_generate(
        conv["id"],
        "Hello, how do I setup Phoenix project?",
        config
      )

      {:ok, updated} = Handbean.ConversationStore.get(conv["id"])
      assert updated["title"] == "Hello, how do I setup Phoen..."
      assert updated["title_source"] == "auto"
    end

    test "title request drops reasoning and uses a short timeout" do
      config =
        ConversationTitleGenerator.title_provider_config(%{
          api_key: "mock-key",
          model: "slow-thinker",
          reasoning: %{effort: "high"},
          reasoning_effort: "high",
          thinking: %{type: "enabled"},
          conversation_id: "conv-1",
          provider_state: %{cursor_session_id: "busy"},
          receive_timeout: 180_000,
          notify_pid: self(),
          req_options: [receive_timeout: 180_000]
        })

      refute Map.has_key?(config, :reasoning)
      refute Map.has_key?(config, :thinking)
      refute Map.has_key?(config, :conversation_id)
      refute Map.has_key?(config, :provider_state)
      assert config.receive_timeout == 20_000
      assert config.max_tokens == 64
      assert config.max_retries == 0
      assert config.retry_count == 0
      assert config.notify_pid == self()
      assert Keyword.get(config.req_options, :receive_timeout) == 20_000
    end

    test "notifies the caller when a title is saved", %{conv: conv} do
      config = %{
        api_key: "mock-key",
        model: "test-model",
        base_url: "http://localhost",
        api: :openai,
        mock_title: "模型列表展示不一致",
        provider_module: MockProvider,
        notify_pid: self()
      }

      conv_id = conv["id"]
      ConversationTitleGenerator.do_generate(conv_id, "模型列表怎么不一致", config)

      assert_receive {:conversation_title_ready, ^conv_id, "模型列表展示不一致"}, 500
    end

    test "broadcasts conversation_updated after successful generation", %{conv: conv} do
      topic = "conversation:updated"
      Phoenix.PubSub.subscribe(Handbean.PubSub, topic)

      config = %{
        api_key: "mock-key",
        model: "test-model",
        base_url: "http://localhost",
        api: :openai,
        mock_title: "Phoenix API Builder",
        provider_module: MockProvider
      }

      conv_id = conv["id"]
      ConversationTitleGenerator.do_generate(conv_id, "Build a REST API", config)

      assert_receive {:conversation_updated, ^conv_id}, 500
    end

    test "uses text blocks and ignores thinking blocks for title", %{conv: conv} do
      defmodule BlockProvider do
        @behaviour Handbean.Agent.Provider

        def complete(_messages, _tool_defs, _config) do
          {:ok,
           %{
             stop_reason: :end_turn,
             messages: [
               %Message{
                 role: :assistant,
                 content: [
                   %{type: "thinking", thinking: "The user wants a concise title"},
                   %{type: "text", text: "项目使用指南"}
                 ]
               }
             ],
             usage: %{input_tokens: 10, output_tokens: 3}
           }}
        end
      end

      config = %{
        api_key: "mock-key",
        model: "test-model",
        base_url: "http://localhost",
        api: :openai,
        provider_module: BlockProvider
      }

      ConversationTitleGenerator.do_generate(conv["id"], "写一个使用指南", config)

      {:ok, updated} = Handbean.ConversationStore.get(conv["id"])
      assert updated["title"] == "项目使用指南"
      assert updated["title_source"] == "auto"
    end

    test "falls back to message truncation when provider returns error", %{conv: conv} do
      defmodule ErrorProvider do
        @behaviour Handbean.Agent.Provider
        def complete(_messages, _tool_defs, _config) do
          {:error, :timeout}
        end
      end

      config = %{
        api_key: "mock-key",
        model: "test-model",
        base_url: "http://localhost",
        api: :openai,
        provider_module: ErrorProvider
      }

      ConversationTitleGenerator.do_generate(
        conv["id"],
        "Hello, how do I setup Phoenix project?",
        config
      )

      {:ok, updated} = Handbean.ConversationStore.get(conv["id"])
      assert updated["title"] == "Hello, how do I setup Phoen..."
      assert updated["title_source"] == "auto"
    end

    test "falls back when the provider hangs past the deadline", %{conv: conv} do
      defmodule HangProvider do
        @behaviour Handbean.Agent.Provider

        def complete(_messages, _tool_defs, _config) do
          Process.sleep(5_000)
          {:error, :too_late}
        end
      end

      config = %{
        api_key: "mock-key",
        model: "slow-thinker",
        base_url: "http://localhost",
        api: :openai,
        provider_module: HangProvider,
        title_timeout_ms: 50
      }

      started = System.monotonic_time(:millisecond)

      ConversationTitleGenerator.do_generate(
        conv["id"],
        "Hello, how do I setup Phoenix project?",
        config
      )

      elapsed = System.monotonic_time(:millisecond) - started
      assert elapsed < 1_000

      {:ok, updated} = Handbean.ConversationStore.get(conv["id"])
      assert updated["title"] == "Hello, how do I setup Phoen..."
    end
  end

  describe "publish_provisional/2" do
    setup do
      isolate_conversation_home!()
      :ok
    end

    test "writes a summary before the model returns" do
      {:ok, conv} =
        Handbean.ConversationStore.create("ws_auto",
          id: "conv-provisional",
          title: "New chat",
          title_source: "manual"
        )

      Phoenix.PubSub.subscribe(Handbean.PubSub, "conversation:updated")

      assert {:ok, "模型列表怎么不一致"} =
               ConversationTitleGenerator.publish_provisional(conv["id"], "模型列表怎么不一致")

      {:ok, updated} = Handbean.ConversationStore.get(conv["id"])
      assert updated["title"] == "模型列表怎么不一致"
      assert updated["title_source"] == "fallback"
      assert_receive {:conversation_title_ready, "conv-provisional", "模型列表怎么不一致"}, 500
    end

    test "does not replace a manual title" do
      {:ok, conv} =
        Handbean.ConversationStore.create("ws_auto",
          id: "conv-provisional-manual",
          title: "Keep me",
          title_source: "manual"
        )

      assert :skip =
               ConversationTitleGenerator.publish_provisional(conv["id"], "something else")

      {:ok, updated} = Handbean.ConversationStore.get(conv["id"])
      assert updated["title"] == "Keep me"
    end

    test "still generates a model title after a provisional summary" do
      {:ok, conv} =
        Handbean.ConversationStore.create("ws_auto",
          id: "conv-after-fallback",
          title: "模型列表怎么不一致",
          title_source: "fallback"
        )

      result =
        ConversationTitleGenerator.maybe_generate(conv["id"], "模型列表怎么不一致", %{
          api_key: "mock-key",
          provider_module: MockProvider
        })

      assert {:ok, pid} = result
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
    end
  end

  describe "fallback_title/1" do
    test "returns the original message if it is short" do
      assert "Hello world" == ConversationTitleGenerator.fallback_title("Hello world")
    end

    test "replaces newlines and tabs with spaces" do
      assert "Line 1 Line 2" == ConversationTitleGenerator.fallback_title("Line 1\nLine 2")
    end

    test "truncates to 30 characters and appends ellipses if long" do
      long_msg =
        "This is a very long message that explains what the user wants to do in this conversation"

      assert "This is a very long message..." ==
               ConversationTitleGenerator.fallback_title(long_msg)
    end
  end

  describe "resolve_provider/1" do
    test "resolves provider 'stepfun' to StepFun module" do
      assert Handbean.Agent.Provider.StepFun ==
               ConversationTitleGenerator.resolve_provider(%{
                 provider: "stepfun",
                 api: :stepfun
               })
    end

    test "resolves provider 'stepfun-step-plan' to StepFun module" do
      assert Handbean.Agent.Provider.StepFun ==
               ConversationTitleGenerator.resolve_provider(%{
                 provider: "stepfun-step-plan",
                 api: :stepfun
               })
    end

    test "resolves api :stepfun without provider to StepFun module" do
      assert Handbean.Agent.Provider.StepFun ==
               ConversationTitleGenerator.resolve_provider(%{
                 api: :stepfun
               })
    end

    test "resolves provider 'anthropic' to Anthropic module" do
      assert Handbean.Agent.Provider.Anthropic ==
               ConversationTitleGenerator.resolve_provider(%{
                 provider: "anthropic",
                 api: :anthropic
               })
    end

    test "resolves api :openai without provider to OpenAICompat module" do
      assert Handbean.Agent.Provider.OpenAICompat ==
               ConversationTitleGenerator.resolve_provider(%{
                 api: :openai
               })
    end

    test "resolves api :openai_responses to OpenAI Responses module" do
      assert Handbean.Agent.Provider.OpenAI ==
               ConversationTitleGenerator.resolve_provider(%{
                 api: :openai_responses
               })
    end

    test "resolves provider 'openai' to OpenAI Responses module" do
      assert Handbean.Agent.Provider.OpenAI ==
               ConversationTitleGenerator.resolve_provider(%{
                 provider: "openai",
                 api: :openai_responses
               })
    end

    test "resolves api :anthropic without provider to Anthropic module" do
      assert Handbean.Agent.Provider.Anthropic ==
               ConversationTitleGenerator.resolve_provider(%{
                 api: :anthropic
               })
    end

    test "defaults to OpenAICompat for unknown provider/api" do
      assert Handbean.Agent.Provider.OpenAICompat ==
               ConversationTitleGenerator.resolve_provider(%{})
    end
  end
end
