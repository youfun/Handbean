defmodule Handbean.Browser.ChromeRelay.Server do
  @moduledoc """
  Owns the local Chrome-extension/CDP relay lifecycle.

  WebSocket processes register here and exchange bounded JSON messages. The
  server never interprets page content and never logs CDP payloads.
  """

  use GenServer

  alias Handbean.Browser.Chrome

  @name __MODULE__
  @heartbeat_interval_ms 20_000

  defstruct extension: nil,
            extension_ref: nil,
            clients: %{},
            refs: %{},
            tabs: 0,
            extension_version: nil,
            cdp_token: nil

  @type role :: :extension | :cdp

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  @spec register(role(), pid(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def register(role, pid, credential)
      when role in [:extension, :cdp] and is_pid(pid) and is_binary(credential) do
    GenServer.call(@name, {:register, role, pid, credential})
  end

  @spec unregister(role(), String.t()) :: :ok
  def unregister(role, id) when role in [:extension, :cdp] and is_binary(id) do
    GenServer.cast(@name, {:unregister, role, id})
  end

  @spec route(role(), String.t(), binary()) :: :ok | {:error, term()}
  def route(role, id, payload)
      when role in [:extension, :cdp] and is_binary(id) and is_binary(payload) do
    GenServer.call(@name, {:route, role, id, payload})
  end

  @spec status() :: map()
  def status do
    if Process.whereis(@name) do
      GenServer.call(@name, :status)
    else
      %{listener_port: nil, extension_connected: false, tabs: 0, client_count: 0}
    end
  end

  @spec extension_connected?() :: boolean()
  def extension_connected?, do: status().extension_connected

  @spec cdp_url() :: String.t() | nil
  def cdp_url do
    case {listener_port(), GenServer.call(@name, :cdp_token)} do
      {port, token} when is_integer(port) and is_binary(token) ->
        "ws://127.0.0.1:#{port}/cdp/#{token}"

      _ ->
        nil
    end
  end

  @spec authorize_cdp(String.t()) :: boolean()
  def authorize_cdp(token) when is_binary(token) do
    case GenServer.call(@name, :cdp_token) do
      expected when is_binary(expected) and byte_size(expected) == byte_size(token) ->
        Plug.Crypto.secure_compare(expected, token)

      _ ->
        false
    end
  end

  def authorize_cdp(_token), do: false

  @spec stop_all() :: :ok
  def stop_all do
    if Process.whereis(@name), do: GenServer.call(@name, :stop_all), else: :ok
  end

  @impl true
  def init(_opts) do
    schedule_heartbeat()
    {:ok, %__MODULE__{cdp_token: random_id(32)}}
  end

  @impl true
  def handle_call({:register, :extension, pid, credential}, _from, state) do
    if Chrome.authorize_extension(credential) do
      state = disconnect_existing_extension(state)
      id = random_id(12)
      ref = Process.monitor(pid)
      state = %{state | extension: {id, pid}, extension_ref: ref, tabs: 0}
      broadcast_status(state)
      {:reply, {:ok, id}, state}
    else
      {:reply, {:error, :unauthorized}, state}
    end
  end

  def handle_call({:register, :cdp, pid, credential}, _from, state) do
    cond do
      not secure_compare(state.cdp_token, credential) ->
        {:reply, {:error, :unauthorized}, state}

      is_nil(state.extension) ->
        {:reply, {:error, :extension_not_connected}, state}

      true ->
        id = random_id(12)
        ref = Process.monitor(pid)

        state = %{
          state
          | clients: Map.put(state.clients, id, pid),
            refs: Map.put(state.refs, ref, {:cdp, id})
        }

        broadcast_status(state)
        {:reply, {:ok, id}, state}
    end
  end

  def handle_call({:route, :cdp, id, payload}, _from, state) do
    with {:ok, message} <- decode_object(payload),
         true <- Map.has_key?(state.clients, id) || {:error, :unknown_client},
         {_extension_id, extension_pid} <- state.extension || {:error, :extension_not_connected} do
      envelope = Handbean.JSON.encode!(%{"type" => "cdp", "clientId" => id, "message" => message})
      send(extension_pid, {:relay_text, envelope})
      {:reply, :ok, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:route, :extension, id, payload}, _from, state) do
    with {^id, _pid} <- state.extension || {:error, :unknown_extension},
         {:ok, message} <- decode_object(payload) do
      {reply, state} = handle_extension_message(message, state)
      {:reply, reply, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      _ -> {:reply, {:error, :unknown_extension}, state}
    end
  end

  def handle_call(:status, _from, state) do
    {:reply, status_map(state), state}
  end

  def handle_call(:cdp_token, _from, state), do: {:reply, state.cdp_token, state}

  def handle_call(:stop_all, _from, state) do
    close_all(state, "Chrome control disabled")

    state = %{
      state
      | extension: nil,
        extension_ref: nil,
        clients: %{},
        refs: %{},
        tabs: 0,
        extension_version: nil,
        cdp_token: random_id(32)
    }

    broadcast_status(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:unregister, :extension, id}, %{extension: {id, _pid}} = state) do
    close_clients(state, "Chrome extension disconnected")

    state = %{
      state
      | extension: nil,
        extension_ref: nil,
        clients: %{},
        refs: %{},
        tabs: 0,
        extension_version: nil
    }

    broadcast_status(state)
    {:noreply, state}
  end

  def handle_cast({:unregister, :cdp, id}, state) do
    state = drop_client(state, id)
    broadcast_status(state)
    {:noreply, state}
  end

  def handle_cast(_message, state), do: {:noreply, state}

  @impl true
  def handle_info(:heartbeat, state) do
    if state.extension do
      {_id, pid} = state.extension
      send(pid, {:relay_text, Handbean.JSON.encode!(%{"type" => "ping"})})
    end

    schedule_heartbeat()
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{extension_ref: ref} = state) do
    close_clients(state, "Chrome extension disconnected")

    state = %{
      state
      | extension: nil,
        extension_ref: nil,
        clients: %{},
        refs: %{},
        tabs: 0,
        extension_version: nil
    }

    broadcast_status(state)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.refs, ref) do
      {{:cdp, id}, refs} ->
        notify_client_disconnected(state, id)
        state = %{state | clients: Map.delete(state.clients, id), refs: refs}
        broadcast_status(state)
        {:noreply, state}

      {nil, _refs} ->
        {:noreply, state}
    end
  end

  defp handle_extension_message(%{"type" => "pong"}, state), do: {:ok, state}

  defp handle_extension_message(%{"type" => "hello"} = message, state) do
    version = Map.get(message, "version")
    state = %{state | extension_version: version}
    broadcast_status(state)
    {:ok, state}
  end

  defp handle_extension_message(%{"type" => "status", "tabs" => tabs}, state)
       when is_integer(tabs) and tabs >= 0 do
    state = %{state | tabs: tabs}
    broadcast_status(state)
    {:ok, state}
  end

  defp handle_extension_message(
         %{"type" => "cdp", "clientId" => client_id, "message" => message},
         state
       )
       when is_binary(client_id) and is_map(message) do
    case Map.fetch(state.clients, client_id) do
      {:ok, pid} ->
        send(pid, {:relay_text, Handbean.JSON.encode!(message)})
        {:ok, state}

      :error ->
        {:ok, state}
    end
  end

  defp handle_extension_message(_message, state), do: {{:error, :invalid_message}, state}

  defp decode_object(payload) when byte_size(payload) <= 1_048_576 do
    case Handbean.JSON.decode(payload) do
      {:ok, value} when is_map(value) -> {:ok, value}
      _ -> {:error, :invalid_json}
    end
  end

  defp decode_object(_payload), do: {:error, :message_too_large}

  defp disconnect_existing_extension(%{extension: {_id, pid}} = state) do
    send(pid, {:relay_close, 4001, "Replaced by a newer extension connection"})
    close_clients(state, "Chrome extension reconnected")

    Enum.each(Map.keys(state.refs), &Process.demonitor(&1, [:flush]))
    if state.extension_ref, do: Process.demonitor(state.extension_ref, [:flush])
    %{state | extension: nil, extension_ref: nil, clients: %{}, refs: %{}}
  end

  defp disconnect_existing_extension(state), do: state

  defp drop_client(state, id) do
    notify_client_disconnected(state, id)

    {removed_refs, kept_refs} =
      Enum.split_with(state.refs, fn {_ref, value} -> value == {:cdp, id} end)

    Enum.each(removed_refs, fn {ref, _value} -> Process.demonitor(ref, [:flush]) end)
    %{state | clients: Map.delete(state.clients, id), refs: Map.new(kept_refs)}
  end

  defp notify_client_disconnected(%{extension: {_extension_id, pid}, clients: clients}, id) do
    if Map.has_key?(clients, id) do
      send(
        pid,
        {:relay_text,
         Handbean.JSON.encode!(%{"type" => "client_disconnected", "clientId" => id})}
      )
    end
  end

  defp notify_client_disconnected(_state, _id), do: :ok

  defp close_all(state, reason) do
    if state.extension do
      {_id, pid} = state.extension
      send(pid, {:relay_text, Handbean.JSON.encode!(%{"type" => "stop"})})
      send(pid, {:relay_close, 1000, reason})
    end

    close_clients(state, reason)
    Enum.each(Map.keys(state.refs), &Process.demonitor(&1, [:flush]))
    if state.extension_ref, do: Process.demonitor(state.extension_ref, [:flush])
  end

  defp close_clients(state, reason) do
    Enum.each(state.clients, fn {_id, pid} -> send(pid, {:relay_close, 1012, reason}) end)
  end

  defp status_map(state) do
    %{
      listener_port: listener_port(),
      extension_connected: state.extension != nil,
      extension_version: state.extension_version,
      tabs: state.tabs,
      client_count: map_size(state.clients)
    }
  end

  defp listener_port do
    case Process.whereis(Handbean.Browser.ChromeRelay.Listener) do
      pid when is_pid(pid) ->
        case ThousandIsland.listener_info(pid) do
          {:ok, {_address, port}} -> port
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp broadcast_status(state) do
    Chrome.broadcast({:chrome_browser_status, status_map(state)})
  end

  defp schedule_heartbeat do
    Process.send_after(self(), :heartbeat, @heartbeat_interval_ms)
  end

  defp secure_compare(expected, provided)
       when is_binary(expected) and is_binary(provided) and
              byte_size(expected) == byte_size(provided),
       do: Plug.Crypto.secure_compare(expected, provided)

  defp secure_compare(_expected, _provided), do: false

  defp random_id(bytes), do: :crypto.strong_rand_bytes(bytes) |> Base.url_encode64(padding: false)
end
