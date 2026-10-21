defmodule Handbean.Agent.RunnerPermissionIdentityTest do
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

  test "permission mode changes reconcile an already pending approval inside Runner" do
    sid = "runner-policy-reconcile-#{System.unique_integer([:positive])}"
    workspace = default_prompt_workspace()

    {:ok, _} =
      Handbean.ConversationStore.create("default", id: sid, permission_mode: "prompt")

    :ok = Session.subscribe(sid)

    script = fn messages, _tools ->
      if Enum.any?(messages, &(&1.role == :tool_result)) do
        "completed after policy reconciliation"
      else
        {:tools,
         [
           %{
             name: "run_elixir_script",
             input: %{"path" => "approval.exs"}
           }
         ]}
      end
    end

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(
               sid,
               "approve through policy",
               opts(
                 workspace_path: workspace,
                 provider_config: %{scenario: {:script, script}},
                 tools: [Handbean.Tool.Builtin.RunElixirScript],
                 middleware: [Handbean.Agent.Middleware.ToolGuard]
               )
             )

    assert_receive {:agent_event, %{kind: :tool_approval_requested}}, 1_000

    assert_eventually(fn ->
      assert {:ok, %{status: :awaiting_approval}} = Coordinator.status(sid)
    end)

    assert {:ok, _metadata} =
             Handbean.Permissions.ConversationMode.update(sid, :yolo, source: :test)

    assert_receive {:agent_event, %{kind: :run_resumed}}, 1_000

    assert_receive {:agent_event, %{kind: :run_end, payload: %{status: status}}}
                   when status in [:completed, "completed"],
                   1_000
  end

  test "yolo does not reconcile a per-tool prompt" do
    sid = "runner-explicit-prompt-#{System.unique_integer([:positive])}"
    workspace = approval_workspace()
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)
    :ok = Session.subscribe(sid)

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(
               sid,
               "keep prompting",
               opts(
                 workspace_path: workspace,
                 provider: ApprovalProvider,
                 tools: [Handbean.Tool.Builtin.RunElixirScript],
                 middleware: [Handbean.Agent.Middleware.ToolGuard]
               )
             )

    assert_receive {:agent_event, %{kind: :tool_approval_requested}}, 1_000

    assert_eventually(fn ->
      assert {:ok, %{status: :awaiting_approval}} = Coordinator.status(sid)
    end)

    assert {:ok, _metadata} =
             Handbean.Permissions.ConversationMode.update(sid, :yolo, source: :test)

    refute_receive {:agent_event, %{kind: :run_resumed}}, 100
    assert {:ok, %{status: :awaiting_approval}} = Coordinator.status(sid)
    assert :ok = Coordinator.cancel(sid)
  end

  test "Runner validates run and approval batch identities atomically" do
    sid = "runner-approval-identity-#{System.unique_integer([:positive])}"
    workspace = approval_workspace()
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)
    :ok = Session.subscribe(sid)

    assert {:ok, %{run_id: run_id}} =
             Coordinator.add_message(
               sid,
               "approve",
               opts(
                 workspace_path: workspace,
                 provider: ApprovalProvider,
                 tools: [Handbean.Tool.Builtin.RunElixirScript],
                 middleware: [Handbean.Agent.Middleware.ToolGuard]
               )
             )

    assert_receive {:agent_event, %{kind: :run_end, payload: %{status: initial_status}}}, 1_000
    assert initial_status in [:interrupted, "interrupted"]

    assert_eventually(fn ->
      assert {:ok,
              %{
                status: :awaiting_approval,
                approval_batch_id: batch_id,
                interrupt_data: interrupt_data
              }} = Coordinator.status(sid)

      assert is_binary(batch_id)
      assert interrupt_data.approval_batch_id == batch_id
    end)

    {:ok, %{approval_batch_id: batch_id, run_supervisor: run_supervisor}} =
      Coordinator.status(sid)

    supervisor_ref = Process.monitor(run_supervisor)
    decisions = [%{"tool_call_id" => "call-1", "action" => "deny"}]

    assert {:error, {:run_mismatch, ^run_id}} =
             Handbean.Agent.Runner.cancel(sid, "stale-run")

    assert {:error, :stale_approval} =
             Handbean.Agent.Runner.resume(sid, decisions, run_id, "stale-batch")

    assert {:ok, %{status: :awaiting_approval}} = Coordinator.status(sid)
    assert :ok = Handbean.Agent.Runner.resume(sid, decisions, run_id, batch_id)
    assert_receive {:agent_event, %{kind: :run_resumed}}, 1_000

    assert_eventually(fn ->
      assert {:ok, %{status: :awaiting_approval, approval_batch_id: next_batch_id}} =
               Coordinator.status(sid)

      assert next_batch_id != batch_id
    end)

    assert :ok = Handbean.Agent.Runner.cancel(sid, run_id)
    assert_receive {:DOWN, ^supervisor_ref, :process, ^run_supervisor, _reason}, 1_000
  end

  defp default_prompt_workspace do
    workspace = Path.join(Handbean.Host.data_dir(), "default-prompt-workspace")
    File.mkdir_p!(Path.join(workspace, ".handbean"))
    File.write!(Path.join(workspace, "approval.exs"), "1\n")

    File.write!(
      Handbean.WorkspaceSettings.path(workspace),
      Handbean.JSON.encode!(%{"tools" => %{"default_mode" => "prompt"}})
    )

    workspace
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
