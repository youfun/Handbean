defmodule Handbean.Agent.RunnerModelSwitchTest do
  use Handbean.DataCase, async: false

  import Handbean.TestSupport.RuntimeLifecycle

  alias Handbean.Agent.{Config, Coordinator, Message, Runner}
  alias Handbean.PubSub.Session

  setup do
    old_home = System.get_env("HOME")
    home_dir = Path.join(System.tmp_dir!(), "handbean_model_switch_#{Ecto.UUID.generate()}")
    File.mkdir_p!(home_dir)
    System.put_env("HOME", home_dir)

    case Handbean.Tool.Registry.get("read") do
      {:ok, _} -> :ok
      :error -> Handbean.Tool.Registry.register(Handbean.Tool.Builtin.Read)
    end

    {:ok, conversation} = Handbean.ConversationStore.create("default", timeline: [])
    sid = conversation["id"]

    assert {:ok, _metadata} =
             Handbean.Permissions.ConversationMode.update(sid, :yolo, source: :test)

    on_exit(fn ->
      try do
        stop_run!(sid)
        drain_terminal_callbacks!()
        sync_runtime_observers!()
      after
        if old_home, do: System.put_env("HOME", old_home), else: System.delete_env("HOME")
        File.rm_rf(home_dir)
      end
    end)

    %{sid: sid}
  end

  defmodule BoundaryProvider do
    @behaviour Handbean.Agent.Provider

    @impl true
    def complete(messages, tool_defs, config) do
      notify = Map.fetch!(config, :notify)
      label = Map.fetch!(config, :label)
      actual_request? = Enum.any?(tool_defs, &(Map.get(&1, :name) == "read"))

      if actual_request? do
        send(notify, {:model_switch_provider_request, label, config.model, self()})
        complete_actual_request(messages)
      else
        {:ok,
         %{
           stop_reason: :end_turn,
           messages: [Message.assistant("summary")],
           usage: %{input_tokens: 1, output_tokens: 1},
           response_metadata: %{}
         }}
      end
    end

    defp complete_actual_request(messages) do
      if Enum.any?(messages, &(&1.role == :tool_result)) do
        receive do
          :finish -> :ok
        after
          5_000 -> raise "final provider fixture timed out"
        end

        {:ok,
         %{
           stop_reason: :end_turn,
           messages: [Message.assistant("done")],
           usage: %{input_tokens: 1, output_tokens: 1},
           response_metadata: %{}
         }}
      else
        receive do
          :continue -> :ok
        after
          5_000 -> raise "provider fixture timed out"
        end

        {:ok,
         %{
           stop_reason: :tool_use,
           messages: [
             Message.tool_use([
               %{
                 type: "tool_use",
                 id: "read-model-switch",
                 name: "read",
                 input: %{"file_path" => "mix.exs", "limit" => 1}
               }
             ])
           ],
           usage: %{input_tokens: 1, output_tokens: 1},
           response_metadata: %{}
         }}
      end
    end

    @impl true
    def stream(messages, tool_defs, config, _on_chunk), do: complete(messages, tool_defs, config)
  end

  defmodule InvalidSwitchProvider do
    @behaviour Handbean.Agent.Provider

    @impl true
    def context_editing?, do: raise("invalid switched provider")

    @impl true
    def complete(_messages, _tool_defs, _config), do: {:error, "must not be called"}
  end

  defmodule RetryProvider do
    @behaviour Handbean.Agent.Provider

    @impl true
    def complete(_messages, _tool_defs, config) do
      calls = Process.get({__MODULE__, :calls}, 0)
      Process.put({__MODULE__, :calls}, calls + 1)
      send(config.notify, {:model_switch_retry_request, calls + 1, config.label, config.model})

      if calls == 0 do
        {:error, "HTTP request failed: %Finch.TransportError{reason: :closed}"}
      else
        {:ok,
         %{
           stop_reason: :end_turn,
           messages: [Message.assistant("retried")],
           usage: %{input_tokens: 1, output_tokens: 1},
           response_metadata: %{}
         }}
      end
    end

    @impl true
    def stream(messages, tool_defs, config, _on_chunk), do: complete(messages, tool_defs, config)
  end

  test "model reconfiguration preserves the effective runtime config" do
    callback = fn _event, _config -> :ok end

    current =
      Config.from_opts(
        provider: BoundaryProvider,
        provider_config: %{provider: "sol"},
        model: "sol-model",
        reasoning_level: "medium",
        system_prompt: "runtime-marker",
        context: %{run_deadline: 123, mcp_scope: [project: nil]},
        allowed_tools: ["read"]
      )

    current = %{
      current
      | on_compaction_complete: callback,
        system_prompt: current.system_prompt <> "\nstartup-transform"
    }

    switched =
      Config.reconfigure_model(current,
        provider: RetryProvider,
        provider_config: %{
          provider: "grok",
          model_meta: %{"contextWindow" => 64_000}
        },
        model: "grok-model",
        reasoning_level: "high"
      )

    assert switched.provider == RetryProvider
    assert switched.model == "grok-model"
    assert switched.reasoning_level == "high"
    assert switched.max_tokens == 64_000
    assert switched.on_compaction_complete == callback
    assert switched.context == current.context
    assert switched.allowed_tools == ["read"]
    assert switched.system_prompt =~ "runtime-marker"
    assert switched.system_prompt =~ "startup-transform"
  end

  test "run options read the durable model revision instead of stale caller reasoning", %{
    sid: sid
  } do
    assert {:ok, persisted} =
             Handbean.ConversationStore.update_model_selection(sid, "sol/ref", nil, 0)

    stale_opts =
      opts(BoundaryProvider)
      |> Keyword.put(:reasoning_level, "high")
      |> Keyword.put(:chat_scope, :free)

    run_opts = Handbean.Agent.Coordinator.RunOptions.build(sid, stale_opts)
    assert run_opts[:selected_model] == "sol/ref"
    assert run_opts[:reasoning_level] == nil
    assert run_opts[:model_selection_revision] == 1
    assert persisted["model_selection_revision"] == 1
  end

  test "switch keeps the in-flight request and applies to the next provider request", %{sid: sid} do
    assert {:ok, %{run_pid: runner}} = Coordinator.start_run(sid, "start", opts(BoundaryProvider))
    assert_receive {:model_switch_provider_request, "sol", "sol-model", task}, 2_000

    assert {:ok, %{run_id: run_id}} = Runner.status(sid)
    assert {:ok, %{status: :accepted, revision: 1}} = request_switch(sid, run_id, "grok")

    assert {:ok,
            %{
              run_pid: ^runner,
              run_id: ^run_id,
              active_model: %{model: "sol-model"},
              pending_model_switch: %{model: "grok-model", revision: 1}
            }} = Runner.status(sid)

    send(task, :continue)

    assert_receive {:model_switch_provider_request, "grok", "grok-model", same_task}, 2_000
    assert same_task == task

    assert {:ok, %{run_pid: ^runner, run_id: ^run_id, active_model: %{model: "grok-model"}}} =
             Runner.status(sid)

    send(same_task, :finish)

    assert_eventually(fn ->
      assert {:ok, %{turns: turns}} =
               Handbean.ConversationStore.trajectory_snapshot(sid, limit: 100)

      assert Enum.map(turns, &{&1.number, &1.model, &1.config_revision}) == [
               {1, "sol-model", 0},
               {2, "grok-model", 1}
             ]

      refute Process.alive?(runner)
    end)
  end

  test "all retries of one logical request retain the original model", %{sid: sid} do
    assert {:ok, %{run_pid: runner}} = Coordinator.start_run(sid, "start", opts(RetryProvider))
    assert_receive {:model_switch_retry_request, 1, "sol", "sol-model"}, 2_000

    assert {:ok, %{run_id: run_id}} = Runner.status(sid)
    assert {:ok, %{status: :accepted}} = request_switch(sid, run_id, "grok")

    assert_receive {:model_switch_retry_request, 2, "sol", "sol-model"}, 2_000

    assert_eventually(fn ->
      refute Process.alive?(runner)
    end)
  end

  test "a blocked Session cannot block switch commit or the next request", %{sid: sid} do
    assert {:ok, %{run_pid: runner}} = Coordinator.start_run(sid, "start", opts(BoundaryProvider))
    assert_receive {:model_switch_provider_request, "sol", "sol-model", task}, 2_000
    assert {:ok, %{run_id: run_id}} = Runner.status(sid)

    session = Session.whereis(sid)
    :ok = :sys.suspend(session)

    on_exit(fn ->
      if Process.alive?(session), do: :sys.resume(session)
    end)

    assert {:ok, %{revision: 1}} = request_switch(sid, run_id, "grok")
    send(task, :continue)

    assert_receive {:model_switch_provider_request, "grok", "grok-model", same_task}, 2_000
    assert same_task == task

    :ok = :sys.resume(session)
    send(same_task, :finish)
    assert_eventually(fn -> refute Process.alive?(runner) end)
  end

  test "session recovery restores the Runner-owned pending switch", %{sid: sid} do
    assert {:ok, %{run_pid: runner}} = Coordinator.start_run(sid, "start", opts(BoundaryProvider))
    assert_receive {:model_switch_provider_request, "sol", "sol-model", task}, 2_000
    assert {:ok, %{run_id: run_id}} = Runner.status(sid)
    assert {:ok, %{revision: 1}} = request_switch(sid, run_id, "grok")

    session = Session.whereis(sid)
    monitor = Process.monitor(session)
    Process.exit(session, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^session, :killed}, 2_000
    assert {:ok, recovered} = Session.start_or_get(session_id: sid, model: "unknown")
    assert recovered != session

    assert_eventually(fn ->
      assert %{meta: %{pending_model: %{model: "grok-model", revision: 1}}} =
               Session.snapshot(sid)
    end)

    send(task, :continue)
    assert_receive {:model_switch_provider_request, "grok", "grok-model", same_task}, 2_000
    send(same_task, :finish)
    assert_eventually(fn -> refute Process.alive?(runner) end)
  end

  test "latest accepted revision wins and stale run ids are rejected", %{sid: sid} do
    assert {:ok, %{run_pid: runner}} = Coordinator.start_run(sid, "start", opts(BoundaryProvider))
    assert_receive {:model_switch_provider_request, "sol", "sol-model", task}, 2_000
    assert {:ok, %{run_id: run_id}} = Runner.status(sid)

    assert {:error, :run_id_required} = request_switch(sid, nil, "grok")
    assert {:error, {:run_mismatch, ^run_id}} = request_switch(sid, "stale-run", "grok")
    assert {:ok, %{revision: 1}} = request_switch(sid, run_id, "grok")
    assert {:ok, %{revision: 2}} = request_switch(sid, run_id, "opus")

    assert {:ok,
            %{
              "selected_model" => "opus/ref",
              "selected_reasoning_level" => "high"
            }} = Handbean.ConversationStore.get_metadata(sid)

    send(task, :continue)
    assert_receive {:model_switch_provider_request, "opus", "opus-model", same_task}, 2_000
    assert same_task == task

    assert {:ok, %{run_pid: ^runner, run_id: ^run_id, active_model: %{model: "opus-model"}}} =
             Runner.status(sid)

    send(same_task, :finish)
    assert_eventually(fn -> refute Process.alive?(runner) end)
  end

  test "a switch that fails at the provider boundary rolls durable selection back to active", %{
    sid: sid
  } do
    assert {:ok, %{run_pid: runner}} = Coordinator.start_run(sid, "start", opts(BoundaryProvider))
    assert_receive {:model_switch_provider_request, "sol", "sol-model", task}, 2_000
    assert {:ok, %{run_id: run_id}} = Runner.status(sid)

    assert {:ok, %{status: :accepted, revision: 1}} =
             Runner.request_model_switch(sid, run_id, %{
               model_ref: "invalid/ref",
               reasoning_level: "high",
               expected_revision: 0,
               run_opts: [
                 selected_model: "invalid/ref",
                 model: "invalid-model",
                 reasoning_level: "high",
                 provider: InvalidSwitchProvider,
                 provider_config: %{provider: "invalid"}
               ]
             })

    assert {:ok, %{"selected_model" => "invalid/ref"}} =
             Handbean.ConversationStore.get_metadata(sid)

    monitor = Process.monitor(runner)
    send(task, :continue)

    assert_eventually(fn ->
      assert {:ok,
              %{
                "selected_model" => "sol/ref",
                "selected_reasoning_level" => "medium"
              }} = Handbean.ConversationStore.get_metadata(sid)
    end)

    assert_receive {:DOWN, ^monitor, :process, ^runner, _reason}, 2_000
  end

  test "stale selection revisions cannot cancel a newer persisted switch", %{sid: sid} do
    assert {:ok, %{run_pid: runner}} = Coordinator.start_run(sid, "start", opts(BoundaryProvider))
    assert_receive {:model_switch_provider_request, "sol", "sol-model", task}, 2_000
    assert {:ok, %{run_id: run_id}} = Runner.status(sid)

    assert {:ok, %{status: :accepted, revision: 1}} =
             Runner.request_model_switch(sid, run_id, %{
               model_ref: "grok/ref",
               reasoning_level: "high",
               expected_revision: 0,
               run_opts: [
                 selected_model: "grok/ref",
                 model: "grok-model",
                 reasoning_level: "high",
                 provider: BoundaryProvider,
                 provider_config: %{notify: self(), label: "grok"}
               ]
             })

    assert {:error, {:stale_model_selection, 1}} =
             Runner.request_model_switch(sid, run_id, %{
               model_ref: "sol/ref",
               reasoning_level: "medium",
               expected_revision: 0,
               run_opts: opts(BoundaryProvider)
             })

    assert {:ok, %{pending_model_switch: %{model_ref: "grok/ref", revision: 1}}} =
             Runner.status(sid)

    assert {:ok,
            %{
              "selected_model" => "grok/ref",
              "selected_reasoning_level" => "high"
            }} = Handbean.ConversationStore.get_metadata(sid)

    monitor = Process.monitor(runner)
    send(task, :continue)
    assert_receive {:model_switch_provider_request, "grok", "grok-model", ^task}, 2_000
    send(task, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^runner, _reason}, 2_000
  end

  test "selecting the active model cancels a pending switch before the next request", %{sid: sid} do
    assert {:ok, %{run_pid: runner}} = Coordinator.start_run(sid, "start", opts(BoundaryProvider))
    assert_receive {:model_switch_provider_request, "sol", "sol-model", task}, 2_000
    assert {:ok, %{run_id: run_id}} = Runner.status(sid)
    assert {:ok, %{status: :accepted, revision: 1}} = request_switch(sid, run_id, "grok")

    assert {:ok, %{status: :cancelled, revision: 2}} =
             Runner.request_model_switch(sid, run_id, %{
               model_ref: "sol/ref",
               reasoning_level: "medium",
               run_opts: opts(BoundaryProvider)
             })

    assert {:ok,
            %{
              active_model: %{model: "sol-model", reasoning_level: "medium"},
              pending_model_switch: nil,
              model_switch_revision: 2
            }} = Runner.status(sid)

    monitor = Process.monitor(runner)
    send(task, :continue)
    assert_receive {:model_switch_provider_request, "sol", "sol-model", ^task}, 2_000
    send(task, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^runner, _reason}, 2_000
  end

  defp opts(provider) do
    [
      workspace_path: File.cwd!(),
      working_directory: File.cwd!(),
      selected_model: "sol/ref",
      model: "sol-model",
      reasoning_level: "medium",
      provider: provider,
      provider_config: %{
        notify: self(),
        label: "sol",
        retry: %{max_retries: 1, base_delay_ms: 100}
      },
      context: %{preserved: true},
      system_prompt: "runtime-marker",
      allowed_tools: ["read"],
      tools: [],
      permission_mode: :yolo,
      source: :cli,
      streaming: false,
      max_turns: 3
    ]
  end

  defp request_switch(sid, run_id, label) do
    Runner.request_model_switch(sid, run_id, %{
      model_ref: "#{label}/ref",
      reasoning_level: "high",
      run_opts: [
        selected_model: "#{label}/ref",
        model: "#{label}-model",
        reasoning_level: "high",
        provider: BoundaryProvider,
        provider_config: %{notify: self(), label: label}
      ]
    })
  end

  defp assert_eventually(fun, attempts \\ 100)
  defp assert_eventually(fun, 0), do: fun.()

  defp assert_eventually(fun, attempts) do
    fun.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(20)
      assert_eventually(fun, attempts - 1)
  end
end
