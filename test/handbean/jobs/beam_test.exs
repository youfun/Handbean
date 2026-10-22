defmodule Handbean.Jobs.BeamTest do
  use ExUnit.Case, async: false

  alias Handbean.Jobs
  alias Handbean.Workspace.MixOwner
  alias Handbean.Tool.Builtin.{RunElixirScript, MixProject}

  @terminal_states [:completed, :failed, :cancelled, :timed_out]

  setup do
    previous = Application.get_env(:handbean, :host)
    work = Path.join(System.tmp_dir!(), "beam-job-#{Ecto.UUID.generate()}")
    File.mkdir_p!(work)
    Handbean.Host.put!(%{shell: false, host_script: true, browser_backend: nil})

    context = %{
      conversation_id: Ecto.UUID.generate(),
      run_id: Ecto.UUID.generate(),
      working_directory: work,
      tool_timeout: 10_000,
      tool_call_id: "launch"
    }

    assert :ok = Jobs.open_run(context, self())

    on_exit(fn ->
      Jobs.close_run(context, :completed)
      {:ok, %{jobs: jobs}} = Jobs.status(nil, 0, 0, context)
      for job <- jobs, do: await_terminal(job.job_id, context)

      if previous,
        do: Application.put_env(:handbean, :host, previous),
        else: Application.delete_env(:handbean, :host)

      File.rm_rf!(work)
    end)

    %{context: context, work: work}
  end

  test "script without mix.exs outlives its caller, streams output and returns a value", %{
    context: ctx,
    work: work
  } do
    name = :"beam_job_#{System.unique_integer([:positive])}"
    Process.register(self(), name)

    File.write!(Path.join(work, "report.exs"), """
    child = spawn(fn -> receive do: (:never -> :ok) end)
    IO.puts("ready")
    send(String.to_existing_atom(hd(args)), {:script, self(), child, Process.group_leader()})
    receive do: (:finish -> 42)
    """)

    task =
      Task.async(fn ->
        RunElixirScript.execute(
          %{
            "path" => "report.exs",
            "job" => true,
            "wait_ms" => 100,
            "timeout_ms" => 70_000,
            "args" => [Atom.to_string(name)]
          },
          ctx
        )
      end)

    assert {:ok, _, %{job: %{job_id: id, state: :running}}} = Task.await(task)
    assert_receive {:script, worker, child, io}
    assert Process.alive?(worker)
    assert {:ok, %{output: "ready\n", cursor: cursor}} = Jobs.status(id, 0, 0, ctx)
    assert {:error, _} = Jobs.status(id, 0, 0, %{ctx | conversation_id: "other"})
    send(worker, :finish)
    assert %{state: :completed, result: result} = await_terminal(id, ctx, cursor)
    assert result =~ "42"
    for pid <- [worker, child, io], do: refute(Process.alive?(pid))
    refute File.exists?(Path.join(work, "mix.exs"))
  end

  test "cancel, execution deadline and run close drain spawned BEAM work", %{context: ctx} do
    parent = self()

    for mode <- [:cancel, :timeout, :run_close] do
      context = %{ctx | tool_call_id: Atom.to_string(mode)}
      timeout = if mode == :timeout, do: 1_000, else: 30_000

      assert {:ok, %{job_id: id}} =
               Jobs.start_beam(
                 :script,
                 fn _ ->
                   child = spawn(fn -> receive do: (:never -> :ok) end)
                   send(parent, {:started, self(), child})
                   receive do: (:never -> {:ok, "never"})
                 end,
                 timeout,
                 100,
                 context
               )

      assert_receive {:started, worker, child}
      assert :ok = Jobs.close_run(context, :interrupted)
      assert Process.alive?(worker)

      case mode do
        :cancel -> assert {:ok, _} = Jobs.cancel(id, context)
        :run_close -> assert :ok = Jobs.close_run(context, :completed)
        :timeout -> :ok
      end

      expected = if mode == :timeout, do: :timed_out, else: :cancelled
      assert {:ok, %{state: ^expected}} = Jobs.status(id, 0, 5_000, context)
      refute Process.alive?(worker)
      refute Process.alive?(child)
    end
  end

  test "Mix cancellation waits for the existing owner to restore cwd and globals", %{
    context: ctx,
    work: work
  } do
    parent = self()
    cwd = File.cwd!()
    env = System.get_env("MIX_HOME")

    assert {:ok, %{job_id: id, state: :running}} =
             Jobs.start_beam(
               :mix,
               fn _ ->
                 result =
                   MixOwner.run(fn ->
                     File.cd!(work)
                     System.put_env("MIX_HOME", work)
                     send(parent, {:mix_started, self()})
                     receive do: (:never -> :ok)
                   end)

                 {:ok, inspect(result)}
               end,
               30_000,
               100,
               ctx
             )

    assert_receive {:mix_started, worker}
    assert MixOwner.busy?()
    assert :ok = MixOwner.cancel_for(self())
    assert Process.alive?(worker)
    assert {:error, _, %{busy: true}} = MixOwner.run(fn -> :must_not_run end)
    assert {:ok, _} = Jobs.cancel(id, ctx)
    assert {:ok, %{state: :cancelled}} = Jobs.status(id, 0, 5_000, ctx)
    refute Process.alive?(worker)
    refute MixOwner.busy?()
    assert File.cwd!() == cwd
    assert System.get_env("MIX_HOME") == env
    assert {:ok, :next} = MixOwner.run(fn -> :next end)
  end

  test "a dead caller queued behind the Mix owner cannot start after cancellation", %{
    context: ctx
  } do
    parent = self()
    :sys.suspend(MixOwner)

    try do
      assert {:ok, %{job_id: id}} =
               Jobs.start_beam(
                 :mix,
                 fn _ ->
                   MixOwner.run(fn -> send(parent, :late_mix_started) end)
                   {:ok, "unexpected"}
                 end,
                 30_000,
                 100,
                 ctx
               )

      assert {:ok, _} = Jobs.cancel(id, ctx)
      assert {:ok, %{state: :cancelling}} = Jobs.status(id, 0, 100, ctx)
    after
      :sys.resume(MixOwner)
    end

    {:ok, %{jobs: [job]}} = Jobs.status(nil, 0, 0, ctx)
    assert {:ok, %{state: :cancelled}} = Jobs.status(job.job_id, 0, 5_000, ctx)
    refute_receive :late_mix_started
  end

  test "expired startup acknowledgement never releases user code", %{context: ctx} do
    parent = self()
    :sys.suspend(Jobs.BeamSupervisor)

    try do
      assert {:error, _} =
               Jobs.start_beam(
                 :script,
                 fn _ ->
                   send(parent, :late_script_started)
                   {:ok, "unexpected"}
                 end,
                 30_000,
                 100,
                 ctx
               )
    after
      :sys.resume(Jobs.BeamSupervisor)
    end

    {:ok, %{jobs: [job]}} = Jobs.status(nil, 0, 5_000, ctx)
    assert {:ok, %{state: :cancelled}} = Jobs.status(job.job_id, 0, 5_000, ctx)
    refute_receive :late_script_started
  end

  test "job server death drains BEAM work without restarting it", %{context: ctx} do
    parent = self()

    assert {:ok, %{job_id: id}} =
             Jobs.start_beam(
               :script,
               fn _ ->
                 child = spawn(fn -> receive do: (:never -> :ok) end)
                 send(parent, {:started, self(), child})
                 receive do: (:never -> {:ok, "never"})
               end,
               30_000,
               100,
               ctx
             )

    assert_receive {:started, worker, child}
    owner = :sys.get_state(Jobs.Server).jobs[id].beam
    ref = Process.monitor(owner)
    Process.exit(Process.whereis(Jobs.Server), :kill)
    assert_receive {:DOWN, ^ref, :process, ^owner, :normal}, 2_000
    refute Process.alive?(worker)
    refute Process.alive?(child)
    refute_receive {:started, _, _}
  end

  test "owner kill drains unlinked descendants before reporting failure", %{context: ctx} do
    parent = self()

    assert {:ok, %{job_id: id}} =
             Jobs.start_beam(
               :script,
               fn _ ->
                 child = spawn(fn -> receive do: (:never -> :ok) end)
                 send(parent, {:started, self(), child})
                 receive do: (:never -> {:ok, "never"})
               end,
               30_000,
               100,
               ctx
             )

    assert_receive {:started, worker, child}
    on_exit(fn -> for pid <- [worker, child], do: Process.exit(pid, :kill) end)
    owner = :sys.get_state(Jobs.Server).jobs[id].beam
    Process.exit(owner, :kill)
    assert {:ok, %{state: :failed, cleanup_error: nil}} = Jobs.status(id, 0, 5_000, ctx)
    refute Process.alive?(worker)
    refute Process.alive?(child)
  end

  test "script streams beyond snapshot cap and reports failed snapshot truncation", %{
    context: ctx,
    work: work
  } do
    name = :"beam_output_#{System.unique_integer([:positive])}"
    Process.register(self(), name)

    File.write!(Path.join(work, "output.exs"), """
    IO.write(String.duplicate("x", 40000))
    caller = String.to_existing_atom(hd(args))
    send(caller, {:ready, self()})
    receive do: (:more -> :ok)
    IO.write(String.duplicate("y", 20000) <> "TAIL")
    send(caller, :tail_written)
    receive do: (:finish -> raise "output failure")
    """)

    assert {:ok, _, %{job: %{job_id: id}}} =
             RunElixirScript.execute(
               %{
                 "path" => "output.exs",
                 "job" => true,
                 "wait_ms" => 100,
                 "args" => [Atom.to_string(name)]
               },
               ctx
             )

    assert_receive {:ready, worker}
    assert {:ok, %{output: first, cursor: cursor, truncated: false}} = Jobs.status(id, 0, 0, ctx)
    assert first == String.duplicate("x", 40000)
    send(worker, :more)
    assert_receive :tail_written

    assert {:ok, %{output: tail, cursor: tail_cursor, truncated: false}} =
             Jobs.status(id, cursor, 0, ctx)

    assert tail == String.duplicate("y", 20000) <> "TAIL"
    send(worker, :finish)
    assert %{state: :failed, result: result} = await_terminal(id, ctx, tail_cursor)

    assert {:ok,
            %{
              state: :failed,
              stdout_truncated?: true,
              truncated: true,
              output: output
            }} = Jobs.status(id, 0, 0, ctx)

    assert byte_size(output) == 50000
    assert String.ends_with?(output, "TAIL")
    assert result =~ "output failure"
  end

  test "bounded results and worker failure remain queryable without rerunning", %{context: ctx} do
    assert {:ok, %{job_id: id}} =
             Jobs.start_beam(
               :script,
               fn sink ->
                 sink.(String.duplicate("x", 55_000))
                 {:ok, String.duplicate("y", 60_000)}
               end,
               30_000,
               100,
               ctx
             )

    assert %{state: :completed} = await_terminal(id, ctx)

    assert {:ok,
            %{
              state: :completed,
              output: output,
              result: result,
              truncated: true,
              result_truncated: true
            }} = Jobs.status(id, 0, 0, ctx)

    assert byte_size(output) == 50_000
    assert byte_size(result) <= 50_000

    crash_ctx = %{ctx | tool_call_id: "crash"}
    fun = fn _ -> exit(:worker_crashed) end
    assert {:ok, %{job_id: failed}} = Jobs.start_beam(:script, fun, 30_000, 100, crash_ctx)
    assert {:ok, %{state: :failed}} = Jobs.status(failed, 0, 5_000, ctx)
    assert {:ok, %{job_id: ^failed}} = Jobs.start_beam(:script, fun, 30_000, 100, crash_ctx)
  end

  test "mix_project compiles and runs a dependency-free project as a job", %{
    context: ctx,
    work: work
  } do
    File.write!(Path.join(work, "mix.exs"), """
    defmodule MobileJobFixture.MixProject do
      use Mix.Project
      def project, do: [app: :mobile_job_fixture, version: "0.1.0", deps: []]
    end
    """)

    File.write!(Path.join(work, "mix.lock"), "%{}\n")
    File.mkdir_p!(Path.join(work, "lib"))

    File.write!(Path.join(work, "lib/report.ex"), """
    defmodule MobileJobFixture.Report do
      def run do
        IO.puts("mobile-report")
        6 * 7
      end
    end
    """)

    assert {:ok, _, %{job: %{job_id: id}}} =
             MixProject.execute(
               %{
                 "action" => "run",
                 "module" => "MobileJobFixture.Report",
                 "job" => true,
                 "wait_ms" => 100,
                 "timeout_ms" => 70_000
               },
               ctx
             )

    assert %{state: :completed, result: result, output: output} = await_terminal(id, ctx)

    assert output =~ "mobile-report"
    assert result =~ "42"
    refute MixOwner.busy?()
  end

  test "script return and exception truncation flags survive the job boundary", %{
    context: ctx,
    work: work
  } do
    for {name, source, status, flag} <- [
          {"return", "List.duplicate(String.duplicate(\"z\", 2000), 20)", :completed,
           :return_truncated?},
          {"error", "raise String.duplicate(\"z\", 20000)", :failed, :error_truncated?}
        ] do
      path = name <> ".exs"
      File.write!(Path.join(work, path), source)

      assert {:ok, _, %{job: %{job_id: id}}} =
               RunElixirScript.execute(
                 %{"path" => path, "job" => true, "wait_ms" => 100},
                 %{ctx | tool_call_id: name}
               )

      assert %{state: ^status, result_truncated: false} = result = await_terminal(id, ctx)

      assert result[flag] == true
    end
  end

  test "mix_project tool returns a failed job rather than requiring a shell", %{context: ctx} do
    assert {:ok, _, %{job: %{job_id: id}}} =
             MixProject.execute(%{"action" => "compile", "job" => true, "wait_ms" => 100}, ctx)

    assert %{state: :failed, result: result} = await_terminal(id, ctx)
    assert result =~ "mix.exs"
    refute MixOwner.busy?()
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
end
