defmodule HandbeanProbe.HomeScreen.Schedules do
  @moduledoc """
  HomeScreen controller for the native scheduled-task center.

  Persistence and dispatch stay with the shared owners
  (`Handbean.Schedule.Store`, `Handbean.Schedule.Dispatch`); every read and
  write runs off-screen through `HandbeanProbe.HomeScreen.Async` under one
  `:schedules` scope, so a reply that lands after a newer request is dropped
  instead of merging into moved-on state. Conversation transitions go back
  through `HandbeanProbe.HomeScreen.Nav`, which owns workspace switches.
  """

  use Gettext, backend: HandbeanProbe.Gettext
  import Mob.Socket, only: [assign: 3]

  alias HandbeanProbe.HomeScreen.{Async, Nav, Notice, Requests}
  alias HandbeanProbe.NativeSchedules

  alias Handbean.{ConversationStore, WorkspaceStore}
  alias Handbean.Schedule
  alias Handbean.Schedule.{Dispatch, Presentation, Store}

  @scope :schedules
  @run_history_limit 5

  def load(socket) do
    {_generation, socket} = Requests.bump(socket, @scope)

    socket
    |> assign(:schedules, NativeSchedules.loading(socket.assigns.schedules))
    |> Async.run(:schedules_loaded, fn -> safely(&fetch/0) end, scope: @scope)
  end

  @doc """
  Refresh after a schedule row changed anywhere in the runtime.

  A mutation in flight reloads when its own reply lands, so its
  `:schedule_changed` broadcast is skipped here instead of bumping the scope
  under the running task.
  """
  def reload(socket) do
    if socket.assigns.schedules && socket.assigns.schedules.busy? do
      socket
    else
      load(socket)
    end
  end

  def handle(_event, %{assigns: %{schedules: %{busy?: true}}} = socket), do: socket

  def handle({:tap, :schedule_refresh}, socket), do: load(socket)

  def handle({:tap, {:schedule_pause, id}}, socket) when is_binary(id),
    do: mutate(socket, :schedule_paused, id, &Store.pause/1)

  def handle({:tap, {:schedule_resume, id}}, socket) when is_binary(id),
    do: mutate(socket, :schedule_resumed, id, &Store.resume/1)

  def handle({:tap, {:schedule_run_now, id}}, socket) when is_binary(id) do
    run_mutation(socket, :schedule_run_claimed, fn ->
      with {:ok, entry} <- Store.get(id),
           {:ok, claim} <- Store.run_now(entry) do
        Dispatch.run(claim)
        :ok
      end
    end)
  end

  def handle({:tap, {:schedule_ask_delete, id}}, socket) when is_binary(id),
    do: assign(socket, :schedules, NativeSchedules.ask_delete(socket.assigns.schedules, id))

  def handle({:tap, :schedule_delete}, socket) do
    case socket.assigns.schedules.confirming do
      id when is_binary(id) ->
        run_mutation(socket, :schedule_deleted, fn ->
          with {:ok, entry} <- Store.get(id), do: Store.delete(entry)
        end)

      _ ->
        socket
    end
  end

  def handle({kind, :schedule_dismiss_confirm}, socket) when kind in [:tap, :dismiss],
    do: assign(socket, :schedules, NativeSchedules.dismiss_confirm(socket.assigns.schedules))

  def handle({:tap, {:schedule_open, id}}, socket) when is_binary(id) do
    case NativeSchedules.find(socket.assigns.schedules, id) do
      nil ->
        socket

      entry ->
        case open_in_workspace(socket, entry) do
          {:ok, socket} -> socket
          {:error, message} -> Notice.put_error(socket, message)
        end
    end
  end

  def handle({:tap, {:schedule_revise, id}}, socket) when is_binary(id) do
    case NativeSchedules.find(socket.assigns.schedules, id) do
      nil ->
        socket

      entry ->
        case open_in_workspace(socket, entry) do
          {:ok, socket} ->
            assign(socket, :draft, gettext("Revise \"%{name}\":", name: entry.name || ""))

          {:error, message} ->
            Notice.put_error(socket, message)
        end
    end
  end

  def handle({:tap, {:schedule_toggle_instruction, id}}, socket) when is_binary(id),
    do:
      assign(socket, :schedules, NativeSchedules.toggle_instruction(socket.assigns.schedules, id))

  def handle(_event, socket), do: socket

  # ── async results ──

  def loaded(socket, result),
    do: assign(socket, :schedules, NativeSchedules.loaded(socket.assigns.schedules, result))

  def result(:schedule_run_claimed, :ok, socket) do
    socket
    |> Notice.put_info(gettext("Queued to run now"))
    |> load()
  end

  def result(:schedule_run_claimed, {:error, reason}, socket) do
    socket
    |> Notice.put_error(
      gettext("Could not run the scheduled task: %{reason}", reason: inspect(reason))
    )
    |> load()
  end

  def result(kind, {:ok, _entry}, socket) when kind in [:schedule_paused, :schedule_resumed],
    do: socket |> assign(:schedules, NativeSchedules.idle(socket.assigns.schedules)) |> load()

  def result(kind, {:error, reason}, socket) when kind in [:schedule_paused, :schedule_resumed] do
    socket
    |> assign(:schedules, NativeSchedules.idle(socket.assigns.schedules))
    |> Notice.put_error(
      gettext("Could not update the scheduled task: %{reason}", reason: inspect(reason))
    )
    |> load()
  end

  def result(:schedule_deleted, :ok, socket) do
    socket
    |> assign(
      :schedules,
      socket.assigns.schedules |> NativeSchedules.idle() |> NativeSchedules.dismiss_confirm()
    )
    |> load()
  end

  def result(:schedule_deleted, {:error, reason}, socket) do
    socket
    |> assign(:schedules, NativeSchedules.idle(socket.assigns.schedules))
    |> Notice.put_error(
      gettext("Could not delete the scheduled task: %{reason}", reason: inspect(reason))
    )
    |> load()
  end

  def result(_kind, _result, socket), do: socket

  # ── internals ──

  defp mutate(socket, kind, id, fun) do
    run_mutation(socket, kind, fn ->
      with {:ok, entry} <- Store.get(id), do: fun.(entry)
    end)
  end

  defp run_mutation(socket, kind, fun) do
    {_generation, socket} = Requests.bump(socket, @scope)

    socket
    |> assign(:schedules, NativeSchedules.busy(socket.assigns.schedules))
    |> Async.run(kind, fn -> safely(fun) end, scope: @scope)
  end

  defp safely(fun) do
    fun.()
  rescue
    _ -> {:error, "scheduled task operation failed"}
  catch
    :exit, _ -> {:error, "scheduled task operation timed out or failed"}
  end

  defp fetch do
    entries = Store.list()
    runs = Store.recent_runs_by_schedule(Enum.map(entries, & &1.id), @run_history_limit)
    now = Schedule.now()

    views =
      Map.new(entries, fn entry ->
        {entry.id, Presentation.once(entry, Map.get(runs, entry.id, []), now)}
      end)

    titles = ConversationStore.titles_for_ids(Enum.map(entries, & &1.conversation_id))
    workspace_names = Map.new(WorkspaceStore.list(), &{&1["id"], &1["name"]})

    {:ok,
     %{
       items: entries,
       runs: runs,
       views: views,
       titles: titles,
       workspace_names: workspace_names,
       now: now
     }}
  end

  # The task list is cross-workspace, so opening a conversation can mean
  # switching workspace first; `Nav.apply_workspace/3` owns that transition.
  defp open_in_workspace(socket, entry) do
    case ConversationStore.get(entry.conversation_id) do
      {:ok, conversation} ->
        case WorkspaceStore.get(entry.workspace_id) do
          {:ok, workspace} ->
            {:ok,
             socket
             |> assign(:page, :chat)
             |> Notice.clear()
             |> Nav.apply_workspace(workspace, conversation)}

          _ ->
            {:error, gettext("That workspace is no longer available")}
        end

      _ ->
        {:error, gettext("The task's conversation is unavailable")}
    end
  end
end
