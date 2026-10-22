defmodule Handbean.ConversationCollaborationSupport do
  @moduledoc false

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Handbean.ConversationStore

  defmodule FailingInboundStore do
    def append(_conversation_id, _entry, _opts), do: {:error, :eisdir}
  end

  defmodule HoldProvider do
    @behaviour Handbean.Agent.Provider
    def complete(_messages, _tools, config) do
      notify = config[:notify] || Process.whereis(:conversation_hold_capture)
      if is_pid(notify), do: send(notify, {:held, self(), config})

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

  defmodule SearchBackend do
    @behaviour Handbean.Search.Backend

    # These tests exercise collaboration, not workspace indexing. Avoid starting
    # file watchers and Git workers that outlive the fixture's temporary checkout.
    @impl true
    def ensure_started(_workspace), do: {:ok, :unused}

    @impl true
    def await(_index, _timeout), do: :ok

    @impl true
    def search(_index, query, _opts),
      do: {:ok, %{paths: [], query: query, duration_ms: 0, status: :ready}}

    @impl true
    def files(_index, _opts), do: {:ok, %{paths: [], status: :ready}}

    @impl true
    def touch(_index, _path), do: :ok

    @impl true
    def update_paths(_index, _paths), do: :ok

    @impl true
    def set_git_status(_index, _entries), do: :ok

    @impl true
    def ignored_path?(_workspace, _path), do: false

    @impl true
    def refresh(_index), do: :ok
  end

  def setup do
    home = Path.join(System.tmp_dir!(), "handoffs-#{Ecto.UUID.generate()}")
    on_exit(fn -> File.rm_rf!(home) end)
    File.mkdir_p!(home)

    env = Map.new(~w(HOME HANDBEAN_MODELS_FILE), &{&1, System.get_env(&1)})

    application_env =
      Map.new([:test_provider, :search_backend], &{&1, Application.fetch_env(:handbean, &1)})

    on_exit(fn ->
      for {key, value} <- env,
          do: if(value, do: System.put_env(key, value), else: System.delete_env(key))

      for {key, value} <- application_env do
        case value do
          {:ok, previous} -> Application.put_env(:handbean, key, previous)
          :error -> Application.delete_env(:handbean, key)
        end
      end
    end)

    System.put_env("HOME", home)
    models = Path.join(home, "models.json")

    File.write!(
      models,
      ~s({"providers":{"fake":{"baseUrl":"http://localhost","api":"openai-chat-completions","apiKey":"fake","models":[{"id":"fake-model","name":"Fake"}]}}})
    )

    System.put_env("HANDBEAN_MODELS_FILE", models)
    Application.put_env(:handbean, :test_provider, %{module: __MODULE__.HoldProvider})
    Application.put_env(:handbean, :search_backend, __MODULE__.SearchBackend)
    test_pid = self()
    hold_capture = spawn(fn -> forward_hold_messages(test_pid) end)

    on_exit(fn ->
      Process.exit(hold_capture, :kill)
      deadline = System.monotonic_time(:millisecond) + 10_000
      await_process!(hold_capture, deadline, :hold_capture)
    end)

    Process.register(hold_capture, :conversation_hold_capture)
    existing_ids = conversation_ids() |> MapSet.new()

    # Callbacks run in reverse order: drain runs while the sandbox and fixture
    # configuration are available, then stop the relay and restore the environment.
    on_exit(fn -> settle_runtime!(existing_ids) end)

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
      conversation_run_opts: opts
    }

    %{source: source["id"], target: target["id"], context: context, opts: opts}
  end

  def catalog do
    ~s({"providers":{"fake":{"baseUrl":"http://localhost","api":"openai-chat-completions","apiKey":"fake","models":[{"id":"fake-model","name":"Fake"}]},"other":{"baseUrl":"http://127.0.0.1:9","api":"openai-chat-completions","apiKey":"other-key","provider":"openai-compat","models":[{"id":"other-model","name":"Other"}]}}})
  end

  # The shared SQL sandbox exposes this test's conversations, including those
  # created in additional workspaces. Keep any pre-existing rows out of cleanup.
  defp conversation_ids do
    ConversationStore.list(include_internal?: true)
    |> Enum.map(& &1["id"])
  end

  defp settle_runtime!(existing_ids) do
    deadline = System.monotonic_time(:millisecond) + 10_000
    do_settle_runtime!(existing_ids, deadline)
  end

  defp do_settle_runtime!(existing_ids, deadline) do
    ids =
      conversation_ids()
      |> Enum.reject(&MapSet.member?(existing_ids, &1))

    Enum.each(ids, &cancel_and_wait(&1, deadline))
    await_runtime_tasks!(deadline)

    running = Enum.filter(ids, &running?/1)
    callbacks = Task.Supervisor.children(Handbean.AgentRunTaskSupervisor)

    cond do
      running == [] and callbacks == [] ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        raise "runtime cleanup did not converge: running=#{inspect(running)} callbacks=#{inspect(callbacks)}"

      true ->
        do_settle_runtime!(existing_ids, deadline)
    end
  end

  defp await_runtime_tasks!(deadline) do
    case Task.Supervisor.children(Handbean.AgentRunTaskSupervisor) do
      [] ->
        :ok

      tasks ->
        Enum.each(tasks, &await_process!(&1, deadline, :terminal_callback))
        await_runtime_tasks!(deadline)
    end
  end

  defp cancel_and_wait(id, deadline) do
    case Handbean.Agent.Runner.status(id) do
      {:ok, %{run_supervisor: supervisor} = status} when is_pid(supervisor) ->
        if status.running?, do: Handbean.Agent.Runner.cancel(id)
        await_process!(supervisor, deadline, {:run_supervisor, id})

      _ ->
        :ok
    end
  end

  defp running?(id) do
    match?({:ok, %{running?: true}}, Handbean.Agent.Runner.status(id))
  end

  defp await_process!(pid, deadline, label) do
    ref = Process.monitor(pid)
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        raise "runtime cleanup timed out waiting for #{inspect(label)} pid=#{inspect(pid)}"
    end
  end

  defp forward_hold_messages(test_pid) do
    receive do
      message ->
        send(test_pid, message)
        forward_hold_messages(test_pid)
    end
  end
end
