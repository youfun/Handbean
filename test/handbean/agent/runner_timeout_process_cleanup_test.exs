defmodule Handbean.Agent.RunnerTimeoutProcessCleanupTest do
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

  defmodule BlockingProvider do
    @behaviour Handbean.Agent.Provider

    @impl true
    def complete(_messages, _tool_defs, config) do
      notify = Map.fetch!(config, :notify)
      send(notify, {:blocking_provider_started, self()})

      receive do
        :finish ->
          {:ok,
           %{
             stop_reason: :end_turn,
             messages: [Handbean.Agent.Message.assistant("done")],
             usage: %{input_tokens: 1, output_tokens: 1},
             response_metadata: %{}
           }}
      after
        5_000 ->
          raise "blocking provider timed out"
      end
    end

    @impl true
    def stream(messages, tool_defs, config, _on_chunk), do: complete(messages, tool_defs, config)
  end

  defmodule ResumeBudgetProvider do
    @behaviour Handbean.Agent.Provider

    @impl true
    def complete(messages, _tool_defs, config) do
      if Enum.any?(messages, &(&1.role == :tool_result)) do
        send(config.notify, {:resumed_deadline, config[:run_deadline]})

        receive do
          :finish -> :ok
        end
      end

      {:ok,
       %{
         stop_reason: :tool_use,
         messages: [
           Handbean.Agent.Message.assistant([
             %{
               type: "tool_use",
               id: "call-1",
               name: "run_elixir_script",
               input: %{"path" => "approval.exs"}
             }
           ])
         ],
         usage: %{input_tokens: 1, output_tokens: 1}
       }}
    end

    @impl true
    def stream(messages, tool_defs, config, _on_chunk), do: complete(messages, tool_defs, config)
  end

  defmodule ApprovalProvider do
    @behaviour Handbean.Agent.Provider

    @impl true
    def complete(_messages, _tool_defs, _config) do
      {:ok,
       %{
         stop_reason: :tool_use,
         messages: [
           Handbean.Agent.Message.assistant([
             %{
               type: "tool_use",
               id: "call-1",
               name: "run_elixir_script",
               input: %{"path" => "approval.exs"}
             }
           ])
         ],
         usage: %{input_tokens: 1, output_tokens: 1}
       }}
    end

    @impl true
    def stream(messages, tool_defs, config, _on_chunk), do: complete(messages, tool_defs, config)
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

  test "interactive approval wait pauses the inactivity watchdog" do
    sid = "runner-approval-deadline-#{System.unique_integer([:positive])}"
    workspace = approval_workspace()
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)
    :ok = Session.subscribe(sid)

    assert {:ok, %{run_pid: runner}} =
             Coordinator.add_message(
               sid,
               "needs approval",
               opts(
                 workspace_path: workspace,
                 timeout_ms: 100,
                 provider: ApprovalProvider,
                 tools: [Handbean.Tool.Builtin.RunElixirScript],
                 middleware: [Handbean.Agent.Middleware.ToolGuard]
               )
             )

    assert_receive {:agent_event, %{kind: :tool_approval_requested}}, 1_000

    assert_eventually(fn ->
      assert {:ok, %{status: :awaiting_approval, deadline: nil}} = Coordinator.status(sid)
    end)

    refute_receive {:agent_event, %{kind: :run_end, payload: %{status: "timeout"}}}, 200
    assert Process.alive?(runner)
    assert :ok = Coordinator.cancel(sid)
  end

  test "resuming an interactive approval starts a fresh inactivity window" do
    sid = "runner-resume-budget-#{System.unique_integer([:positive])}"
    workspace = approval_workspace()
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)
    :ok = Session.subscribe(sid)
    parent = self()

    assert {:ok, %{run_id: run_id}} =
             Coordinator.add_message(
               sid,
               "approve then block",
               opts(
                 workspace_path: workspace,
                 timeout_ms: 300,
                 provider: ResumeBudgetProvider,
                 provider_config: %{notify: parent},
                 tools: [Handbean.Tool.Builtin.RunElixirScript],
                 middleware: [Handbean.Agent.Middleware.ToolGuard]
               )
             )

    assert_receive {:agent_event, %{kind: :tool_approval_requested}}, 1_000

    assert_eventually(fn ->
      assert {:ok, %{deadline: nil, status: :awaiting_approval}} = Coordinator.status(sid)
    end)

    assert :ok =
             Coordinator.resume(sid, [%{"tool_call_id" => "call-1", "action" => "approve"}],
               expected_run_id: run_id
             )

    assert_receive {:resumed_deadline, received_deadline}, 1_000
    assert received_deadline == nil

    assert_receive {:agent_event,
                    %{
                      kind: :run_end,
                      payload: %{status: "timeout", reason: :run_inactivity_timeout}
                    }},
                   1_200

    refute_receive {:agent_event, %{kind: :run_end, payload: %{status: :completed}}}, 50
  end

  test "run timeout kills the bash child started by the tool" do
    sid = "runner-bash-kill-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)
    workspace = Handbean.Host.data_dir()
    shell_file = Path.join(workspace, "tmp-bash-shell-#{System.unique_integer([:positive])}.txt")
    child_file = Path.join(workspace, "tmp-bash-child-#{System.unique_integer([:positive])}.txt")

    provider =
      Module.concat(__MODULE__, "BashHangProvider#{System.unique_integer([:positive])}")

    defmodule provider do
      @behaviour Handbean.Agent.Provider

      def complete(messages, tool_defs, config) do
        if Enum.any?(messages, &(&1.role == :tool_result)) do
          Handbean.Agent.RunnerTimeoutProcessCleanupTest.BlockingProvider.complete(
            messages,
            tool_defs,
            config
          )
        else
          {:ok,
           %{
             stop_reason: :tool_use,
             messages: [
               Handbean.Agent.Message.assistant([
                 %{
                   type: "tool_use",
                   id: "bash-1",
                   name: "bash",
                   input: %{
                     "command" =>
                       "echo $$ > #{config.shell_file}; sleep 30 & echo $! > #{config.child_file}; wait",
                     "wait_ms" => 100
                   }
                 }
               ])
             ],
             usage: %{input_tokens: 1, output_tokens: 1}
           }}
        end
      end

      def stream(messages, tool_defs, config, _on_chunk),
        do: complete(messages, tool_defs, config)
    end

    :ok = Session.subscribe(sid)

    assert {:ok, _} =
             Coordinator.add_message(
               sid,
               "hang",
               opts(
                 timeout_ms: 1_500,
                 provider: provider,
                 provider_config: %{
                   shell_file: shell_file,
                   child_file: child_file,
                   notify: self()
                 },
                 tools: [Handbean.Tool.Builtin.Bash],
                 middleware: [],
                 workspace_path: workspace,
                 working_directory: workspace
               )
             )

    assert_eventually(fn ->
      assert File.exists?(shell_file) and File.exists?(child_file)
    end)

    {shell_pid, child_pid} = host_process_ids(shell_file, child_file)

    assert_receive {:agent_event,
                    %{
                      kind: :run_end,
                      payload: %{status: "timeout", reason: :run_inactivity_timeout}
                    }},
                   3_000

    assert_eventually(fn ->
      refute alive_os?(shell_pid)
      refute alive_os?(child_pid)
    end)

    File.rm(shell_file)
    File.rm(child_file)
  end

  test "killing the runner cleans the bash process group" do
    sid = "runner-bash-crash-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)
    workspace = Handbean.Host.data_dir()

    shell_file =
      Path.join(workspace, "tmp-bash-crash-shell-#{System.unique_integer([:positive])}.txt")

    child_file =
      Path.join(workspace, "tmp-bash-crash-child-#{System.unique_integer([:positive])}.txt")

    provider = Module.concat(__MODULE__, "CrashBash#{System.unique_integer([:positive])}")

    defmodule provider do
      @behaviour Handbean.Agent.Provider

      def complete(_messages, _tool_defs, config) do
        {:ok,
         %{
           stop_reason: :tool_use,
           messages: [
             Handbean.Agent.Message.assistant([
               %{
                 type: "tool_use",
                 id: "bash-crash",
                 name: "bash",
                 input: %{
                   "command" =>
                     "echo $$ > #{config.shell_file}; sleep 30 & echo $! > #{config.child_file}; wait"
                 }
               }
             ])
           ],
           usage: %{input_tokens: 1, output_tokens: 1}
         }}
      end

      def stream(messages, tool_defs, config, _on_chunk),
        do: complete(messages, tool_defs, config)
    end

    assert {:ok, %{run_pid: runner}} =
             Coordinator.add_message(
               sid,
               "crash owner",
               opts(
                 timeout_ms: 30_000,
                 provider: provider,
                 provider_config: %{shell_file: shell_file, child_file: child_file},
                 tools: [Handbean.Tool.Builtin.Bash],
                 middleware: [],
                 workspace_path: workspace,
                 working_directory: workspace
               )
             )

    assert_eventually(fn ->
      assert File.exists?(shell_file) and File.exists?(child_file)
    end)

    {shell_pid, child_pid} = host_process_ids(shell_file, child_file)
    assert Process.alive?(runner)
    Process.exit(runner, :kill)

    assert_eventually(fn ->
      refute alive_os?(shell_pid)
      refute alive_os?(child_pid)
    end)

    File.rm(shell_file)
    File.rm(child_file)
  end

  test "a finished bash command leaves no child process" do
    sid = "runner-bash-done-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)
    workspace = Handbean.Host.data_dir()
    marker = Path.join(workspace, "tmp-bash-done-#{System.unique_integer([:positive])}.txt")

    provider = Module.concat(__MODULE__, "DoneBash#{System.unique_integer([:positive])}")

    defmodule provider do
      @behaviour Handbean.Agent.Provider

      def complete(messages, _tool_defs, config) do
        if Enum.any?(messages, &(&1.role == :tool_result)) do
          {:ok,
           %{
             stop_reason: :end_turn,
             messages: [Handbean.Agent.Message.assistant("done")],
             usage: %{input_tokens: 1, output_tokens: 1}
           }}
        else
          {:ok,
           %{
             stop_reason: :tool_use,
             messages: [
               Handbean.Agent.Message.assistant([
                 %{
                   type: "tool_use",
                   id: "bash-done",
                   name: "bash",
                   input: %{"command" => "echo done > #{config.marker}"}
                 }
               ])
             ],
             usage: %{input_tokens: 1, output_tokens: 1}
           }}
        end
      end

      def stream(messages, tool_defs, config, _on_chunk),
        do: complete(messages, tool_defs, config)
    end

    :ok = Session.subscribe(sid)

    assert {:ok, _} =
             Coordinator.add_message(
               sid,
               "finish",
               opts(
                 provider: provider,
                 provider_config: %{marker: marker},
                 tools: [Handbean.Tool.Builtin.Bash],
                 middleware: [],
                 workspace_path: workspace,
                 working_directory: workspace
               )
             )

    assert_receive {:agent_event, %{kind: :run_end, payload: %{status: status}}}, 2_000
    assert status in [:completed, "completed"]
    assert File.read!(marker) == "done\n"
    File.rm(marker)
  end

  test "delegated run deadline ends a stuck provider and ignores a late result" do
    sid = "runner-deadline-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)
    :ok = Session.subscribe(sid)
    entered = :counters.new(1, [])

    assert {:ok, %{run_pid: runner}} =
             Coordinator.add_message(
               sid,
               "stuck",
               opts(
                 timeout_ms: 50,
                 delegated?: true,
                 provider: BlockingProvider,
                 provider_config: %{notify: self(), counter: entered}
               )
             )

    assert_receive {:agent_event,
                    %{kind: :run_end, payload: %{status: "timeout", reason: :run_timeout}}},
                   1_000

    refute_receive {:agent_event, %{kind: :run_end, payload: %{status: :completed}}}, 100
    refute Process.alive?(runner)
    assert {:error, :not_found} = Handbean.Agent.Runner.status(sid)
    _ = entered
  end

  defp approval_workspace do
    workspace = Path.join(Handbean.Host.data_dir(), "approval-workspace")
    File.mkdir_p!(Path.join(workspace, ".handbean"))
    File.write!(Path.join(workspace, "approval.exs"), "1\n")

    File.write!(
      Handbean.WorkspaceSettings.path(workspace),
      Handbean.JSON.encode!(%{"tools" => %{"per_tool" => %{"run_elixir_script" => "prompt"}}})
    )

    workspace
  end

  defp host_process_ids(shell_file, child_file) do
    shell_pid = shell_file |> File.read!() |> String.trim() |> String.to_integer()
    child_pid = child_file |> File.read!() |> String.trim() |> String.to_integer()

    if :os.type() == {:unix, :linux} do
      # $$ and $! are namespace-local under Bubblewrap, not host PIDs.
      # Resolve the shell by its unique command marker, then the child within
      # that same PID namespace. Never mistake a namespace PID of 2 for kthreadd.
      processes =
        for name <- File.ls!("/proc"),
            {pid, ""} <- [Integer.parse(name)],
            {:ok, status} <- [File.read("/proc/#{pid}/status")],
            [_, ids] <- [Regex.run(~r/^NSpid:\s*(.+)$/m, status)] do
          {pid, ids |> String.split() |> List.last() |> String.to_integer()}
        end

      assert [{host_shell, ^shell_pid}] =
               Enum.filter(processes, fn {pid, local} ->
                 local == shell_pid and
                   case File.read("/proc/#{pid}/cmdline") do
                     {:ok, command} -> String.contains?(command, shell_file)
                     _ -> false
                   end
               end)

      namespace = File.read_link!("/proc/#{host_shell}/ns/pid")

      assert [{host_child, ^child_pid}] =
               Enum.filter(processes, fn {pid, local} ->
                 local == child_pid and
                   File.read_link("/proc/#{pid}/ns/pid") == {:ok, namespace}
               end)

      {host_shell, host_child}
    else
      {shell_pid, child_pid}
    end
  end

  defp alive_os?(pid) when is_integer(pid) do
    case System.cmd("ps", ["-p", Integer.to_string(pid), "-o", "stat="]) do
      {state, 0} ->
        String.trim(state) != "" and not String.starts_with?(String.trim(state), ["Z", "X"])

      _ ->
        false
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
