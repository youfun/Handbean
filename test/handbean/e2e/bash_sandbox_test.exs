defmodule Handbean.E2E.BashSandboxTest do
  @moduledoc """
  Coordinator → Runner → Turn → bash → transcript, under the OS workspace sandbox.

  Run: mix test --include e2e test/handbean/e2e/bash_sandbox_test.exs
  """

  use ExUnit.Case, async: false

  alias Handbean.Agent.Coordinator
  alias Handbean.PubSub.Session

  @moduletag :e2e
  @moduletag :os_sandbox

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Handbean.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Handbean.Repo, {:shared, self()})

    root = Path.join(System.tmp_dir!(), "bash-sandbox-e2e-#{Ecto.UUID.generate()}")
    home = Path.join(root, "home")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(home)
    File.mkdir_p!(workspace)

    # Outside target lives in the repo, not under /tmp: Linux gives the sandbox a
    # private tmpfs there, which would hide the denial instead of reporting it.
    outside = Path.join(File.cwd!(), "tmp_bash_sandbox_e2e_#{System.unique_integer([:positive])}")

    old_home = System.get_env("HOME")
    old_models = System.get_env("HANDBEAN_MODELS_FILE")
    models = Path.join(root, "models.json")

    File.write!(
      models,
      ~s({"providers": {"fake": {"baseUrl": "http://localhost", "api": "openai-chat-completions", "apiKey": "sk-fake", "models": [{"id": "fake-model", "name": "Fake Model"}]}}})
    )

    System.put_env("HOME", home)
    System.put_env("HANDBEAN_MODELS_FILE", models)

    on_exit(fn ->
      if old_home, do: System.put_env("HOME", old_home), else: System.delete_env("HOME")

      if old_models,
        do: System.put_env("HANDBEAN_MODELS_FILE", old_models),
        else: System.delete_env("HANDBEAN_MODELS_FILE")

      File.rm_rf!(root)
      File.rm(outside)
    end)

    %{workspace: workspace, outside: outside}
  end

  defp start(sid, workspace, inputs) do
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)
    :ok = Session.subscribe(sid)
    on_exit(fn -> Handbean.TestSupport.E2EHarness.cancel!(sid) end)

    Coordinator.add_message(sid, "run the script",
      workspace_path: workspace,
      model: "fake/fake-model",
      provider: Handbean.TestSupport.FakeProvider,
      provider_config: %{scenario: {:bash_script, inputs}},
      tools: [Handbean.Tool.Builtin.Bash],
      source: :cli,
      streaming: false,
      max_turns: 6
    )
  end

  defp await_event(kind) do
    receive do
      {:agent_event, %{kind: ^kind, payload: payload}} -> payload
    after
      15_000 -> flunk("no #{kind} event")
    end
  end

  # Waits for the Runner, its fire-and-forget completion tasks (thread
  # collaboration meta updates), and the TaskTracker, so nothing reads or
  # rebuilds the conversation index after on_exit restores HOME; a late reader
  # would otherwise reach the real ~/.handbean.
  defp await_terminal_run_end(sid) do
    payload = await_run_end(sid)

    for pid <- Task.Supervisor.children(Handbean.AgentRunTaskSupervisor) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    end

    {:ok, session} = Session.start_or_get(session_id: sid)
    :sys.get_state(session)
    if tracker = Process.whereis(Handbean.Runtime.TaskTracker), do: :sys.get_state(tracker)
    payload
  end

  defp await_run_end(sid) do
    payload = await_event(:run_end)

    if payload[:status] in [:interrupted, "interrupted"] do
      await_run_end(sid)
    else
      case Registry.lookup(Handbean.AgentRunRegistry, sid) do
        [{pid, _}] ->
          ref = Process.monitor(pid)
          assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000

        [] ->
          :ok
      end

      payload
    end
  end

  defp tool_entries(sid) do
    {:ok, entries} = Handbean.ConversationTranscriptStore.list(sid)
    Enum.filter(entries, &(&1["content_type"] == "tool"))
  end

  test "workspace writes persist, outside writes are denied with a retry hint", %{
    workspace: workspace,
    outside: outside
  } do
    sid = "bash-sandbox-e2e-#{System.unique_integer([:positive])}"

    assert {:ok, _} =
             start(sid, workspace, [
               %{"command" => "printf inside > inside.txt"},
               %{"command" => "target=$(printf '%s' '#{outside}'); printf x > \"$target\""}
             ])

    assert %{status: status} = await_terminal_run_end(sid)
    assert status in [:completed, "completed"]

    assert File.read!(Path.join(workspace, "inside.txt")) == "inside"
    refute File.exists?(outside)

    assert [write_inside, write_outside] = tool_entries(sid)
    assert write_inside["tool_name"] == "bash"
    assert write_inside["tool_status"] == "done"
    assert write_outside["output"] =~ "[sandbox]"
    assert write_outside["output"] =~ "unsandboxed=true"
  end

  test "unsandboxed retry pauses for approval and runs only after approval", %{
    workspace: workspace,
    outside: outside
  } do
    sid = "bash-sandbox-e2e-#{System.unique_integer([:positive])}"

    assert {:ok, %{run_pid: runner}} =
             start(sid, workspace, [
               %{
                 "command" => "target=$(printf '%s' '#{outside}'); printf approved > \"$target\"",
                 "unsandboxed" => true
               }
             ])

    request = await_event(:tool_approval_requested)
    assert [%{tool_call_id: call_id, tool_name: "bash"}] = request.action_requests

    # The task emits the request before returning its interrupted State. Wait
    # for that task, then ask the Runner that owns the approval lifecycle.
    case :sys.get_state(runner).task do
      %Task{pid: task} ->
        ref = Process.monitor(task)
        assert_receive {:DOWN, ^ref, :process, ^task, _}, 5_000

      nil ->
        :ok
    end

    assert {:ok, %{status: :awaiting_approval}} = Coordinator.status(sid)
    refute File.exists?(outside)

    assert :ok =
             Coordinator.resume(sid, [
               %{"tool_call_id" => call_id, "tool_name" => "bash", "action" => "approve"}
             ])

    assert %{status: status} = await_terminal_run_end(sid)
    assert status in [:completed, "completed"]
    assert File.read!(outside) == "approved"
    assert [%{"tool_status" => "done"}] = tool_entries(sid)
  end
end
