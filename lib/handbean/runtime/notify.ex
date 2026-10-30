defmodule Handbean.Runtime.Notify do
  @moduledoc """
  Pure policy for run-lifecycle notifications.

  A task is one Runner execution (`run_id`). The page does not guess
  status; the runtime reports it. Duration does not change ownership.
  """

  @type reason :: :completed | :failed | :cancelled
  @type task :: %{
          required(:conversation_id) => String.t(),
          required(:run_id) => String.t(),
          optional(:workspace_id) => String.t() | nil,
          optional(:scope) => String.t() | nil,
          optional(:title) => String.t() | nil,
          optional(:status) => :running | :waiting_confirmation,
          optional(:waiting_episode) => pos_integer() | nil
        }

  @type snapshot :: %{
          running_count: non_neg_integer(),
          waiting_count: non_neg_integer(),
          tasks: [task()]
        }

  @type context :: %{
          app_visible?: boolean(),
          viewing?: boolean()
        }

  @type action ::
          {:update_running, snapshot()}
          | {:system_ended, task(), reason()}
          | {:in_app_ended, task(), reason()}

  @spec snapshot([task()]) :: snapshot()
  def snapshot(tasks) when is_list(tasks) do
    running = Enum.count(tasks, &(&1.status == :running))
    waiting = Enum.count(tasks, &(&1.status == :waiting_confirmation))
    %{running_count: running, waiting_count: waiting, tasks: tasks}
  end

  @spec actions(snapshot(), {:started | :waiting, task()} | {:ended, task(), reason()}, context()) ::
          [action()]
  def actions(snapshot, event, context)

  def actions(snapshot, {:started, _task}, _context), do: [{:update_running, snapshot}]
  def actions(snapshot, {:waiting, _task}, _context), do: [{:update_running, snapshot}]

  def actions(snapshot, {:ended, task, reason}, context) do
    ended =
      cond do
        reason == :cancelled ->
          nil

        context.app_visible? and context.viewing? ->
          nil

        context.app_visible? ->
          {:in_app_ended, task, reason}

        true ->
          {:system_ended, task, reason}
      end

    Enum.reject([{:update_running, snapshot}, ended], &is_nil/1)
  end
end
