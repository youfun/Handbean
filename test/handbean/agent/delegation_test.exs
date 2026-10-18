defmodule Handbean.Agent.DelegationTest do
  use Handbean.DataCase, async: false

  alias Handbean.Agent.{Config, Coordinator, Delegation, Message, State}
  alias Handbean.Agent.Delegation.Policy
  alias Handbean.Agent.Subagent.Profile
  alias Handbean.Agent.Tool.Executor
  alias Handbean.ConversationStore

  defmodule BlockingProvider do
    @behaviour Handbean.Agent.Provider
    def complete(messages, defs, config) do
      send(config.notify, {:provider, config.label, self(), messages, defs, config})

      receive do
        :crash ->
          exit(:deliberate_child_crash)

        :approval ->
          {:ok,
           %{
             stop_reason: :tool_use,
             messages: [
               Message.tool_use([
                 %{
                   type: "tool_use",
                   id: "read-call",
                   name: "read",
                   input: %{"path" => "sample.ex"}
                 }
               ])
             ],
             usage: %{input_tokens: 11, output_tokens: 2},
             response_metadata: %{}
           }}

        {:error, reason} ->
          {:error, reason}

        :finish ->
          {:ok,
           %{
             stop_reason: :end_turn,
             messages: [Message.assistant("Evidence: lib/sample.ex:17")],
             usage: %{input_tokens: 7, output_tokens: 3},
             response_metadata: %{}
           }}
      end
    end

    def stream(messages, defs, config, _callback), do: complete(messages, defs, config)
  end

  setup do
    old_home = System.get_env("HOME")
    home = Path.join(System.tmp_dir!(), "delegation-#{Ecto.UUID.generate()}")
    File.mkdir_p!(home)
    System.put_env("HOME", home)
    unless Process.whereis(Delegation), do: start_supervised!(Delegation)
    {:ok, parent} = ConversationStore.create("workspace")

    opts = [
      workspace_path: home,
      working_directory: home,
      workspace_id: "workspace",
      model: "fake",
      provider: BlockingProvider,
      provider_config: %{notify: self(), label: :parent},
      tools: [],
      source: :cli,
      middleware: [],
      mcp: false
    ]

    {:ok, ack} = Coordinator.add_message(parent["id"], "Parent secret not inherited", opts)
    assert_receive {:provider, :parent, _, _, _, _}, 2_000

    context = %{
      conversation_id: parent["id"],
      workspace_id: "workspace",
      run_id: ack.run_id,
      runner_pid: ack.run_pid,
      tool_call_id: "task-1",
      working_directory: home,
      tool_timeout: 60_000,
      authorized_tools: ["read", "write", "task"],
      delegation_config:
        Config.from_opts(opts |> Keyword.put(:provider_config, %{notify: self(), label: :child}))
    }

    on_exit(fn ->
      ref = Process.monitor(ack.run_pid)
      Coordinator.cancel(parent["id"])

      receive do
        {:DOWN, ^ref, :process, _, _} -> :ok
      after
        2_000 -> Process.demonitor(ref, [:flush])
      end

      sync_runtime_observers()
      if old_home, do: System.put_env("HOME", old_home), else: System.delete_env("HOME")
      remove_tree(home)
    end)

    %{context: context, parent: parent}
  end

  defp remove_tree(path, attempts \\ 10)

  defp remove_tree(path, attempts) when attempts > 0 do
    case File.rm_rf(path) do
      {:ok, _files} ->
        :ok

      {:error, _reason, _file} ->
        Process.sleep(20)
        remove_tree(path, attempts - 1)
    end
  end

  defp remove_tree(path, 0), do: File.rm_rf!(path)

  defp sync_runtime_observers do
    for name <- [Handbean.Runtime.TaskTracker, Handbean.Schedule.Recorder],
        pid = Process.whereis(name),
        is_pid(pid) do
      :sys.get_state(pid)
    end
  end

  defp delegate(context) do
    Task.async(fn ->
      Handbean.Tool.Builtin.Task.execute(
        %{"task" => "Find evidence", "criteria" => "Include exact line", "background" => false},
        context
      )
    end)
  end

  test "deadline is half the outer timeout, capped, and low limits fail before startup" do
    assert Policy.budget(60_000) == {:ok, 30_000}
    assert Policy.budget(10_000) == {:ok, 5_000}
    assert Policy.budget(120_000) == {:ok, 45_000}
    assert {:error, _} = Policy.budget(3_999)
  end

  test "manual advisor tasks use task and criteria as the child prompt", %{context: context} do
    task =
      Task.async(fn ->
        Handbean.Tool.Builtin.Task.execute(
          %{
            "task" => "Review the proposed approach",
            "criteria" => "Identify the highest-risk assumption",
            "subagent_type" => "advisor",
            "background" => false
          },
          context
        )
      end)

    assert_receive {:provider, :child, child, messages, _, _}, 2_000
    prompt = Enum.map_join(messages, "\n", &Message.text/1)
    assert prompt =~ "Review the proposed approach"
    assert prompt =~ "Identify the highest-risk assumption"

    send(child, :finish)
    assert {:ok, _, _} = Task.await(task, 5_000)
  end

  test "independent context, raw usage once, no visible child or notification", %{
    context: context,
    parent: parent
  } do
    task = delegate(context)
    assert_receive {:provider, :child, child, messages, defs, _}, 2_000
    assert Enum.map(defs, & &1.name) -- ["read"] == []
    refute Enum.any?(messages, &(Message.text(&1) =~ "Parent secret"))
    assert Enum.any?(messages, &(Message.text(&1) =~ "Include exact line"))
    assert ConversationStore.list() |> Enum.map(& &1["id"]) == [parent["id"]]

    [internal] =
      Enum.filter(ConversationStore.list(include_internal?: true), &ConversationStore.internal?/1)

    assert {:error, :not_found} = ConversationStore.get(internal["id"])
    assert {:ok, _} = ConversationStore.get(internal["id"], access_context: context)
    assert {:error, :not_found} = Handbean.ConversationTranscriptStore.list(internal["id"])

    assert {:ok, [_]} =
             Handbean.ConversationTranscriptStore.list(internal["id"], access_context: context)

    state = %{tasks: %{}, viewers: %{}}

    assert {:noreply, ^state} =
             Handbean.Runtime.TaskTracker.handle_info(
               {:run_lifecycle, internal["id"], :run_start, %{}},
               state
             )

    child_ref = Process.monitor(child)
    send(child, :finish)
    assert {:ok, text, details} = Task.await(task, 5_000)
    assert text =~ "lib/sample.ex:17"
    assert details.usage.input_tokens == 7
    assert_receive {:DOWN, ^child_ref, :process, ^child, _}, 2_000
    assert Registry.lookup(Handbean.AgentRunRegistry, internal["id"]) == []
    assert %{input_tokens: 0} = elem(ConversationStore.get_token_usage(parent["id"]), 1)

    assert %{details.child_run_id => %{"input_tokens" => 7}} ==
             Map.new(ConversationStore.delegated_usage(parent["id"]), fn {id, usage} ->
               {id, Map.take(usage, ["input_tokens"])}
             end)

    ConversationStore.record_delegated_usage(parent["id"], details.child_run_id, %{
      input_tokens: 99
    })

    assert ConversationStore.delegated_usage(parent["id"])[details.child_run_id]["input_tokens"] ==
             7
  end

  test "parallel background researchers all provision and persist one inbound", %{
    context: context
  } do
    results =
      1..4
      |> Task.async_stream(
        fn index ->
          Handbean.Tool.Builtin.Task.execute(
            %{
              "task" => "Find evidence #{index}",
              "criteria" => "Return one line",
              "background" => true
            },
            %{context | tool_call_id: "parallel-task-#{index}"}
          )
        end,
        max_concurrency: 4,
        ordered: false,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, {:ok, _ack, details}} -> details end)

    assert length(results) == 4
    assert Enum.all?(results, &(&1.status == :running))
    assert length(Enum.uniq_by(results, & &1.child_conversation_id)) == 4

    children =
      for _ <- 1..4 do
        assert_receive {:provider, :child, child, _, _, _}, 5_000
        child
      end

    refs = Enum.map(children, &{Process.monitor(&1), &1})
    Enum.each(children, &send(&1, :finish))

    for {ref, child} <- refs do
      assert_receive {:DOWN, ^ref, :process, ^child, _}, 5_000
    end

    ids = MapSet.new(results, & &1.child_conversation_id)

    assert_eventually(fn ->
      assert {:ok, sessions} = Delegation.status(context.conversation_id, :list)

      completed =
        sessions
        |> Enum.filter(&MapSet.member?(ids, &1.child_conversation_id))
        |> Enum.filter(&(&1.status in [:completed, "completed"]))

      assert length(completed) == 4
    end)

    internal_ids =
      ConversationStore.list(include_internal?: true)
      |> Enum.filter(&ConversationStore.internal?/1)
      |> MapSet.new(& &1["id"])

    assert MapSet.subset?(ids, internal_ids)

    for id <- ids do
      assert {:ok, entries} =
               Handbean.ConversationTranscriptStore.list(id, access_context: context)

      inbound = Enum.filter(entries, &(&1["role"] == "user"))
      assert [%{"sequence" => 1}] = inbound
    end
  end

  test "startup failures retain a sanitized stage-specific error", %{context: context} do
    missing = Path.join(context.working_directory, "missing-checkout")

    task =
      Task.async(fn ->
        Handbean.Tool.Builtin.Task.execute(
          %{"task" => "Fail before launch", "criteria" => "Expose the startup reason"},
          %{context | working_directory: missing}
        )
      end)

    assert {:ok, _text, %{child_conversation_id: child_id, status: :running}} =
             Task.await(task, 5_000)

    assert_eventually(fn ->
      assert {:ok, %{status: :startup_failed, error: error}} =
               Delegation.status(context.conversation_id, :get, child_id)

      assert error =~ "create_conversation"
      assert error =~ "invalid_checkout_path"
      refute error =~ missing
    end)
  end

  test "shorter deadline stops provider and Runner before returning", %{context: context} do
    task = delegate(%{context | tool_timeout: 4_000})
    assert_receive {:provider, :child, child, _, _, _}, 2_000
    ref = Process.monitor(child)
    assert {:error, _, %{status: :timed_out, usage_complete?: false}} = Task.await(task, 5_000)
    assert_receive {:DOWN, ^ref, :process, ^child, _}, 1_000
  end

  test "parent supervisor teardown does not own child cleanup", %{context: context} do
    task = delegate(context)
    assert_receive {:provider, :child, child, _, _, _}, 2_000
    child_ref = Process.monitor(child)
    parent_ref = Process.monitor(context.runner_pid)
    assert :ok = Coordinator.cancel(context.conversation_id)
    assert_receive {:DOWN, ^parent_ref, :process, _, _}, 2_000
    assert {:error, _, %{status: :parent_closed}} = Task.await(task, 5_000)
    assert_receive {:DOWN, ^child_ref, :process, ^child, _}, 2_000
    assert Process.alive?(Process.whereis(Delegation))
  end

  test "all terminal forms close children but interruption does not", %{context: context} do
    statuses = [:completed, :max_turns, :budget_exceeded, :halted, :error, :cancelled]

    for status <- statuses ++ Enum.map(statuses, &Atom.to_string/1) do
      task = delegate(context)
      assert_receive {:provider, :child, child, _, _, _}, 2_000

      send(
        Delegation,
        {:run_lifecycle, context.conversation_id, :run_end, %{status: :interrupted}}
      )

      assert map_size(:sys.get_state(Delegation).jobs) == 1
      assert Process.alive?(child)
      send(Delegation, {:run_lifecycle, context.conversation_id, :run_end, %{status: status}})
      assert {:error, _, %{status: :parent_closed}} = Task.await(task, 5_000)
    end
  end

  test "child cancellation reconciles tools without exposing its transcript", %{context: context} do
    task = delegate(context)
    assert_receive {:provider, :child, _child, _, _, _}, 2_000
    [{id, job}] = Map.to_list(:sys.get_state(Delegation).jobs)

    assert {:ok, _} =
             Handbean.ConversationTranscriptStore.append(id, %{
               "id" => "running-tool",
               "content_type" => "tool",
               "tool_status" => "running",
               "run_id" => job.run_id,
               "tool_name" => "read"
             })

    assert {:error, :not_found} =
             Handbean.ConversationTranscriptStore.list(id,
               runner_pid: job.runner,
               run_id: job.run_id
             )

    assert :ok = Handbean.Agent.TranscriptRecovery.recover(id)

    assert {:ok, entries} =
             Handbean.ConversationTranscriptStore.list(id, access_context: context)

    assert Enum.find(entries, &(&1["id"] == "running-tool"))["tool_status"] == "running"

    assert :ok = Coordinator.cancel(id)
    assert {:error, _, _} = Task.await(task, 5_000)
    assert {:ok, entries} = Handbean.ConversationTranscriptStore.list(id, access_context: context)
    assert Enum.find(entries, &(&1["id"] == "running-tool"))["tool_status"] == "cancelled"
  end

  test "child crash does not restart or stop its parent", %{context: context} do
    task = delegate(context)
    assert_receive {:provider, :child, child, _, _, _}, 2_000
    [{id, job}] = Map.to_list(:sys.get_state(Delegation).jobs)

    assert {:ok, _} =
             Handbean.ConversationTranscriptStore.append(id, %{
               "id" => "unfinished-reply",
               "role" => "assistant",
               "status" => "streaming",
               "content" => "durable before crash",
               "run_id" => job.run_id
             })

    send(child, :crash)
    assert {:error, _, _} = Task.await(task, 5_000)

    assert {:ok, entries} =
             Handbean.ConversationTranscriptStore.list(id, access_context: context)

    reply = Enum.find(entries, &(&1["id"] == "unfinished-reply"))
    assert reply["status"] == "error"
    assert reply["content"] == "durable before crash"
    assert {:error, :not_found} = Handbean.ConversationTranscriptStore.list(id)
    assert Policy.live_parent?(context)
    refute_receive {:provider, :child, _, _, _, _}, 100

    assert {:ok, historical_entry} =
             Handbean.ConversationTranscriptStore.append(id, %{
               "id" => "child-history-fact",
               "content_type" => "assistant_msg",
               "message_type" => "assistant",
               "role" => "assistant",
               "content" => "verbose child history fact",
               "status" => "completed"
             })

    {:ok, child_entries} =
      Handbean.ConversationTranscriptStore.list(id, access_context: context)

    child_messages =
      Handbean.Attachments.History.to_messages(child_entries, context.working_directory, id)

    first = hd(child_messages)
    historical = Enum.find(child_messages, &(&1.id == historical_entry["id"]))

    assert {:ok, _checkpoint} =
             Handbean.Agent.CompactionCheckpoint.persist(
               id,
               %{
                 first: first,
                 previous_summary: nil,
                 messages_to_summarize: [historical],
                 summary: "durable child checkpoint",
                 context_edited: false,
                 context_generation: 0,
                 context_window: 200_000,
                 model: "fake",
                 run_id: "child-checkpoint-run"
               },
               access_context: context
             )

    resume = Task.async(fn -> Delegation.resume_task(context.conversation_id, id) end)
    assert_receive {:provider, :child, resumed_child, resumed_messages, _, _}, 2_000
    assert resumed_child != child
    assert Enum.any?(resumed_messages, &(Message.text(&1) =~ "durable child checkpoint"))
    refute Enum.any?(resumed_messages, &(Message.text(&1) =~ "verbose child history fact"))
    assert Enum.any?(resumed_messages, &(Message.text(&1) =~ "Resume the interrupted task"))
    assert {:ok, %{child_conversation_id: ^id, delivery: :follow_up}} = Task.await(resume, 2_000)
    send(resumed_child, :finish)
  end

  test "child provider errors remain intact after internal transcript settlement", %{
    context: context
  } do
    task = delegate(context)
    assert_receive {:provider, :child, child, _, _, _}, 2_000
    [{id, job}] = Map.to_list(:sys.get_state(Delegation).jobs)

    send(child, {:error, :server_is_overloaded})
    assert {:error, _, %{status: status}} = Task.await(task, 5_000)
    assert status in [:error, "error"]

    assert {:ok, entries} =
             Handbean.ConversationTranscriptStore.list(id, access_context: context)

    error = Enum.find(entries, &(&1["id"] == "msg-run-error-#{job.run_id}"))

    assert error["content"] =~ "server_is_overloaded"
    refute error["content"] =~ "Transcript persistence failed"
  end

  test "approval is blocked and cleaned rather than left awaiting a user", %{context: context} do
    path = Handbean.WorkspaceSettings.path(context.working_directory)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Handbean.JSON.encode!(%{"tools" => %{"per_tool" => %{"read" => "prompt"}}}))
    task = delegate(context)
    assert_receive {:provider, :child, child, _, _, _}, 2_000
    send(child, :approval)
    assert {:error, _, %{status: :blocked, usage: %{input_tokens: 11}}} = Task.await(task, 5_000)
    assert Policy.live_parent?(context)
  end

  test "killed tool caller cannot orphan a child", %{context: context} do
    owner = Process.whereis(Delegation)
    :erlang.trace(owner, true, [:receive])
    on_exit(fn -> :erlang.trace(owner, false, [:receive]) end)
    task = delegate(context)
    assert_receive {:provider, :child, child, _, _, _}, 2_000
    assert_receive {:trace, ^owner, :receive, {:started, id, _run_id, {:ok, _}}}, 2_000
    ref = Process.monitor(child)
    Task.shutdown(task, :brutal_kill)
    assert_receive {:DOWN, ^ref, :process, ^child, _}, 2_000
    assert_receive {:trace, ^owner, :receive, {:cleaned, ^id, _, _}}, 2_000
    # The worker's DOWN precedes usage persistence. Drain the owner callback
    # before teardown removes HOME and races the final ledger write.
    refute Map.has_key?(:sys.get_state(owner).jobs, id)
    assert Policy.live_parent?(context)
  end

  test "startup blocked past deadline cannot start after lost acknowledgement", %{
    context: context
  } do
    :sys.suspend(Handbean.AgentRunSupervisor)

    try do
      task = delegate(%{context | tool_timeout: 4_000})
      assert {:error, _, %{status: :cleaning_up}} = Task.await(task, 5_000)
    after
      :sys.resume(Handbean.AgentRunSupervisor)
    end

    refute_receive {:provider, :child, _, _, _, _}, 500
  end

  test "authorization rejects globally registered write and recursive task", %{context: context} do
    Handbean.Tool.Registry.register(Handbean.Tool.Builtin.Write)
    Handbean.Tool.Registry.register(Handbean.Tool.Builtin.Task)
    config = %{context.delegation_config | allowed_tools: ["read"], delegated?: true}
    state = State.init(config, "read only")

    {:ok, _, blocks} =
      Executor.execute_all_with_details(
        [
          %{
            id: "write",
            name: "write",
            input: %{"file_path" => "forbidden.txt", "content" => "no"}
          },
          %{id: "recursive", name: "task", input: %{"task" => "no", "criteria" => "no"}}
        ],
        state
      )

    assert Enum.all?(blocks, & &1.is_error)
    assert Enum.all?(blocks, &String.contains?(&1.content, "Unknown tool"))
    refute File.exists?(Path.join(context.working_directory, "forbidden.txt"))
  end

  test "native capabilities and custom middleware are not inherited", %{context: context} do
    provider =
      Policy.provider_config(%{
        web_search: true,
        x_search: true,
        previous_response_id: "parent-history",
        use_previous_response_id: true,
        built_in_tools: [%{type: "code_interpreter"}, %{"type" => "web_search_preview"}]
      })

    assert provider.web_search
    refute Map.has_key?(provider, :x_search)
    refute Map.has_key?(provider, :previous_response_id)
    refute provider.use_previous_response_id
    assert provider.built_in_tools == [%{"type" => "web_search_preview"}]
    {:ok, opts} = Policy.child_opts(context, 30_000)
    assert opts[:history_messages] == []
    assert opts[:delivery] == Handbean.Delivery.Noop
    assert opts[:allowed_tools] == ["read"]

    assert opts[:middleware] == [
             Handbean.Agent.Middleware.Security,
             Handbean.Agent.Middleware.ToolGuard
           ]

    assert {:error, reason} =
             Policy.validate(%{
               context
               | delegation_config: %{context.delegation_config | max_budget_cents: 1}
             })

    assert reason =~ "monetary budget"
  end

  test "inherited child model keeps its context window", %{context: context} do
    delegation_config = %{
      context.delegation_config
      | provider_config:
          Map.put(context.delegation_config.provider_config, :model_meta, %{
            "contextWindow" => 272_000
          })
    }

    {:ok, opts} =
      Policy.child_opts(%{context | delegation_config: delegation_config}, 30_000)

    assert Config.from_opts(opts).max_tokens == 272_000
  end

  test "advisor child resolves its configured provider and reasoning level", %{context: context} do
    models_path = Path.join([context.working_directory, ".handbean", "models.json"])
    File.mkdir_p!(Path.dirname(models_path))

    previous_models_path = System.get_env("HANDBEAN_MODELS_FILE")
    System.put_env("HANDBEAN_MODELS_FILE", models_path)

    on_exit(fn ->
      if previous_models_path,
        do: System.put_env("HANDBEAN_MODELS_FILE", previous_models_path),
        else: System.delete_env("HANDBEAN_MODELS_FILE")
    end)

    File.write!(
      models_path,
      Handbean.JSON.encode!(%{
        "defaultProvider" => "mg",
        "defaultModel" => "cursor/gemini-4-argon",
        "providers" => %{
          "mg" => %{
            "baseUrl" => "https://example.test",
            "api" => "openai-responses",
            "provider" => "mg",
            "apiKey" => "test-key",
            "models" => [
              %{
                "id" => "cursor/gemini-4-argon",
                "reasoning" => true,
                "reasoningLevels" => ["low", "high"]
              }
            ]
          }
        }
      })
    )

    default_advisor = %{
      provider_id: "mg",
      model_id: "cursor/gemini-4-argon",
      reasoning: nil
    }

    default_config = %{context.delegation_config | advisor: default_advisor}

    assert {:ok, default_opts} =
             Policy.child_opts(
               %{context | delegation_config: default_config},
               30_000,
               Profile.advisor(:consult)
             )

    refute Keyword.has_key?(default_opts, :reasoning_level)
    refute Map.has_key?(default_opts[:provider_config], :reasoning)
    assert default_opts[:provider] == Handbean.Agent.Provider.OpenAI
    assert default_opts[:provider_config].provider == "mg"

    explicit_advisor = %{
      provider_id: "mg",
      model_id: "cursor/gemini-4-argon",
      reasoning: "high"
    }

    explicit_config = %{context.delegation_config | advisor: explicit_advisor}

    assert {:ok, opts} =
             Policy.child_opts(
               %{context | delegation_config: explicit_config},
               30_000,
               Profile.advisor(:consult)
             )

    assert opts[:reasoning_level] == "high"
    assert opts[:provider_config].reasoning == %{effort: "high"}
  end

  test "neither delegated nor ordinary runs are restarted with the original input" do
    assert Handbean.Agent.RunSupervisor.child_spec(run_opts: [delegated?: true]).restart ==
             :temporary

    assert Handbean.Agent.RunSupervisor.child_spec(run_opts: []).restart == :temporary

    for opts <- [[delegated?: true], []] do
      {:ok, {_, children}} =
        Handbean.Agent.RunSupervisor.init(conversation_id: "run", run_opts: opts)

      assert Enum.all?(children, &(&1.restart == :temporary))
    end
  end

  defp assert_eventually(fun, attempts \\ 50)
  defp assert_eventually(fun, 0), do: fun.()

  defp assert_eventually(fun, attempts) do
    fun.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(20)
      assert_eventually(fun, attempts - 1)
  end
end
