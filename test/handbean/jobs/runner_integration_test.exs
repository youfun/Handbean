defmodule Handbean.Jobs.RunnerIntegrationTest do
  use Handbean.DataCase, async: false

  @moduletag :unix_jobs

  alias Handbean.Agent.{Coordinator, Message}
  alias Handbean.Jobs

  defmodule Provider do
    @behaviour Handbean.Agent.Provider

    def complete(messages, _defs, config) do
      if Enum.any?(messages, &(&1.role == :tool_result)) do
        send(config.notify, {:job_launched, self(), messages})

        receive do
          :finish ->
            {:ok, %{stop_reason: :end_turn, messages: [Message.assistant("done")], usage: %{}}}
        end
      else
        call = %{
          type: "tool_use",
          id: "launch-job",
          name: config.tool_name,
          input: config.tool_input
        }

        {:ok, %{stop_reason: :tool_use, messages: [Message.tool_use([call])], usage: %{}}}
      end
    end

    def stream(messages, defs, config, _callback), do: complete(messages, defs, config)
  end

  setup do
    old_home = System.get_env("HOME")
    old_host = Application.get_env(:handbean, :host)
    dir = Path.join(System.tmp_dir!(), "job-runner-#{Ecto.UUID.generate()}")
    File.mkdir_p!(dir)
    System.put_env("HOME", dir)
    {:ok, conversation} = Handbean.ConversationStore.create("ws")

    on_exit(fn ->
      Coordinator.cancel(conversation["id"])

      # Runner completion can leave a supervised thread-report task and queued
      # lifecycle consumers behind. Finish their storage work before changing
      # HOME or removing the fixture, not merely before the Runner exits.
      for pid <- Task.Supervisor.children(Handbean.AgentRunTaskSupervisor) do
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
      end

      Handbean.PubSub.Session.snapshot(conversation["id"])
      :ok = Handbean.SessionSupervisor.stop_session(conversation["id"])
      GenServer.call(Handbean.Runtime.TaskTracker, :snapshot)

      if old_home, do: System.put_env("HOME", old_home), else: System.delete_env("HOME")

      if old_host,
        do: Application.put_env(:handbean, :host, old_host),
        else: Application.delete_env(:handbean, :host)

      File.rm_rf!(dir)
    end)

    %{dir: dir, id: conversation["id"]}
  end

  for outcome <- [:completed, :cancelled],
      tool <- [Handbean.Tool.Builtin.Bash, Handbean.Tool.Builtin.RunElixirScript] do
    test "real Runner #{outcome} closes #{tool} jobs after an Executor wait returns", %{
      dir: dir,
      id: id
    } do
      tool = unquote(tool)

      input =
        if unquote(tool == Handbean.Tool.Builtin.RunElixirScript) do
          Handbean.Host.put!(%{shell: false, host_script: true, browser_backend: nil})

          File.write!(
            Path.join(dir, "wait.exs"),
            "IO.write(\"ready\"); receive do: (:never -> :ok)"
          )

          %{"path" => "wait.exs", "job" => true, "wait_ms" => 100}
        else
          %{"command" => "printf ready; read -r answer", "job" => true, "wait_ms" => 100}
        end

      {:ok, ack} =
        Coordinator.add_message(id, "run a job",
          workspace_path: dir,
          model: "fake",
          provider: Provider,
          provider_config: %{notify: self(), tool_name: tool.name(), tool_input: input},
          tools: [tool],
          source: :cli,
          middleware: [],
          mcp: false
        )

      assert_receive {:job_launched, task, messages}, 3_000
      tool_message = Enum.find(messages, &(&1.role == :tool_result))
      refute hd(tool_message.content).is_error

      context = %{
        conversation_id: id,
        run_id: ack.run_id,
        working_directory: dir,
        tool_timeout: 10_000
      }

      assert {:ok, %{jobs: [%{job_id: job_id, state: :running}]}} =
               Jobs.status(nil, 0, 500, context)

      assert {:ok, %{output: "ready", state: :running}} = Jobs.status(job_id, 0, 100, context)

      monitor = Process.monitor(ack.run_pid)
      if unquote(outcome) == :completed, do: send(task, :finish), else: Coordinator.cancel(id)
      assert_receive {:DOWN, ^monitor, :process, _, _}, 3_000

      assert {:ok, %{state: :cancelled}} =
               Jobs.status(job_id, 0, 5_000, %{context | run_id: "next-run"})
    end
  end
end
