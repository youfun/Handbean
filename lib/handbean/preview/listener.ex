defmodule Handbean.Preview.Listener do
  @moduledoc """
  Tracks loopback preview listeners.

  Display hide does not stop a listener. Closing a preview record does.
  This process is not a sandbox for arbitrary workspace code.
  """

  use GenServer

  @name __MODULE__

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @spec register(String.t(), map()) :: :ok
  def register(preview_id, info) when is_binary(preview_id) and is_map(info) do
    GenServer.call(@name, {:register, preview_id, info})
  end

  @spec lookup(String.t()) :: {:ok, map()} | {:error, :not_found}
  def lookup(preview_id) when is_binary(preview_id) do
    GenServer.call(@name, {:lookup, preview_id})
  end

  @spec stop(String.t()) :: :ok
  def stop(preview_id) when is_binary(preview_id) do
    if Process.whereis(@name) do
      GenServer.call(@name, {:stop, preview_id})
    else
      :ok
    end
  end

  @impl true
  def init(_opts) do
    {:ok, %{listeners: %{}}}
  end

  @impl true
  def handle_call({:register, preview_id, info}, _from, state) do
    info = Map.put(info, :preview_id, preview_id)

    if pid = info[:pid] do
      Process.monitor(pid)
    end

    {:reply, :ok, put_in(state.listeners[preview_id], info)}
  end

  def handle_call({:lookup, preview_id}, _from, state) do
    case Map.fetch(state.listeners, preview_id) do
      {:ok, info} -> {:reply, {:ok, info}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:stop, preview_id}, _from, state) do
    listeners = Map.get(state, :listeners, %{})

    case Map.pop(listeners, preview_id) do
      {nil, listeners} ->
        {:reply, :ok, Map.put(state, :listeners, listeners)}

      {info, listeners} ->
        stop_owned(info)
        {:reply, :ok, Map.put(state, :listeners, listeners)}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    listeners =
      state.listeners
      |> Enum.reject(fn {_id, info} -> info[:pid] == pid end)
      |> Map.new()

    {:noreply, %{state | listeners: listeners}}
  end

  defp stop_owned(%{pid: pid, owned?: true}) when is_pid(pid) do
    Process.exit(pid, :shutdown)
    :ok
  end

  defp stop_owned(_info), do: :ok
end
