defmodule Handbean.Agent.Provider.Cursor.FlowControl do
  @moduledoc """
  HTTP/2 send-window queue.

  Chunks outbound bytes to the current connection/request window and
  holds the remainder until a WINDOW_UPDATE arrives. Cancel drops the
  queue instead of sending it later.
  """

  defstruct queue: <<>>, eof?: false

  @type t :: %__MODULE__{queue: binary(), eof?: boolean()}

  def new, do: %__MODULE__{}

  def enqueue(%__MODULE__{} = state, data, eof? \\ false) when is_binary(data) do
    %{state | queue: state.queue <> data, eof?: state.eof? or eof?}
  end

  def empty?(%__MODULE__{queue: <<>>, eof?: false}), do: true
  def empty?(%__MODULE__{}), do: false

  def take(%__MODULE__{} = state, window) when is_integer(window) and window <= 0 do
    {[], state}
  end

  def take(%__MODULE__{queue: <<>>} = state, _window) do
    {eof_ops(state), %{state | eof?: false}}
  end

  def take(%__MODULE__{} = state, window) when is_integer(window) and window > 0 do
    size = min(byte_size(state.queue), window)
    chunk = binary_part(state.queue, 0, size)
    rest = binary_part(state.queue, size, byte_size(state.queue) - size)
    state = %{state | queue: rest}

    if rest == <<>> do
      {[{:data, chunk} | eof_ops(state)], %{state | eof?: false}}
    else
      {[{:data, chunk}], state}
    end
  end

  def cancel(_state), do: new()

  defp eof_ops(%__MODULE__{queue: <<>>, eof?: true}), do: [:eof]
  defp eof_ops(_), do: []
end
