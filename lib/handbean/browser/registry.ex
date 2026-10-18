defmodule Handbean.Browser.Registry do
  @moduledoc """
  Per-conversation browser session registry.

  Maps `{conversation_id, slot}` → session PID. The default slot is
  `"default"`. Two conversations never share a session pid.
  """

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec register(String.t(), String.t(), pid()) :: :ok | {:error, :already_exists}
  def register(conversation_id, slot, pid)
      when is_binary(conversation_id) and is_binary(slot) and is_pid(pid) do
    GenServer.call(__MODULE__, {:register, conversation_id, slot, pid})
  end

  @spec unregister(String.t(), String.t()) :: :ok
  def unregister(conversation_id, slot)
      when is_binary(conversation_id) and is_binary(slot) do
    GenServer.call(__MODULE__, {:unregister, conversation_id, slot})
  end

  @spec lookup(String.t(), String.t()) :: {:ok, pid()} | {:error, :not_found}
  def lookup(conversation_id, slot)
      when is_binary(conversation_id) and is_binary(slot) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:lookup, conversation_id, slot})
    else
      {:error, :not_found}
    end
  end

  @spec list(String.t()) :: [%{slot: String.t(), pid: pid()}]
  def list(conversation_id) when is_binary(conversation_id) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:list, conversation_id})
    else
      []
    end
  end

  @impl true
  def init(_opts) do
    {:ok, %{sessions: %{}}}
  end

  @impl true
  def handle_call({:register, conversation_id, slot, pid}, _from, state) do
    key = {conversation_id, slot}

    if Map.has_key?(state.sessions, key) do
      {:reply, {:error, :already_exists}, state}
    else
      Process.monitor(pid)
      {:reply, :ok, %{state | sessions: Map.put(state.sessions, key, pid)}}
    end
  end

  def handle_call({:unregister, conversation_id, slot}, _from, state) do
    {:reply, :ok, %{state | sessions: Map.delete(state.sessions, {conversation_id, slot})}}
  end

  def handle_call({:lookup, conversation_id, slot}, _from, state) do
    case Map.fetch(state.sessions, {conversation_id, slot}) do
      {:ok, pid} -> {:reply, {:ok, pid}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:list, conversation_id}, _from, state) do
    results =
      state.sessions
      |> Enum.filter(fn {{id, _slot}, _pid} -> id == conversation_id end)
      |> Enum.map(fn {{_id, slot}, pid} -> %{slot: slot, pid: pid} end)

    {:reply, results, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    sessions =
      state.sessions
      |> Enum.reject(fn {_key, p} -> p == pid end)
      |> Map.new()

    {:noreply, %{state | sessions: sessions}}
  end
end
