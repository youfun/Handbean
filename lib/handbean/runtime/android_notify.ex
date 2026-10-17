defmodule Handbean.Runtime.AndroidNotify do
  @moduledoc """
  Android host adapter for run-lifecycle notifications.

  The host injects its notifier via `Application.put_env(:handbean, :notifier, ...)`
  (same shape as `:android_intent`): either a module exporting
  `app_visible/0`, `update_running/1`, `show_ended/1` (the `:handbean_notify` NIF
  stub on device) or a `fun/2` receiving `(fun_name, args)`. Without a
  notifier every action is a no-op and the app is treated as not visible.
  """

  @behaviour Handbean.Runtime.NotifyAdapter

  @impl true
  def app_visible? do
    notifier_call(:app_visible, []) == true
  end

  @impl true
  def apply({:update_running, snapshot}) do
    _ = notifier_call(:update_running, [encode_running(snapshot)])
    :ok
  end

  def apply({:system_ended, task, reason}) do
    _ = notifier_call(:show_ended, [encode_ended(task, reason)])
    :ok
  end

  def apply({:in_app_ended, _task, _reason}), do: :ok

  defp encode_running(%{running_count: running, waiting_count: waiting, tasks: tasks}) do
    Handbean.JSON.encode!(%{
      "running_count" => running,
      "waiting_count" => waiting,
      "tasks" => Enum.map(tasks, &encode_task/1)
    })
  end

  defp encode_ended(task, reason) do
    Handbean.JSON.encode!(%{
      "reason" => Atom.to_string(reason),
      "task" => encode_task(task)
    })
  end

  defp encode_task(task) do
    %{
      "conversation_id" => task.conversation_id,
      "run_id" => task.run_id,
      "workspace_id" => task[:workspace_id],
      "title" => task[:title],
      "status" => task[:status] && Atom.to_string(task.status)
    }
  end

  defp notifier_call(fun, args) do
    case Application.get_env(:handbean, :notifier) do
      notifier when is_function(notifier, 2) -> notifier.(fun, args)
      mod when is_atom(mod) and not is_nil(mod) -> Kernel.apply(mod, fun, args)
      _ -> fallback(fun)
    end
  catch
    :error, :undef -> fallback(fun)
    :error, :badarg -> fallback(fun)
  end

  defp fallback(:app_visible), do: false
  defp fallback(_fun), do: :ok
end
