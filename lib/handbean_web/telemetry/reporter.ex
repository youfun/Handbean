defmodule HandbeanWeb.Telemetry.Reporter do
  @moduledoc """
  In-process metric aggregates for host diagnostics via `snapshot/0`.

  Stores one count, total and last value per declared metric, without tags,
  query text or request metadata. Storage is bounded by the metric definitions.
  """

  use GenServer

  def start_link(metrics), do: GenServer.start_link(__MODULE__, metrics, name: __MODULE__)

  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @impl true
  def init(metrics) do
    Process.flag(:trap_exit, true)
    id = __MODULE__
    # Also discard a handler left behind by an untrappable process exit.
    :telemetry.detach(id)
    events = metrics |> Enum.map(& &1.event_name) |> Enum.uniq()
    :ok = :telemetry.attach_many(id, events, &__MODULE__.handle_event/4, {self(), metrics})
    {:ok, %{handler_id: id, metrics: %{}}}
  end

  @doc false
  def handle_event(event, measurements, metadata, {pid, metrics}) do
    values =
      for metric <- metrics,
          metric.event_name == event,
          value = measurement(metric.measurement, measurements, metadata),
          is_number(value),
          do: {metric.name, value}

    GenServer.cast(pid, {:measurements, values})
  end

  @impl true
  def handle_cast({:measurements, values}, state) do
    metrics =
      Enum.reduce(values, state.metrics, fn {name, value}, acc ->
        Map.update(acc, name, %{count: 1, total: value, last: value}, fn previous ->
          %{count: previous.count + 1, total: previous.total + value, last: value}
        end)
      end)

    {:noreply, %{state | metrics: metrics}}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state.metrics, state}

  @impl true
  def terminate(_reason, state), do: :telemetry.detach(state.handler_id)

  defp measurement(fun, measurements, metadata) when is_function(fun, 2),
    do: fun.(measurements, metadata)

  defp measurement(fun, measurements, _metadata) when is_function(fun, 1),
    do: fun.(measurements)

  defp measurement(key, measurements, _metadata), do: Map.get(measurements, key)
end
