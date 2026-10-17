defmodule Handbean.Terminal.Registry do
  @moduledoc """
  Registry for terminal sessions scoped by workspace and checkout.

  The primary key is `{workspace_id, checkout_key, terminal_name}`.
  """

  use GenServer

  @legacy_checkout "legacy"

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def register(workspace_id, name, pid),
    do: register(workspace_id, @legacy_checkout, name, pid)

  def register(workspace_id, checkout_key, name, pid)
      when is_binary(workspace_id) and is_binary(checkout_key) and is_binary(name) and is_pid(pid) do
    GenServer.call(__MODULE__, {:register, workspace_id, checkout_key, name, pid})
  end

  def unregister(workspace_id, name),
    do: unregister(workspace_id, @legacy_checkout, name)

  def unregister(workspace_id, checkout_key, name)
      when is_binary(workspace_id) and is_binary(checkout_key) and is_binary(name) do
    GenServer.call(__MODULE__, {:unregister, workspace_id, checkout_key, name})
  end

  def lookup(workspace_id, name),
    do: lookup(workspace_id, @legacy_checkout, name)

  def lookup(workspace_id, checkout_key, name)
      when is_binary(workspace_id) and is_binary(checkout_key) and is_binary(name) do
    GenServer.call(__MODULE__, {:lookup, workspace_id, checkout_key, name})
  end

  def list(workspace_id) when is_binary(workspace_id) do
    GenServer.call(__MODULE__, {:list_workspace, workspace_id})
  end

  def list(workspace_id, checkout_key)
      when is_binary(workspace_id) and is_binary(checkout_key) do
    GenServer.call(__MODULE__, {:list, workspace_id, checkout_key})
  end

  def remove_workspace(workspace_id) when is_binary(workspace_id) do
    GenServer.call(__MODULE__, {:remove_workspace, workspace_id})
  end

  @impl true
  def init(_opts), do: {:ok, %{sessions: %{}}}

  @impl true
  def handle_call({:register, ws_id, checkout_key, name, pid}, _from, state) do
    key = {ws_id, checkout_key, name}

    if Map.has_key?(state.sessions, key) do
      {:reply, {:error, :already_exists}, state}
    else
      Process.monitor(pid)
      {:reply, :ok, %{state | sessions: Map.put(state.sessions, key, pid)}}
    end
  end

  def handle_call({:unregister, ws_id, checkout_key, name}, _from, state) do
    key = {ws_id, checkout_key, name}
    {:reply, :ok, %{state | sessions: Map.delete(state.sessions, key)}}
  end

  def handle_call({:lookup, ws_id, checkout_key, name}, _from, state) do
    case Map.fetch(state.sessions, {ws_id, checkout_key, name}) do
      {:ok, pid} -> {:reply, {:ok, pid}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:list, ws_id, checkout_key}, _from, state) do
    results =
      state.sessions
      |> Enum.filter(fn {{workspace, checkout, _name}, _pid} ->
        workspace == ws_id and checkout == checkout_key
      end)
      |> Enum.map(fn {{_workspace, _checkout, name}, pid} -> %{name: name, pid: pid} end)

    {:reply, results, state}
  end

  def handle_call({:list_workspace, ws_id}, _from, state) do
    results =
      state.sessions
      |> Enum.filter(fn {{workspace, _checkout, _name}, _pid} -> workspace == ws_id end)
      |> Enum.map(fn {{_workspace, checkout_key, name}, pid} ->
        %{checkout_key: checkout_key, name: name, pid: pid}
      end)

    {:reply, results, state}
  end

  def handle_call({:remove_workspace, ws_id}, _from, state) do
    sessions =
      state.sessions
      |> Enum.reject(fn {{workspace, _checkout, _name}, _pid} -> workspace == ws_id end)
      |> Map.new()

    {:reply, :ok, %{state | sessions: sessions}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    sessions = state.sessions |> Enum.reject(fn {_key, value} -> value == pid end) |> Map.new()
    {:noreply, %{state | sessions: sessions}}
  end
end
