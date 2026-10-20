defmodule Handbean.Browser.ChromeRelay.Socket do
  @moduledoc false

  @behaviour WebSock

  alias Handbean.Browser.ChromeRelay.Server

  @impl true
  def init(%{role: role, credential: credential} = state) do
    case Server.register(role, self(), credential) do
      {:ok, id} -> {:ok, state |> Map.delete(:credential) |> Map.put(:id, id)}
      {:error, reason} -> {:stop, reason, 1013, Map.delete(state, :credential)}
    end
  end

  @impl true
  def handle_in({payload, opcode: :text}, state) do
    case Server.route(state.role, state.id, payload) do
      :ok -> {:ok, state}
      {:error, :message_too_large} -> {:stop, :message_too_large, 1009, state}
      {:error, reason} -> {:stop, reason, 1008, state}
    end
  end

  def handle_in({_payload, opcode: :binary}, state) do
    {:stop, :binary_frames_unsupported, 1003, state}
  end

  @impl true
  def handle_info({:relay_text, payload}, state), do: {:push, {:text, payload}, state}

  def handle_info({:relay_close, code, reason}, state) do
    {:stop, :normal, {code, reason}, state}
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, %{role: role, id: id}) do
    Server.unregister(role, id)
    :ok
  end

  def terminate(_reason, _state), do: :ok
end
