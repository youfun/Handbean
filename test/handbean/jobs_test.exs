defmodule Handbean.JobsTest do
  use ExUnit.Case, async: false

  alias Handbean.Jobs
  alias Handbean.Jobs.{Cleaner, Server}
  alias Handbean.Tool.Builtin.{Bash, JobCancel, JobStatus}

  @moduletag :unix_jobs

  setup do
    unless Process.whereis(Cleaner), do: start_supervised!(Cleaner)
    unless Process.whereis(Server), do: start_supervised!(Server)

    runner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    id = Integer.to_string(System.unique_integer([:positive]))

    context = %{
      conversation_id: "jobs-test-#{id}",
      run_id: "run-#{id}",
      working_directory: File.cwd!(),
      tool_timeout: 10_000,
      tool_call_id: "call-1"
    }

    assert :ok = Jobs.open_run(context, runner)

    on_exit(fn ->
      Jobs.close_run(context, :cancelled)
      send(runner, :stop)
    end)

    %{context: context, runner: runner}
  end

  test "wait budget respects request and actual outer timeout", %{context: context} do
    assert {:ok, 125} = Jobs.wait_budget(9_000, %{context | tool_timeout: 250})
    assert {:ok, 5_000} = Jobs.wait_budget(9_000, context)
    assert {:ok, 23} = Jobs.wait_budget(23, context)
    assert {:error, _} = Jobs.wait_budget(100, Map.delete(context, :tool_timeout))
    assert {:error, _} = Jobs.wait_budget(-1, context)
  end

  test "managed Bash returns executor-compatible text and a recoverable job handle", %{
    context: context
  } do
    assert {:ok, sync_text, %{job: sync_job, recovery: :poll}} =
             Bash.execute(%{"command" => "printf sync"}, context)

    assert is_binary(sync_text)
    assert sync_job.state == :completed
    assert sync_job.output == "sync"

    assert {:ok, text, %{job: job}} =
             Bash.execute(
               %{"command" => "printf async", "job" => true},
               %{context | tool_call_id: "call-explicit"}
             )

    assert job.state == :completed
    assert job.output == "async"
    assert text =~ job.job_id
    assert text =~ "cursor"
  end

  test "wait expiration does not kill job, and tool call retries do not execute again", %{
    context: context
  } do
    assert {:ok, first} = launch("read -r answer; printf '%s' \"$answer\"", context)
    assert first.state == :running
    assert {:ok, retry} = launch("printf MUST_NOT_EXECUTE", context)
    assert first.job_id == retry.job_id
    assert {:ok, %{jobs: [%{job_id: id}]}} = Jobs.status(nil, 0, 500, context)
    assert id == first.job_id
    release(id, "result\n")

    assert {:ok, %{state: :completed, output: "result", exit_code: 0}} =
             Jobs.status(id, 0, 5_000, context)

    assert {:ok, %{output: ""}} = Jobs.status(id, 6, 500, context)
    assert {:ok, %{state: :completed}} = Jobs.cancel(id, context)
  end

  test "nonzero exit, timeout and cancellation are distinct", %{context: context} do
    assert {:ok, %{state: :failed, exit_code: 7}} =
             Jobs.start("exit 7", File.cwd!(), 10_000, 3_000, context)

    timed = %{context | tool_call_id: "timed"}
    assert {:ok, timeout_job} = Jobs.start("read -r answer", File.cwd!(), 100, 3_000, timed)
    assert timeout_job.state == :timed_out
    assert {:ok, job} = launch("read -r answer", %{context | tool_call_id: "cancel"})
    assert {:ok, %{state: :cancelling}} = Jobs.cancel(job.job_id, context)
    assert {:ok, %{state: state}} = Jobs.cancel(job.job_id, context)
    assert state in [:cancelling, :cancelled]
    assert {:ok, %{state: :cancelled}} = Jobs.status(job.job_id, 0, 5_000, context)
  end

  test "killing the tool caller after admission preserves a recoverable, deduplicated job", %{
    context: context
  } do
    server = Process.whereis(Server)
    :erlang.trace(server, true, [:receive])
    on_exit(fn -> :erlang.trace(server, false, [:receive]) end)

    caller =
      spawn(fn ->
        Jobs.start(
          "printf ready; read -r answer; printf '%s' \"$answer\"",
          File.cwd!(),
          30_000,
          5_000,
          context
        )
      end)

    on_exit(fn -> Process.exit(caller, :kill) end)
    assert_receive {:trace, ^server, :receive, {_port, {:data, "ready"}}}, 5_000
    ref = Process.monitor(caller)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^ref, :process, ^caller, :killed}
    assert {:ok, %{jobs: [%{job_id: id, state: :running}]}} = Jobs.status(nil, 0, 500, context)
    assert {:ok, %{job_id: ^id, state: :running}} = launch("printf duplicate", context)
    release(id, "once\n")
    assert {:ok, %{state: :completed, output: "readyonce"}} = Jobs.status(id, 0, 5_000, context)
  end

  for status <- [:completed, :max_turns, :budget_exceeded, :halted, :error, :cancelled],
      representation <- [:atom, :string] do
    test "run #{status} (#{representation}) closes admission and cancels accepted jobs", %{
      context: context
    } do
      status = unquote(if representation == :atom, do: status, else: Atom.to_string(status))
      assert {:ok, job} = launch("read -r answer", context)
      assert :ok = Jobs.close_run(context, status)
      assert :ok = Jobs.close_run(context, status)
      assert {:error, _} = launch("printf unauthorized", %{context | tool_call_id: "late"})
      assert {:ok, %{state: :cancelled}} = Jobs.status(job.job_id, 0, 5_000, context)
      later = %{context | run_id: "later"}
      assert {:ok, %{state: :cancelled}} = Jobs.status(job.job_id, 0, 500, later)
    end
  end

  test "approval pauses retain work; runner death cancels after run tree is gone", %{
    context: context,
    runner: runner
  } do
    assert {:ok, job} = launch("read -r answer", context)

    for pause <- [:interrupted, "interrupted", :awaiting_approval, "awaiting_approval"] do
      assert :ok = Jobs.close_run(context, pause)
    end

    assert {:ok, %{state: :running}} = Jobs.status(job.job_id, 0, 100, context)
    ref = Process.monitor(runner)
    Process.exit(runner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^runner, :killed}

    assert {:ok, %{state: :cancelled}} =
             Jobs.status(job.job_id, 0, 5_000, %{context | run_id: "later"})
  end

  test "conversation and canonical workspace both scope queries and cancellation", %{
    context: context
  } do
    assert {:ok, job} = launch("read -r answer", context)

    for outsider <- [
          %{context | conversation_id: "other"},
          %{context | working_directory: "/tmp"}
        ] do
      assert {:error, _} = Jobs.status(job.job_id, 0, 500, outsider)
      assert {:error, _} = Jobs.cancel(job.job_id, outsider)
      assert {:ok, %{jobs: []}} = Jobs.status(nil, 0, 500, outsider)
    end

    assert {:ok, text, %{job: %{state: :cancelling}}} =
             JobCancel.execute(%{"job_id" => job.job_id}, context)

    assert text =~ "cancelling"

    assert {:ok, text, _} =
             JobStatus.execute(%{"job_id" => job.job_id, "wait_ms" => 5_000}, context)

    assert text =~ "cancelled"
  end

  test "per-run concurrency is bounded", %{context: context} do
    for n <- 1..4 do
      assert {:ok, %{state: :running}} =
               launch("read -r answer", %{context | tool_call_id: "call-#{n}"})
    end

    assert {:error, "Job capacity exhausted"} =
             launch("printf overflow", %{context | tool_call_id: "call-5"})
  end

  test "terminal history rolls over without blocking new jobs", %{context: context} do
    ids =
      for n <- 1..33 do
        job_context = %{context | tool_call_id: "retained-#{n}"}

        assert {:ok, %{job_id: id, state: :completed}} =
                 Jobs.start_beam(:script, fn _ -> {:ok, "done"} end, 30_000, 5_000, job_context)

        id
      end

    assert {:ok, %{jobs: jobs, limit: 32}} = Jobs.status(nil, 0, 500, context)
    retained_ids = Enum.map(jobs, & &1.job_id)
    assert length(retained_ids) == 32
    assert List.last(ids) in retained_ids
    assert [expired_id] = ids -- retained_ids
    assert expired_id == hd(ids)
    assert {:error, _} = Jobs.status(expired_id, 0, 500, context)
  end

  test "completed results expire only after the run is closed", %{context: context} do
    assert {:ok, job} = Jobs.start("printf done", File.cwd!(), 10_000, 3_000, context)

    :sys.replace_state(Server, fn state ->
      put_in(state.jobs[job.job_id].finished_at, System.monotonic_time(:millisecond) - 1_000_000)
    end)

    send(Server, :prune)
    assert {:ok, _} = Jobs.status(job.job_id, 0, 500, context)
    assert :ok = Jobs.close_run(context, :completed)
    send(Server, :prune)
    assert {:error, _} = Jobs.status(job.job_id, 0, 500, context)
  end

  test "Port owner crash leaves cleanup with Cleaner and never reruns the command", %{
    context: context
  } do
    assert {:ok, job} = launch("printf once; read -r answer", context)
    server = Process.whereis(Server)
    cleaner = Process.whereis(Cleaner)
    group = :sys.get_state(Server).jobs[job.job_id].group
    :erlang.trace(cleaner, true, [:send])
    on_exit(fn -> :erlang.trace(cleaner, false, [:send]) end)
    ref = Process.monitor(server)
    Process.exit(server, :kill)
    assert_receive {:DOWN, ^ref, :process, ^server, :killed}
    id = job.job_id

    assert_receive {:trace, ^cleaner, :send_to_non_existing_process, {:job_cleanup, ^id, :ok},
                    ^server},
                   5_000

    assert :ok = Handbean.Platform.ProcessManager.cleanup_job_group(group)
    assert {:error, _} = Jobs.status(id, 0, 500, context)
  end

  defp launch(command, context), do: Jobs.start(command, File.cwd!(), 30_000, 500, context)

  defp release(id, input) do
    port = :sys.get_state(Server).jobs[id].port
    Port.command(port, input)
  end
end
