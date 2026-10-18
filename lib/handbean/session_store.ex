defmodule Handbean.SessionStore do
  @moduledoc """
  Behaviour for runtime session snapshot persistence.

  Stores only recoverable runtime data. It must not store process ids, task refs,
  queue pids, ports, or provider connections.
  """

  @callback save(String.t(), map(), keyword()) :: :ok | {:error, term()}
  @callback load(String.t(), keyword()) :: {:ok, map()} | {:error, :not_found | term()}
  @callback delete(String.t(), keyword()) :: :ok | {:error, term()}
  @callback list_active(keyword()) :: {:ok, [String.t()]} | {:error, term()}
  @callback update(String.t(), map(), keyword()) :: :ok | {:error, term()}

  alias Handbean.Log.Redactor

  @runtime_keys [
    :pid,
    :agent_pid,
    :queue_pid,
    :task,
    :task_ref,
    :port,
    "pid",
    "agent_pid",
    "queue_pid",
    "task",
    "task_ref",
    "port"
  ]

  @doc false
  def prepare_snapshot(snapshot) do
    snapshot
    |> strip_runtime_handles()
    |> Redactor.redact()
  end

  defp strip_runtime_handles(map) when is_map(map) do
    map
    |> Map.drop(@runtime_keys)
    |> Map.new(fn {key, value} -> {key, strip_runtime_handles(value)} end)
  end

  defp strip_runtime_handles(list) when is_list(list),
    do: Enum.map(list, &strip_runtime_handles/1)

  defp strip_runtime_handles(value) when is_pid(value), do: nil
  defp strip_runtime_handles(value) when is_reference(value), do: nil
  defp strip_runtime_handles(value) when is_function(value), do: nil
  defp strip_runtime_handles(value), do: value
end
