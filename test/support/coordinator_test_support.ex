defmodule Handbean.Agent.CoordinatorTestSupport do
  def setup_coordinator(_context) do
    old_home = System.get_env("HOME")

    home_dir = Path.join(System.tmp_dir!(), "sigil_coord_home_#{Ecto.UUID.generate()}")

    File.mkdir_p!(home_dir)
    System.put_env("HOME", home_dir)
    previous_host = Application.get_env(:handbean, :host)
    Handbean.Host.put!(%{data_dir: home_dir})

    ExUnit.Callbacks.on_exit(fn ->
      drain_runtime_tasks()
      sync_runtime_observers()

      if old_home, do: System.put_env("HOME", old_home), else: System.delete_env("HOME")

      if previous_host,
        do: Application.put_env(:handbean, :host, previous_host),
        else: Application.delete_env(:handbean, :host)

      remove_home!(home_dir)
    end)

    :ok
  end

  defmodule CrashProvider do
    @behaviour Handbean.Agent.Provider

    @impl true
    def complete(_messages, _tool_defs, _config) do
      raise "intentional provider crash"
    end

    @impl true
    def stream(_messages, _tool_defs, _config, _on_chunk) do
      raise "intentional provider crash"
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

  defmodule HoldProvider do
    @behaviour Handbean.Agent.Provider

    @impl true
    def complete(_messages, _tool_defs, config) do
      send(Map.fetch!(config, :notify), {:held, self()})

      receive do
        :release -> :ok
      after
        5_000 -> :ok
      end

      {:ok,
       %{
         stop_reason: :end_turn,
         messages: [Handbean.Agent.Message.assistant("ok")],
         usage: %{input_tokens: 1, output_tokens: 1},
         response_metadata: %{id: "hold-provider", model: "fake-model"}
       }}
    end

    @impl true
    def stream(messages, tool_defs, config, _on_chunk), do: complete(messages, tool_defs, config)
  end

  defmodule NotifyProvider do
    @behaviour Handbean.Agent.Provider

    @impl true
    def complete(messages, _tool_defs, config) do
      send(Map.fetch!(config, :notify), {:provider_messages, messages})

      {:ok,
       %{
         stop_reason: :end_turn,
         messages: [Handbean.Agent.Message.assistant("ok")],
         usage: %{input_tokens: 1, output_tokens: 1},
         response_metadata: %{id: "notify-provider", model: "fake-model"}
       }}
    end

    @impl true
    def stream(messages, tool_defs, config, _on_chunk), do: complete(messages, tool_defs, config)
  end

  defmodule FailingInboundStore do
    def append(_conversation_id, _entry, _opts), do: {:error, :eisdir}
  end

  def tmp_no_policy_workspace do
    dir =
      Path.join(
        System.tmp_dir!(),
        "sigil_coord_nopolicy_" <> Integer.to_string(System.unique_integer([:positive]))
      )

    File.mkdir_p!(dir)

    old = System.get_env("HANDBEAN_MODELS_FILE")
    models_path = Path.join(dir, "models.json")

    File.write!(
      models_path,
      ~s({"providers": {"fake": {"baseUrl": "http://localhost", "api": "openai-chat-completions", "apiKey": "sk-fake", "models": [{"id": "fake-model", "name": "Fake Model"}]}}})
    )

    System.put_env("HANDBEAN_MODELS_FILE", models_path)

    ExUnit.Callbacks.on_exit(fn ->
      if old,
        do: System.put_env("HANDBEAN_MODELS_FILE", old),
        else: System.delete_env("HANDBEAN_MODELS_FILE")

      File.rm_rf(dir)
    end)

    dir
  end

  def remove_home!(dir) do
    Enum.reduce_while(1..8, :error, fn attempt, _ ->
      case File.rm_rf(dir) do
        {:ok, _} ->
          {:halt, :ok}

        {:error, reason, _path} ->
          if attempt == 8, do: raise("failed to remove #{dir}: #{inspect(reason)}")
          Process.sleep(25 * attempt)
          {:cont, :error}
      end
    end)
  end

  def drain_runtime_tasks do
    deadline = System.monotonic_time(:millisecond) + 2_000
    await_runtime_tasks(deadline)
  end

  def await_runtime_tasks(deadline) do
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

  def sync_runtime_observers do
    for name <- [Handbean.Runtime.TaskTracker, Handbean.Schedule.Recorder],
        pid = Process.whereis(name),
        is_pid(pid) do
      :sys.get_state(pid)
    end
  end

  def idle_message(sid, request_id) do
    Handbean.Agent.Coordinator.add_message(
      sid,
      "later",
      opts(source: :schedule, require_idle?: true, request_id: request_id, deliver_as: :follow_up)
    )
  end

  def opts(extra \\ []) do
    Keyword.merge(
      [
        workspace_path: tmp_no_policy_workspace(),
        model: "fake/fake-model",
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

  def inbound_user(sid) do
    sid
    |> Handbean.ConversationStore.load_messages()
    |> Enum.find(&(&1["role"] == "user"))
  end

  def assert_receive_run_end(sid) do
    deadline = System.monotonic_time(:millisecond) + 1_000
    wait_for_run_end(sid, deadline)
  end

  def wait_for_run_end(sid, deadline) do
    %{events: events} = Handbean.PubSub.Session.snapshot(sid)

    if Enum.any?(events, &match?(%{kind: :run_end}, &1)) do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        ExUnit.Assertions.flunk("expected run_end event for #{sid}")
      else
        Process.sleep(10)
        wait_for_run_end(sid, deadline)
      end
    end
  end
end
