ExUnit.start()

defmodule HandbeanProbe.ScreenSettle do
  @moduledoc """
  Deliver the replies of `HandbeanProbe.HomeScreen` off-screen tasks to an
  in-BEAM `Mob.ScreenCase` view.

  Screen tasks run under `HandbeanProbe.TaskSupervisor` via
  `Task.Supervisor.async_nolink/2`, so their `{ref, result}` replies land in
  the test process (the screen's mailbox in-BEAM). `settle/1` feeds every
  reply back through `handle_info/2` and, while any task started by this
  process is still alive, blocks for the next one — no sleeps, no fixed
  waits, deterministic completion.
  """

  @timeout 15_000

  def settle(view) do
    receive do
      {ref, {tag, _generation, _result}} = msg when is_reference(ref) and is_atom(tag) ->
        settle(deliver(view, msg))

      {ref, {tag, _generation, _target, _result}} = msg when is_reference(ref) and is_atom(tag) ->
        settle(deliver(view, msg))
    after
      0 ->
        if pending_task?(), do: await(view), else: view
    end
  end

  defp await(view) do
    receive do
      {ref, {tag, _generation, _result}} = msg when is_reference(ref) and is_atom(tag) ->
        settle(deliver(view, msg))

      {ref, {tag, _generation, _target, _result}} = msg when is_reference(ref) and is_atom(tag) ->
        settle(deliver(view, msg))

      {:DOWN, _ref, :process, _pid, _reason} ->
        settle(view)
    after
      @timeout ->
        raise "screen task did not reply within #{@timeout}ms"
    end
  end

  defp deliver(%{socket: socket, module: module} = view, msg) do
    {:noreply, socket} = module.handle_info(msg, socket)
    %{view | socket: socket}
  end

  # A task this process is monitoring and that still runs under the screen's
  # Task.Supervisor. `:DOWN` handling above covers the exit-before-reply window.
  defp pending_task? do
    {:monitors, monitors} = Process.info(self(), :monitors)
    children = Task.Supervisor.children(HandbeanProbe.TaskSupervisor)
    Enum.any?(monitors, fn {:process, pid} -> pid in children end)
  end
end

defmodule HandbeanProbe.RuntimeCleanup do
  @moduledoc false

  def stop! do
    Enum.each(Handbean.AgentRunSupervisor.which_runs(), fn {_, pid, _, _} ->
      _ = Handbean.AgentRunSupervisor.stop_run(pid)
    end)

    Enum.each(Task.Supervisor.children(Handbean.AgentRunTaskSupervisor), fn pid ->
      _ = Task.Supervisor.terminate_child(Handbean.AgentRunTaskSupervisor, pid)
    end)

    Enum.each(Handbean.SessionSupervisor.which_sessions(), fn {_, pid, _, _} ->
      _ = GenServer.call(pid, :snapshot)
      _ = DynamicSupervisor.terminate_child(Handbean.SessionSupervisor, pid)
    end)

    # Drain lifecycle events already forwarded by Session before a test restores
    # its host data directory or removes temporary files.
    _ = GenServer.call(Handbean.Runtime.TaskTracker, :snapshot)

    home = Handbean.Home.path()

    for path <- registered_ids(ExFff.Registry),
        path == home or String.starts_with?(path, home <> "/"),
        {pid, _} <- Registry.lookup(ExFff.Registry, path) do
      GenServer.stop(pid)
    end

    :ok
  end

  defp registered_ids(registry) do
    Registry.select(registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end
end

data_dir =
  Path.join(System.tmp_dir!(), "handbean_probe_test_#{System.unique_integer([:positive])}")

File.mkdir_p!(data_dir)
File.mkdir_p!(Path.join(data_dir, ".handbean"))
System.put_env("MOB_DATA_DIR", data_dir)
System.put_env("HOME", data_dir)
System.put_env("HANDBEAN_WORKSPACES_FILE", Path.join(data_dir, ".handbean/workspaces.json"))
System.put_env("HANDBEAN_MODELS_FILE", Path.join(data_dir, ".handbean/models.json"))
Application.put_env(:handbean, :workspaces_file, Path.join(data_dir, ".handbean/workspaces.json"))
Application.put_env(:handbean, :models_file, Path.join(data_dir, ".handbean/models.json"))
Handbean.Host.put!(%{data_dir: data_dir, shell: false, mcp: false})

Application.put_env(:handbean, Handbean.Repo,
  database: Path.join(data_dir, "handbean.db"),
  pool_size: 5
)

HandbeanProbe.App.configure_error_tracker!()
{:ok, _} = Application.ensure_all_started(:ecto_sqlite3)

Ecto.Migrator.with_repo(Handbean.Repo, fn repo ->
  Ecto.Migrator.run(repo, Handbean.Paths.migrations_dir(), :up, all: true)
end)

{:ok, _} = HandbeanProbe.Repo.start_link()
Ecto.Migrator.run(HandbeanProbe.Repo, :up, all: true)

{:ok, _} = Application.ensure_all_started(:handbean)
Ecto.Migrator.run(Handbean.Repo, Handbean.Paths.migrations_dir(), :up, all: true)
:ok = HandbeanProbe.App.ensure_task_supervisor()
:ok = HandbeanProbe.ShareIntake.Lock.ensure_started()
:ok = HandbeanProbe.ShareCopy.ensure_started()
:ok = HandbeanProbe.Platform.IOS.Registry.ensure_started()
