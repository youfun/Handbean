defmodule Handbean.Jobs.CleanupTest do
  use ExUnit.Case, async: false
  alias Handbean.Jobs.Cleaner
  alias Handbean.Platform.{ProcessManager, ProcessRunner}

  @moduletag :unix_jobs

  setup do
    unless Process.whereis(Cleaner), do: start_supervised!(Cleaner)
    :ok
  end

  test "pipeline and background children are cleaned with the managed group" do
    {id, port, identity} = gated("sleep 30 | cat & printf ready; read -r answer")
    Port.command(port, "go\n")
    assert_receive {^port, {:data, "ready"}}, 5_000
    Cleaner.cancel(id)
    assert_receive {:job_cleanup, ^id, :ok}, 5_000
    assert :ok = ProcessManager.cleanup_job_group(identity)
    close_port(port)
  end

  test "leader exit does not discard cleanup responsibility for remaining descendants" do
    {id, port, identity} = gated("sleep 30 >/dev/null 2>&1 & exit 7")
    Port.command(port, "go\n")
    assert_receive {^port, {:exit_status, 7}}, 5_000
    Cleaner.cancel(id)
    assert_receive {:job_cleanup, ^id, :ok}, 5_000
    assert :ok = ProcessManager.cleanup_job_group(identity)
    close_port(port)
  end

  test "brutal Port owner death is cleaned by the surviving application ledger" do
    parent = self()
    cleaner = Process.whereis(Cleaner)
    :erlang.trace(cleaner, true, [:send])
    on_exit(fn -> :erlang.trace(cleaner, false, [:send]) end)

    owner =
      spawn(fn ->
        {id, port, identity} = gated("sleep 30 >/dev/null 2>&1 & printf ready; read -r answer")
        Port.command(port, "go\n")

        receive do
          {^port, {:data, "ready"}} -> send(parent, {:ready, id, identity})
        end

        receive do
          :never -> :ok
        end
      end)

    on_exit(fn -> Process.exit(owner, :kill) end)

    assert_receive {:ready, id, identity}, 5_000
    ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^owner, :killed}

    assert_receive {:trace, ^cleaner, :send_to_non_existing_process, {:job_cleanup, ^id, :ok},
                    ^owner},
                   5_000

    assert Process.alive?(cleaner)
    assert :ok = ProcessManager.cleanup_job_group(identity)
  end

  test "a reused leader identity is not signalled" do
    {id, port, identity} = gated("printf must_not_run")

    wrong_identity =
      case identity do
        %{backend: :darwin, started: {sec, usec, abstime}} ->
          %{identity | started: {sec, usec, abstime + 1}}

        %{backend: :linux} ->
          %{identity | started: "wrong-generation"}
      end

    assert {:error,
            "Process identity changed or cannot be verified; refusing to signal reused PID"} =
             ProcessManager.cleanup_job_group(wrong_identity)

    assert Port.info(port) != nil
    Cleaner.cancel(id)
    assert_receive {:job_cleanup, ^id, :ok}, 5_000
    close_port(port)
  end

  defp gated(command) do
    {:ok, port, pid} = ProcessRunner.open_gated_bash(command, File.cwd!())
    {:ok, identity} = ProcessManager.verify_job_group(pid)
    id = "cleanup-test-#{System.unique_integer([:positive])}"
    {:ok, ^identity} = Cleaner.register(id, pid, self())
    {id, port, identity}
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
