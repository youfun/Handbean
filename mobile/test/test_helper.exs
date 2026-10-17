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

data_dir =
  Path.join(System.tmp_dir!(), "handbean_probe_test_#{System.unique_integer([:positive])}")

File.mkdir_p!(data_dir)
System.put_env("MOB_DATA_DIR", data_dir)
System.put_env("HOME", data_dir)
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
