defmodule Handbean.ConversationCollaborationTargetRuntimeTest do
  use Handbean.DataCase, async: false

  alias Handbean.ConversationCollaborationSupport, as: Support
  alias Handbean.ConversationCollaborationSupport.HoldProvider
  alias Handbean.{ConversationStore, ConversationTranscriptStore}
  alias Handbean.Conversations.Collaboration

  setup do
    Support.setup()
  end

  test "cross-workspace creation uses the target default model and reasoning", c do
    File.write!(
      System.get_env("HANDBEAN_MODELS_FILE"),
      ~s({"defaultProvider":"fake","defaultModel":"fake-model","providers":{"fake":{"baseUrl":"http://localhost","api":"openai-chat-completions","apiKey":"fake","models":[{"id":"fake-model","name":"Fake"}]},"other":{"baseUrl":"http://127.0.0.1:9","api":"openai-chat-completions","apiKey":"other-key","provider":"openai-compat","models":[{"id":"other-model","name":"Other","reasoning":true,"reasoningLevels":["low","high"],"defaultReasoning":"high"}]}}})
    )

    target_path = Path.join(c.context.conversation_run_opts[:workspace_path], "remote-workspace")
    File.mkdir_p!(target_path)
    {:ok, target_workspace} = Handbean.WorkspaceStore.add(target_path, name: "Remote")

    settings_path = Handbean.WorkspaceSettings.path(target_path)
    File.mkdir_p!(Path.dirname(settings_path))

    File.write!(
      settings_path,
      Handbean.JSON.encode!(%{
        "models" => %{
          "version" => 1,
          "default" => %{"provider" => "other", "model" => "other-model"},
          "allow" => %{"providers" => %{"other" => %{"models" => ["other-model"]}}}
        }
      })
    )

    context = Map.put(c.context, :approval_mode, :yolo)

    input = %{
      "title" => "Remote task",
      "message" => "Use target defaults",
      "request_id" => "remote-default",
      "workspace" => target_workspace["id"]
    }

    assert {:ok, receipt} = Collaboration.create(input, context)
    assert receipt.workspace == target_workspace["id"]
    assert receipt.model == "other/other-model"
    assert receipt.reasoning_level == "high"
    assert_receive {:held, provider, config}, 2_000
    assert config.model == "other-model"
    assert config.working_directory == target_workspace["default_checkout_path"]

    assert {:ok, meta} = ConversationStore.get_metadata(receipt.conversation)
    assert meta["workspace_id"] == target_workspace["id"]
    assert meta["selected_model"] == "other/other-model"
    assert meta["selected_reasoning_level"] == "high"

    send(provider, :release)

    current_input =
      Map.merge(input, %{
        "request_id" => "remote-current",
        "model" => "current",
        "reasoning_level" => "low"
      })

    assert {:ok, current} = Collaboration.create(current_input, context)
    assert current.model == "other/other-model"
    assert current.reasoning_level == "low"
    assert_receive {:held, current_provider, _config}, 2_000
    send(current_provider, :release)

    assert {:error, :target_model_unavailable} =
             Collaboration.create(
               Map.merge(input, %{
                 "request_id" => "remote-source-model",
                 "model" => "fake/fake-model"
               }),
               context
             )

    assert {:error, :invalid_reasoning_level} =
             Collaboration.create(
               Map.merge(input, %{
                 "request_id" => "remote-bad-reasoning",
                 "reasoning_level" => "medium"
               }),
               context
             )

    empty_path = Path.join(c.context.conversation_run_opts[:workspace_path], "empty-workspace")
    File.mkdir_p!(empty_path)
    {:ok, empty_workspace} = Handbean.WorkspaceStore.add(empty_path, name: "Empty")
    empty_settings = Handbean.WorkspaceSettings.path(empty_path)
    File.mkdir_p!(Path.dirname(empty_settings))

    File.write!(
      empty_settings,
      Handbean.JSON.encode!(%{
        "models" => %{
          "version" => 1,
          "allow" => %{"providers" => %{"missing" => %{"models" => ["none"]}}}
        }
      })
    )

    assert {:error, :target_model_unavailable} =
             Collaboration.create(
               Map.merge(input, %{
                 "request_id" => "remote-no-default",
                 "workspace" => empty_workspace["id"]
               }),
               context
             )

    File.write!(
      empty_settings,
      Handbean.JSON.encode!(%{
        "models" => %{
          "version" => 1,
          "allow" => %{"providers" => %{"other" => %{"models" => ["other-model"]}}}
        }
      })
    )

    for {request_id, model} <- [
          {"remote-missing-default", nil},
          {"remote-current-without-default", "current"}
        ] do
      missing_default_input =
        input
        |> Map.merge(%{"request_id" => request_id, "workspace" => empty_workspace["id"]})
        |> then(fn request -> if model, do: Map.put(request, "model", model), else: request end)

      assert {:error, :target_model_unavailable} =
               Collaboration.create(missing_default_input, context)
    end

    assert {:ok, explicit} =
             Collaboration.create(
               Map.merge(input, %{
                 "request_id" => "remote-explicit-without-default",
                 "workspace" => empty_workspace["id"],
                 "model" => "other/other-model"
               }),
               context
             )

    assert explicit.model == "other/other-model"
    assert_receive {:held, explicit_provider, _config}, 2_000
    send(explicit_provider, :release)
  end

  test "cross-workspace request runs with target facts and returns only on its handoff", c do
    File.write!(System.get_env("HANDBEAN_MODELS_FILE"), Support.catalog())

    source_path = Path.join(c.context.conversation_run_opts[:workspace_path], "cross-source")
    target_path = Path.join(c.context.conversation_run_opts[:workspace_path], "cross-target")
    File.mkdir_p!(source_path)
    File.mkdir_p!(target_path)
    {:ok, source_workspace} = Handbean.WorkspaceStore.add(source_path, name: "Cross Source")
    {:ok, target_workspace} = Handbean.WorkspaceStore.add(target_path, name: "Cross Target")

    for {path, provider, model} <- [
          {source_path, "fake", "fake-model"},
          {target_path, "other", "other-model"}
        ] do
      settings_path = Handbean.WorkspaceSettings.path(path)
      File.mkdir_p!(Path.dirname(settings_path))

      File.write!(
        settings_path,
        Handbean.JSON.encode!(%{
          "models" => %{
            "version" => 1,
            "default" => %{"provider" => provider, "model" => model},
            "allow" => %{"providers" => %{provider => %{"models" => [model]}}}
          }
        })
      )
    end

    {:ok, source} =
      ConversationStore.create(source_workspace["id"],
        checkout_path: source_path,
        selected_model: "fake/fake-model"
      )

    {:ok, target} =
      ConversationStore.create(target_workspace["id"],
        checkout_path: target_path,
        selected_model: "other/other-model"
      )

    context = %{
      conversation_id: source["id"],
      workspace_id: source_workspace["id"],
      run_id: "cross-source-run",
      approval_mode: :yolo,
      conversation_run_opts: [
        workspace_path: source_path,
        working_directory: source_path,
        model: "fake/fake-model",
        provider: HoldProvider,
        provider_config: %{notify: self()},
        tools: [],
        source: :cli,
        workspace_id: source_workspace["id"],
        streaming: false
      ]
    }

    assert {:ok, receipt} =
             Collaboration.send_message(
               %{
                 "conversation" => target["id"],
                 "message" => "Cross workspace request",
                 "request_id" => "cross-request",
                 "purpose" => "request"
               },
               context
             )

    assert receipt.delivery == "started"
    assert_receive {:held, target_provider, target_config}, 2_000
    assert target_config.model == "other-model"
    assert target_config.working_directory == target["checkout_path"]
    send(target_provider, :release)

    assert_receive {:held, return_provider, return_config}, 4_000
    assert return_config.model == "fake-model"
    assert return_config.working_directory == source["checkout_path"]
    send(return_provider, :release)

    assert {:ok, entries} = ConversationTranscriptStore.list(source["id"])

    assert Enum.any?(entries, fn entry ->
             entry["content_type"] == "user_msg" and
               get_in(entry, ["origin", "handoff_id"]) == receipt.handoff_id and
               get_in(entry, ["origin", "automatic_report"]) == true
           end)
  end

  test "target wakeup rebuilds model, identity, checkout and permission from target facts", c do
    File.write!(System.get_env("HANDBEAN_MODELS_FILE"), Support.catalog())

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
end
