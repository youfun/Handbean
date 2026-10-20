defmodule Handbean.Agent.RunnerStreamPersistenceTest do
  use Handbean.DataCase, async: false

  alias Handbean.Agent.Coordinator
  alias Handbean.PubSub.Session

  setup do
    old_home = System.get_env("HOME")
    home_dir = Path.join(System.tmp_dir!(), "sigil_runner_home_#{Ecto.UUID.generate()}")
    File.mkdir_p!(home_dir)
    System.put_env("HOME", home_dir)
    previous_host = Application.get_env(:handbean, :host)
    Handbean.Host.put!(%{data_dir: home_dir})

    on_exit(fn ->
      drain_runtime_tasks()
      sync_runtime_observers()

      if old_home, do: System.put_env("HOME", old_home), else: System.delete_env("HOME")

      if previous_host,
        do: Application.put_env(:handbean, :host, previous_host),
        else: Application.delete_env(:handbean, :host)

      File.rm_rf(home_dir)
    end)

    :ok
  end

  defp drain_runtime_tasks do
    deadline = System.monotonic_time(:millisecond) + 2_000
    await_runtime_tasks(deadline)
  end

  defp await_runtime_tasks(deadline) do
    tasks = Task.Supervisor.children(Handbean.AgentRunTaskSupervisor)

    if tasks != [] and System.monotonic_time(:millisecond) < deadline do
      refs = Enum.map(tasks, &Process.monitor/1)
      timeout = max(deadline - System.monotonic_time(:millisecond), 0)

      Enum.each(refs, fn ref ->
        receive do
          {:DOWN, ^ref, :process, _pid, _reason} -> :ok
        after
          timeout -> Process.demonitor(ref, [:flush])
        end
      end)

      await_runtime_tasks(deadline)
    end
  end

  defp sync_runtime_observers do
    for name <- [Handbean.Runtime.TaskTracker, Handbean.Schedule.Recorder],
        pid = Process.whereis(name),
        is_pid(pid) do
      :sys.get_state(pid)
    end
  end

  defmodule FailingTimerStore do
    alias Handbean.ConversationTranscriptStore.ConversationStore, as: Store

    def append(id, entry, opts), do: Store.append(id, entry, opts)
    def list(id, opts), do: Store.list(id, opts)

    def update(id, entry_id, %{"content" => %{"$append" => _delta}} = patch, opts) do
      counter = Keyword.fetch!(opts, :timer_flush_counter)
      :counters.add(counter, 1, 1)
      count = :counters.get(counter, 1)

      if count == 1,
        do: Store.update(id, entry_id, patch, opts),
        else: {:error, :enospc}
    end

    def update(id, entry_id, patch, opts), do: Store.update(id, entry_id, patch, opts)
  end

  defmodule StreamingProvider do
    @behaviour Handbean.Agent.Provider

    @impl true
    def complete(_messages, _tool_defs, _config) do
      {:ok,
       %{
         stop_reason: :end_turn,
         messages: [Handbean.Agent.Message.assistant("streamed")],
         usage: %{input_tokens: 1, output_tokens: 1},
         response_metadata: %{}
       }}
    end

    @impl true
    def stream(_messages, _tool_defs, _config, on_chunk) do
      on_chunk.("streamed")

      {:ok,
       %{
         stop_reason: :end_turn,
         messages: [Handbean.Agent.Message.assistant("streamed")],
         usage: %{input_tokens: 1, output_tokens: 1},
         response_metadata: %{}
       }}
    end
  end

  defmodule ControlledStreamingProvider do
    @behaviour Handbean.Agent.Provider

    @impl true
    def complete(_messages, _tool_defs, _config), do: raise("stream/4 expected")

    @impl true
    def stream(_messages, _tool_defs, config, on_chunk) do
      send(config.notify, {:controlled_stream_ready, self()})
      stream_loop(config.notify, on_chunk, config.on_event, [])
    end

    defp stream_loop(notify, on_chunk, on_event, chunks) do
      receive do
        {:emit_chunk, payload} ->
          on_chunk.(payload)
          send(notify, {:chunk_callback_returned, self(), payload})
          stream_loop(notify, on_chunk, on_event, [payload | chunks])

        {:emit_event, event} ->
          on_event.(event)
          send(notify, {:event_callback_returned, self(), event})
          stream_loop(notify, on_chunk, on_event, chunks)

        :kill_stream ->
          Process.exit(self(), :kill)

        :finish_stream ->
          chunks = Enum.reverse(chunks)

          {:ok,
           %{
             stop_reason: :end_turn,
             messages: [assistant_message(chunks)],
             usage: %{input_tokens: 1, output_tokens: 1},
             response_metadata: %{}
           }}
      end
    end

    defp assistant_message(chunks) do
      if Enum.any?(chunks, &is_map/1) do
        blocks =
          Enum.map(chunks, fn chunk ->
            %{
              type: "text",
              text: chunk.text,
              phase: chunk.phase,
              output_index: chunk.output_index
            }
          end)

        Handbean.Agent.Message.assistant(blocks)
      else
        Handbean.Agent.Message.assistant(Enum.join(chunks))
      end
    end
  end

  defmodule RoundTripTool do
    @behaviour Handbean.Agent.Tool

    def name, do: "round_trip_fixture"
    def description, do: "Completes immediately for a streaming multi-turn test"
    def input_schema, do: %{type: "object", properties: %{}}
    def execute(_input, _context), do: {:ok, "round trip complete"}
  end

  defmodule MultiTurnStreamingProvider do
    @behaviour Handbean.Agent.Provider

    @impl true
    def complete(_messages, _tool_defs, _config), do: raise("stream/4 expected")

    @impl true
    def stream(messages, _tool_defs, config, on_chunk) do
      if Enum.any?(messages, &(&1.role == :tool_result)) do
        on_chunk.("second")
        send(config.notify, {:second_turn_chunk_returned, self()})

        receive do
          :finish_second_turn ->
            {:ok,
             %{
               stop_reason: :end_turn,
               messages: [Handbean.Agent.Message.assistant("second")],
               usage: %{input_tokens: 1, output_tokens: 1},
               response_metadata: %{}
             }}
        end
      else
        on_chunk.("first")

        {:ok,
         %{
           stop_reason: :tool_use,
           messages: [
             Handbean.Agent.Message.assistant([
               %{
                 type: "tool_use",
                 id: "round-trip-1",
                 name: "round_trip_fixture",
                 input: %{}
               }
             ])
           ],
           usage: %{input_tokens: 1, output_tokens: 1},
           response_metadata: %{}
         }}
      end
    end
  end

  defp opts(extra) do
    Keyword.merge(
      [
        workspace_path: File.cwd!(),
        model: "fake-model",
        provider: Handbean.TestSupport.FakeProvider,
        provider_config: %{scenario: :simple_answer},
        tools: [],
        source: :cli,
        streaming: false,
        max_turns: 3
      ],
      extra
    )
  end

  test "streaming coordinator run broadcasts message_delta into session" do
    sid = "runner-streaming-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(
               sid,
               "hello",
               opts(provider: StreamingProvider, provider_config: %{}, streaming: true)
             )

    assert_eventually(fn ->
      %{events: events} = Session.snapshot(sid)

      assert Enum.any?(
               events,
               &match?(%{kind: :message_delta, payload: %{chunk: "streamed"}}, &1)
             )

      assert Enum.any?(events, &match?(%{kind: :run_end}, &1))
    end)
  end

  test "stream persistence commits the first chunk immediately and flushes a quiet batch" do
    {sid, provider} = start_controlled_stream(stream_flush_ms: 20)

    emit_chunk(provider, "你")

    assert_receive {:agent_event, %{kind: :message_delta, payload: %{text: "你", text_offset: 0}}},
                   1_000

    assert [%{"role" => "user"}, %{"content" => "你"}] =
             Handbean.ConversationStore.load_messages(sid)

    emit_chunk(provider, "好")
    refute_receive {:agent_event, %{kind: :message_delta, payload: %{text: "好"}}}, 0

    assert_receive {:agent_event, %{kind: :message_delta, payload: %{text: "好", text_offset: 3}}},
                   1_000

    assert [%{"role" => "user"}, %{"content" => "你好"}] =
             Handbean.ConversationStore.load_messages(sid)

    finish_stream(provider)
  end

  test "stream persistence flushes at the byte bound without waiting for its timer" do
    {sid, provider} = start_controlled_stream(stream_flush_bytes: 6, stream_flush_ms: 5_000)

    emit_chunk(provider, "a")
    assert_receive {:agent_event, %{kind: :message_delta, payload: %{text: "a"}}}, 1_000

    emit_chunk(provider, "你好")

    assert_receive {:agent_event,
                    %{kind: :message_delta, payload: %{text: "你好", text_offset: 1}}},
                   1_000

    assert [%{"role" => "user"}, %{"content" => "a你好"}] =
             Handbean.ConversationStore.load_messages(sid)

    finish_stream(provider)
  end

  test "rich message deltas bypass text batching without losing metadata" do
    {sid, provider} = start_controlled_stream(stream_flush_ms: 5_000)

    emit_chunk(provider, "saved")
    assert_receive {:agent_event, %{kind: :message_delta, payload: %{text: "saved"}}}, 1_000

    emit_provider_event(provider, {:message_delta, %{"chunk" => " pending"}})

    provider_items = [%{type: "reasoning", id: "reasoning-1"}]

    emit_provider_event(
      provider,
      {:message_delta,
       %{
         chunk: " rich",
         thinking: "private reasoning",
         provider_items: provider_items
       }}
    )

    assert_receive {:agent_event, %{kind: :message_delta, payload: %{text: " pending"}}}, 1_000

    assert_receive {:agent_event,
                    %{
                      kind: :message_delta,
                      payload: %{
                        text: " rich",
                        thinking: "private reasoning",
                        provider_items: ^provider_items
                      }
                    }},
                   1_000

    emit_provider_event(
      provider,
      {:message_delta, %{chunk: "", thinking_delta: "more private reasoning"}}
    )

    assert_receive {:agent_event,
                    %{
                      kind: :message_delta,
                      payload: %{chunk: "", thinking_delta: "more private reasoning"} = payload
                    }},
                   1_000

    refute Map.has_key?(payload, :text)

    assert [%{"role" => "user"}, %{"content" => "saved pending rich"}] =
             Handbean.ConversationStore.load_messages(sid)
  end

  test "the first visible chunk of a later tool turn commits immediately" do
    sid = "runner-multi-turn-stream-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)
    :ok = Session.subscribe(sid)

    assert {:ok, %{action: :started, run_pid: runner}} =
             Coordinator.add_message(
               sid,
               "use a tool",
               opts(
                 provider: MultiTurnStreamingProvider,
                 provider_config: %{notify: self()},
                 tools: [RoundTripTool],
                 streaming: true,
                 stream_flush_ms: 5_000,
                 source: :web
               )
             )

    assert_receive {:agent_event, %{kind: :message_delta, payload: %{text: "first"}}}, 1_000
    assert_receive {:second_turn_chunk_returned, provider}, 1_000

    assert_receive {:agent_event, %{kind: :message_delta, payload: %{text: "second"}}}, 1_000

    runner_ref = Process.monitor(runner)
    send(provider, :finish_second_turn)
    assert_receive {:agent_event, %{kind: :run_end, payload: %{status: :completed}}}, 1_000
    assert_receive {:DOWN, ^runner_ref, :process, ^runner, :shutdown}, 1_000
  end

  test "phase and output index changes each drain the preceding stream segment" do
    {sid, provider} = start_controlled_stream(stream_flush_ms: 5_000)

    emit_chunk(provider, %{text: "a", phase: "commentary", output_index: 0})

    assert_receive {:agent_event,
                    %{
                      kind: :message_delta,
                      payload: %{
                        text: "a",
                        phase: "commentary",
                        output_index: 0,
                        text_offset: 0
                      }
                    }},
                   1_000

    emit_chunk(provider, %{text: "b", phase: "commentary", output_index: 0})
    emit_chunk(provider, %{text: "c", phase: "final_answer", output_index: 0})

    assert_receive {:agent_event,
                    %{
                      kind: :message_delta,
                      payload: %{
                        text: "b",
                        phase: "commentary",
                        output_index: 0,
                        text_offset: 1
                      }
                    }},
                   1_000

    assert_receive {:agent_event,
                    %{
                      kind: :message_delta,
                      payload: %{
                        text: "c",
                        phase: "final_answer",
                        output_index: 0,
                        text_offset: 0
                      }
                    }},
                   1_000

    emit_chunk(provider, %{text: "d", phase: "final_answer", output_index: 1})
    refute_receive {:agent_event, %{kind: :message_delta, payload: %{text: "d"}}}, 0

    send(provider, :finish_stream)

    assert_receive {:agent_event,
                    %{
                      kind: :message_delta,
                      payload: %{
                        text: "d",
                        phase: "final_answer",
                        output_index: 1,
                        text_offset: 0
                      }
                    }},
                   1_000

    assert_receive {:agent_event, %{kind: :run_end}}, 1_000

    assert [
             %{"role" => "user"},
             %{"content" => "ab", "phase" => "commentary"},
             %{"content" => "c", "phase" => "final_answer"},
             %{"content" => "d", "phase" => "final_answer"}
           ] = Handbean.ConversationStore.load_messages(sid)
  end

  test "cancellation flushes an accepted stream batch before its terminal event" do
    {sid, provider} = start_controlled_stream(stream_flush_ms: 5_000)

    emit_chunk(provider, "saved")
    assert_receive {:agent_event, %{kind: :message_delta, payload: %{text: "saved"}}}, 1_000

    emit_chunk(provider, " pending")
    assert :ok = Coordinator.cancel(sid)
    assert_receive {:agent_event, %{kind: :message_delta, payload: %{text: " pending"}}}, 1_000
    assert_receive {:agent_event, %{kind: :run_end, payload: %{status: "cancelled"}}}, 1_000

    assert [%{"role" => "user"}, %{"content" => "saved pending", "status" => "cancelled"}] =
             Handbean.ConversationStore.load_messages(sid)
  end

  test "provider task failure flushes accepted text before reporting error" do
    {sid, provider} = start_controlled_stream(stream_flush_ms: 5_000)

    emit_chunk(provider, "saved")
    assert_receive {:agent_event, %{kind: :message_delta, payload: %{text: "saved"}}}, 1_000
    emit_chunk(provider, " pending")

    send(provider, :kill_stream)

    assert_receive {:agent_event, %{kind: :message_delta, payload: %{text: " pending"}}}, 1_000
    assert_receive {:agent_event, %{kind: :run_end, payload: %{status: "error"}}}, 1_000

    assert [%{"role" => "user"}, %{"content" => "saved pending", "status" => "error"}, _] =
             Handbean.ConversationStore.load_messages(sid)
  end

  test "inactivity timeout flushes accepted text before reporting timeout" do
    {sid, provider} =
      start_controlled_stream(stream_flush_ms: 5_000, timeout_ms: 300, delegated?: false)

    emit_chunk(provider, "saved")
    assert_receive {:agent_event, %{kind: :message_delta, payload: %{text: "saved"}}}, 1_000
    emit_chunk(provider, " pending")

    assert_receive {:agent_event, %{kind: :message_delta, payload: %{text: " pending"}}}, 1_000

    assert_receive {:agent_event,
                    %{
                      kind: :run_end,
                      payload: %{status: "timeout", reason: :run_inactivity_timeout}
                    }},
                   1_000

    assert [
             %{"role" => "user"},
             %{
               "role" => "assistant",
               "content" => "saved pending",
               "status" => "error",
               "error" => "run stalled: no progress for 300ms"
             },
             %{
               "role" => "system",
               "message_type" => "error",
               "status" => "final",
               "content" => "Run error: run stalled: no progress for 300ms"
             }
           ] = Handbean.ConversationStore.load_messages(sid)
  end

  test "absolute run deadline flushes accepted text before reporting timeout" do
    {sid, provider} =
      start_controlled_stream(stream_flush_ms: 5_000, timeout_ms: 300, delegated?: true)

    emit_chunk(provider, "saved")
    assert_receive {:agent_event, %{kind: :message_delta, payload: %{text: "saved"}}}, 1_000
    emit_chunk(provider, " pending")

    assert_receive {:agent_event, %{kind: :message_delta, payload: %{text: " pending"}}}, 1_000

    assert_receive {:agent_event,
                    %{kind: :run_end, payload: %{status: "timeout", reason: :run_timeout}}},
                   1_000

    assert [
             %{"role" => "user"},
             %{
               "role" => "assistant",
               "content" => "saved pending",
               "status" => "error",
               "error" => "run deadline exceeded"
             },
             %{
               "role" => "system",
               "message_type" => "error",
               "status" => "final",
               "content" => "Run error: run deadline exceeded"
             }
           ] = Handbean.ConversationStore.load_messages(sid)
  end

  test "timer flush failure stops the producer without replaying pending text" do
    counter = :counters.new(1, [])

    {sid, provider} =
      start_controlled_stream(
        stream_flush_ms: 20,
        transcript_store: FailingTimerStore,
        timer_flush_counter: counter
      )

    emit_chunk(provider, "saved")
    assert_receive {:agent_event, %{kind: :message_delta, payload: %{text: "saved"}}}, 1_000
    emit_chunk(provider, " pending")
    provider_ref = Process.monitor(provider)

    assert_receive {:DOWN, ^provider_ref, :process, ^provider, _reason}, 1_000
    assert_receive {:agent_event, %{kind: :run_end, payload: %{status: "error"}}}, 1_000
    refute_receive {:agent_event, %{kind: :message_delta, payload: %{text: " pending"}}}, 100

    assert [%{"role" => "user"}, %{"content" => "saved", "status" => "error"}, _] =
             Handbean.ConversationStore.load_messages(sid)

    assert :counters.get(counter, 1) == 2
  end

  test "on_event failure stops the producer without replaying a committed batch" do
    callback = fn
      {:message_delta, %{chunk: " pending"}} -> raise "callback failed"
      _event -> :ok
    end

    {sid, provider} = start_controlled_stream(stream_flush_ms: 20, on_event: callback)

    emit_chunk(provider, "saved")
    assert_receive {:agent_event, %{kind: :message_delta, payload: %{text: "saved"}}}, 1_000
    emit_chunk(provider, " pending")
    provider_ref = Process.monitor(provider)

    assert_receive {:DOWN, ^provider_ref, :process, ^provider, _reason}, 1_000
    assert_receive {:agent_event, %{kind: :run_end, payload: %{status: "error"}}}, 1_000
    refute_receive {:agent_event, %{kind: :message_delta, payload: %{text: " pending"}}}, 100

    assert [%{"role" => "user"}, %{"content" => "saved pending", "status" => "error"}, _] =
             Handbean.ConversationStore.load_messages(sid)
  end

  test "non-message callback failure does not replay the batch it drained" do
    callback = fn
      {:usage_updated, _payload} -> raise "usage callback failed"
      _event -> :ok
    end

    {sid, provider} = start_controlled_stream(stream_flush_ms: 5_000, on_event: callback)

    emit_chunk(provider, "saved")
    assert_receive {:agent_event, %{kind: :message_delta, payload: %{text: "saved"}}}, 1_000
    emit_chunk(provider, " pending")
    send(provider, :finish_stream)

    assert_receive {:agent_event, %{kind: :message_delta, payload: %{text: " pending"}}}, 1_000
    assert_receive {:agent_event, %{kind: :run_end, payload: %{status: "error"}}}, 1_000
    refute_receive {:agent_event, %{kind: :message_delta, payload: %{text: " pending"}}}, 100

    assert [%{"role" => "user"}, %{"content" => "saved pending", "status" => "error"}, _] =
             Handbean.ConversationStore.load_messages(sid)
  end

  defp start_controlled_stream(extra) do
    sid = "runner-controlled-stream-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)
    :ok = Session.subscribe(sid)

    assert {:ok, %{action: :started, run_pid: runner}} =
             Coordinator.add_message(
               sid,
               "hello",
               opts(
                 [
                   provider: ControlledStreamingProvider,
                   provider_config: %{notify: self()},
                   streaming: true,
                   source: :web
                 ] ++ extra
               )
             )

    assert_receive {:controlled_stream_ready, provider}, 1_000
    on_exit(fn -> stop_controlled_run(sid, runner) end)
    {sid, provider}
  end

  defp stop_controlled_run(sid, runner) do
    ref = Process.monitor(runner)
    if Process.alive?(runner), do: Coordinator.cancel(sid)
    assert_receive {:DOWN, ^ref, :process, ^runner, _reason}, 2_000

    # Runner schedules collaboration settlement before it exits. Waiting for
    # the Runner first makes that task visible to the existing task drain and
    # keeps it inside the current SQL sandbox ownership lifetime.
    drain_runtime_tasks()
  end

  defp emit_chunk(provider, payload) do
    send(provider, {:emit_chunk, payload})
    assert_receive {:chunk_callback_returned, ^provider, ^payload}, 1_000
    :ok
  end

  defp emit_provider_event(provider, event) do
    send(provider, {:emit_event, event})
    assert_receive {:event_callback_returned, ^provider, ^event}, 1_000
    :ok
  end

  defp finish_stream(provider) do
    send(provider, :finish_stream)
    assert_receive {:agent_event, %{kind: :run_end}}, 1_000
    :ok
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
