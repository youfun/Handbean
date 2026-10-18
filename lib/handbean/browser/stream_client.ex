defmodule Handbean.Browser.StreamClient do
  @moduledoc """
  WebSocket client for one `agent-browser` session preview.

  Connects only to `127.0.0.1`. Frames are forwarded to the user surface.
  The browser page never sees this socket.
  """

  use WebSockex

  @spec start_link(pos_integer(), pid()) :: {:ok, pid()} | {:error, term()}
  def start_link(port, parent)
      when is_integer(port) and port > 0 and port < 65_536 and is_pid(parent) do
    WebSockex.start_link("ws://127.0.0.1:#{port}/", __MODULE__, %{parent: parent})
  end

  @spec send_text(pid(), String.t()) :: :ok | {:error, term()}
  def send_text(pid, text) when is_pid(pid) and is_binary(text) do
    WebSockex.send_frame(pid, {:text, text})
  end

  @impl true
  def handle_frame({:text, msg}, %{parent: parent} = state) do
    send(parent, {:browser_stream_frame, IO.iodata_to_binary(msg)})
    {:ok, state}
  end

  def handle_frame(_frame, state), do: {:ok, state}

  @impl true
  def handle_disconnect(_status, state), do: {:ok, state}
end
