defmodule Handbean.Schedule.Recorder do
  @moduledoc """
  Writes the terminal status of a scheduled run back to `schedule_runs`.

  `:interrupted` is not terminal. A scheduled run should already have been
  turned into `:halted` before it could wait for a person.

  A failed write is logged and dropped. This process stays up: it is a
  permanent child, and a bookkeeping error must not stop the application.
  """

  use GenServer

  require Logger

  alias Handbean.PubSub.AgentEvent
  alias Handbean.Schedule.Store

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(Handbean.PubSub, "runtime:runs")
    {:ok, %{}}
  end

  @impl true
  def handle_info({:run_lifecycle, _conversation_id, :run_end, payload}, state) do
    status = payload_value(payload, :status)
    run_id = payload_value(payload, :run_id)

    cond do
      not is_binary(run_id) or run_id == "" ->
        :ok

      status in [:interrupted, "interrupted", :awaiting_approval, "awaiting_approval"] ->
        :ok

      AgentEvent.terminal_status?(status) ->
        finish_scheduled_run(run_id, status, payload)

      true ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # A run_end is broadcast for every conversation. Only a scheduled run has a
  # matching schedule_runs row, and that table may not exist yet on a fresh
  # install. A missing row is not a failed finish.
  #
  # The checkout can also exit. In tests the SQL sandbox lends this process the
  # caller's connection, and that owner can die mid-query. In production a
  # locked database raises. Either one used to kill this permanent child, and
  # three deaths inside the supervisor window stopped the whole application.
  defp finish_scheduled_run(run_id, status, payload) do
    Store.finish_by_run_id(run_id, map_status(status), reason(payload, status))
  catch
    :error, %Exqlite.Error{} = error ->
      unless missing_schedule_runs?(error), do: log_finish_failure(:error, error)

    kind, reason ->
      log_finish_failure(kind, reason)
  end

  defp log_finish_failure(kind, reason) do
    Logger.warning(
      "[Schedule.Recorder] could not record run finish: " <>
        Exception.format_banner(kind, reason)
    )
  end

  defp missing_schedule_runs?(%{message: message}) when is_binary(message) do
    String.contains?(message, "no such table: schedule_runs")
  end

  defp missing_schedule_runs?(_error), do: false

  defp map_status(status) when status in [:completed, "completed"], do: "completed"
  defp map_status(status) when status in [:cancelled, "cancelled"], do: "cancelled"
  defp map_status(status) when status in [:stalled, "stalled"], do: "stalled"
  defp map_status(status) when status in [:halted, "halted"], do: "halted"
  defp map_status(_status), do: "failed"

  defp reason(payload, status) do
    case payload_value(payload, :error) do
      value when is_binary(value) and value != "" -> value
      _ -> to_string(status)
    end
  end

  defp payload_value(payload, key) when is_map(payload) do
    Map.get(payload, key) || Map.get(payload, Atom.to_string(key))
  end

  defp payload_value(_payload, _key), do: nil
end
