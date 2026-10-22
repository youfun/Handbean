defmodule Handbean.JobsTest do
  use ExUnit.Case, async: false

  alias Handbean.Jobs
  alias Handbean.Jobs.{Cleaner, Server}
  alias Handbean.Tool.Builtin.{Bash, JobCancel, JobStatus}

  @moduletag :unix_jobs

  @terminal_states [:completed, :failed, :cancelled, :timed_out]

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

  test "wait budgets distinguish launch from status queries", %{context: context} do
    assert {:ok, 125} = Jobs.wait_budget(9_000, %{context | tool_timeout: 250})
    assert {:ok, 5_000} = Jobs.wait_budget(9_000, context)
    assert {:ok, 23} = Jobs.wait_budget(23, context)
    assert {:error, _} = Jobs.wait_budget(100, Map.delete(context, :tool_timeout))
    assert {:error, _} = Jobs.wait_budget(-1, context)

    long_context = %{context | tool_timeout: 120_000}
    assert {:ok, 30_000} = Jobs.status_wait_budget(60_000, long_context)
    assert {:ok, 125} = Jobs.status_wait_budget(9_000, %{context | tool_timeout: 250})
    assert {:error, _} = Jobs.status_wait_budget(-1, context)
    assert get_in(JobStatus.input_schema(), [:properties, :wait_ms, :maximum]) == 30_000
  end

  test "job status recovers handles when the tool binding supplies an empty job id", %{
    context: context
  } do
    assert {:ok, completed} =
             Jobs.start_beam(
               :script,
               fn _sink -> {:ok, "done"} end,
               30_000,
               5_000,
               %{context | tool_call_id: "recover-empty-id"}
             )

    for input <- [%{"wait_ms" => 0}, %{"job_id" => "", "wait_ms" => 0}] do
      assert {:ok, text, %{job: %{jobs: jobs}}} = JobStatus.execute(input, context)
      assert Enum.any?(jobs, &(&1.job_id == completed.job_id))
      assert text =~ completed.job_id
    end
  end

  test "managed Bash returns executor-compatible text and a recoverable job handle", %{
    context: context
  } do
    assert {:ok, sync_text, %{job: sync_job, recovery: :poll}} =
             Bash.execute(%{"command" => "printf sync"}, context)

    assert is_binary(sync_text)
    assert sync_job.state == :completed
    assert sync_job.output == "sync"
    assert sync_job.elapsed_ms >= 0
    assert sync_job.output_idle_ms >= 0
    assert sync_job.remaining_ms == 0
    assert sync_job.timeout_ms == 120_000
    assert sync_job.total_output_bytes == 4

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

  test "managed Bash returns current-conversation file effects", %{
    context: context,
    runner: runner
  } do
    repo =
      Path.join([
        File.cwd!(),
        "tmp",
        "handbean_job_changes_#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(repo)
    git!(repo, ["init"])
    git!(repo, ["config", "user.email", "test@example.com"])
    git!(repo, ["config", "user.name", "Handbean Test"])
    File.write!(Path.join(repo, "tracked.txt"), "before\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "fixture"])

    scoped = %{
      context
      | working_directory: repo,
        tool_call_id: "changes",
        conversation_id: context.conversation_id <> "-changes"
    }

    assert :ok = Jobs.open_run(scoped, runner)

    on_exit(fn ->
      Jobs.close_run(scoped, :completed)
      File.rm_rf!(repo)
    end)

    assert {:ok, _text, %{changes: changes, job: %{state: :completed}} = details} =
             Bash.execute(
               %{"command" => "printf 'after\\n' > tracked.txt; printf 'new\\n' > created.txt"},
               scoped
             )

    assert Enum.sort(Enum.map(changes, &Path.basename(&1.file_path))) == [
             "created.txt",
             "tracked.txt"
           ]

    projected = Handbean.Agent.Tool.ResultContract.project_details(details)
    assert length(projected.changes) == 2
  end

  test "large change batches retain an explicit count when tool details are bounded" do
    changes =
      for index <- 1..33 do
        %{
          file_path: "lib/file_#{index}.ex",
          change_snapshot_ref: "snapshot-#{index}",
          change_type: "write",
          existed_before: false,
          existed_after: true,
          after_sha256: String.duplicate(Integer.to_string(rem(index, 10)), 64),
          reversible: true
        }
      end

    projected = Handbean.Agent.Tool.ResultContract.project_details(%{changes: changes})

    assert projected.partial == true
    assert projected.change_count == 33
    assert length(Map.get(projected, :changes, [])) <= 32
  end

  test "launch wait ignores output while status returns unread output immediately", %{
    context: context
  } do
    task =
      Task.async(fn ->
        Jobs.start(
          "printf ready; read -r answer",
          File.cwd!(),
          30_000,
          1_000,
          %{context | tool_call_id: "launch-output"}
        )
      end)

    assert Task.yield(task, 100) == nil
    assert {:ok, %{state: :running, output: "ready"} = job} = Task.await(task, 5_000)

    assert {:ok, %{state: :running, output: "ready", cursor: cursor}} =
             Jobs.status(job.job_id, 0, 5_000, context)

    assert cursor == 5
    release(job.job_id, "done\n")
    assert {:ok, %{state: :completed}} = Jobs.status(job.job_id, cursor, 5_000, context)
  end

  test "status wait wakes on new output and reports monotonic runtime facts", %{context: context} do
    assert {:ok, job} = launch("read -r answer; printf '%s' \"$answer\"", context)
    assert job.state == :running
    assert job.total_output_bytes == 0

    task = Task.async(fn -> Jobs.status(job.job_id, job.cursor, 5_000, context) end)
    assert Task.yield(task, 50) == nil
    release(job.job_id, "result\n")

    assert {:ok,
            %{
              output: "result",
              cursor: cursor,
              total_output_bytes: 6,
              elapsed_ms: elapsed_ms,
              output_idle_ms: output_idle_ms,
              remaining_ms: remaining_ms
            }} = Task.await(task, 1_000)

    assert elapsed_ms >= job.elapsed_ms
    assert output_idle_ms >= 0
    assert remaining_ms in 0..30_000

    later = await_terminal(job.job_id, context, cursor)
    assert later.elapsed_ms >= elapsed_ms
    assert later.state == :completed
    assert later.remaining_ms == 0
  end

  test "status wait does not wake for incomplete UTF-8", %{context: context} do
    parent = self()

    fun = fn sink ->
      sink.(<<?a, 0xE4, 0xBD>>)
      send(parent, {:partial_utf8, self()})

      receive do
        :finish_utf8 ->
          sink.(<<0xA0, ?z>>)
          {:ok, "done"}
      end
    end

    beam_context = %{context | tool_call_id: "utf8-beam"}

    assert {:ok, %{state: :running, output: "a", cursor: 1} = job} =
             Jobs.start_beam(:script, fun, 30_000, 500, beam_context)

    assert_receive {:partial_utf8, worker}
    task = Task.async(fn -> Jobs.status(job.job_id, job.cursor, 5_000, context) end)
    assert Task.yield(task, 50) == nil
    send(worker, :finish_utf8)

    assert {:ok, %{output: "你z", cursor: 5}} = Task.await(task, 1_000)
    assert {:ok, %{state: :completed}} = Jobs.status(job.job_id, 5, 5_000, context)
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

    assert {:ok, update} = Jobs.status(id, 0, 5_000, context)
    assert update.output == "result"

    terminal =
      if update.state == :completed do
        update
      else
        assert {:ok, terminal} = Jobs.status(id, update.cursor, 5_000, context)
        terminal
      end

    assert terminal.state == :completed
    assert terminal.exit_code == 0
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

    on_exit(fn ->
      if Process.alive?(server), do: :erlang.trace(server, false, [:receive])
    end)

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
    update = await_terminal(id, context)
    assert update.output == "readyonce"
    assert update.state == :completed
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
    assert Enum.all?(jobs, &Map.has_key?(&1, :elapsed_ms))
    assert Enum.all?(jobs, &Map.has_key?(&1, :output_idle_ms))
    assert Enum.all?(jobs, &Map.has_key?(&1, :remaining_ms))
    assert Enum.all?(jobs, &Map.has_key?(&1, :total_output_bytes))
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

    on_exit(fn ->
      if Process.alive?(cleaner), do: :erlang.trace(cleaner, false, [:send])
    end)

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

  defp await_terminal(id, context), do: await_terminal(id, context, 0)
  defp await_terminal(id, context, cursor), do: await_terminal(id, context, cursor, [], 20)

  defp await_terminal(id, context, cursor, output, attempts) when attempts > 0 do
    assert {:ok, status} = Jobs.status(id, cursor, 5_000, context)
    output = [status.output | output]

    if status.state in @terminal_states do
      %{status | output: output |> Enum.reverse() |> IO.iodata_to_binary()}
    else
      await_terminal(id, context, status.cursor, output, attempts - 1)
    end
  end

  defp await_terminal(id, _context, _cursor, _output, 0) do
    flunk("job did not reach a terminal state: #{id}")
  end

  defp git!(cwd, args) do
    {output, status} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    assert status == 0, output
    output
  end

  defp launch(command, context), do: Jobs.start(command, File.cwd!(), 30_000, 500, context)

  defp release(id, input) do
    port = :sys.get_state(Server).jobs[id].port
    Port.command(port, input)
  end
end
