defmodule Handbean.Browser.Display do
  @moduledoc """
  Foreground projection for browser and preview native instances.

  One foreground slot. Switching display does not destroy a hidden
  browser session. A takeover request from another conversation is
  notified, never stolen.
  """

  use GenServer

  @name __MODULE__

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @spec show(atom(), String.t(), map()) :: :ok | {:error, term()}
  def show(kind, id, meta) when kind in [:browser, :preview] and is_binary(id) do
    if Process.whereis(@name) do
      GenServer.call(@name, {:show, kind, id, meta})
    else
      :ok
    end
  end

  @spec hide(atom(), String.t()) :: :ok
  def hide(kind, id) when kind in [:browser, :preview] and is_binary(id) do
    if Process.whereis(@name) do
      GenServer.call(@name, {:hide, kind, id})
    else
      :ok
    end
  end

  @spec current() :: map() | nil
  def current do
    if Process.whereis(@name) do
      GenServer.call(@name, :current)
    else
      nil
    end
  end

  @spec reset!() :: :ok
  def reset! do
    if Process.whereis(@name) do
      GenServer.call(@name, :reset)
    else
      :ok
    end
  end

  @impl true
  def init(_opts) do
    {:ok, %{current: nil, hidden: %{}}}
  end

  @impl true
  def handle_call({:show, kind, id, meta}, _from, state) do
    takeover? = user_control?(meta)
    current_conv = conversation_id(state.current)
    incoming_conv = conversation_id(meta)

    steal? =
      takeover? and is_binary(current_conv) and is_binary(incoming_conv) and
        current_conv != incoming_conv and user_control?(state.current)

    cond do
      steal? ->
        {:reply, {:error, :other_conversation_takeover}, state}

      true ->
        {hidden, previous} = park_current(state)
        slot = %{kind: kind, id: id, meta: meta, visible: true}
        hidden = Map.delete(hidden, {kind, id})
        notify({:shown, slot, previous})
        {:reply, :ok, %{state | current: slot, hidden: hidden}}
    end
  end

  def handle_call({:hide, kind, id}, _from, state) do
    cond do
      match?(%{kind: ^kind, id: ^id}, state.current) ->
        parked = %{state.current | visible: false}
        notify({:hidden, parked})
        {:reply, :ok, %{state | current: nil, hidden: Map.put(state.hidden, {kind, id}, parked)}}

      Map.has_key?(state.hidden, {kind, id}) ->
        {:reply, :ok, state}

      true ->
        {:reply, :ok, state}
    end
  end

  def handle_call(:current, _from, state) do
    {:reply, state.current, state}
  end

  def handle_call(:reset, _from, _state) do
    {:reply, :ok, %{current: nil, hidden: %{}}}
  end

  defp park_current(%{current: nil, hidden: hidden}), do: {hidden, nil}

  defp park_current(%{current: current, hidden: hidden}) do
    parked = %{current | visible: false}
    {Map.put(hidden, {current.kind, current.id}, parked), parked}
  end

  defp conversation_id(nil), do: nil
  defp conversation_id(%{meta: meta}), do: conversation_id(meta)

  defp conversation_id(meta) when is_map(meta),
    do: Handbean.Utils.SafeMap.get_any(meta, :conversation_id, "conversation_id")

  defp conversation_id(_), do: nil

  defp user_control?(nil), do: false
  defp user_control?(%{meta: meta}), do: user_control?(meta)

  defp user_control?(meta) when is_map(meta) do
    meta[:control] in [:user, "user"] or meta["control"] in [:user, "user"]
  end

  defp user_control?(_), do: false

  defp notify(event) do
    if Process.whereis(Handbean.PubSub) do
      Phoenix.PubSub.broadcast(Handbean.PubSub, "native_display", event)
    end

    :ok
  end
end
