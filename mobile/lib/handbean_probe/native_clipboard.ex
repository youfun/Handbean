defmodule HandbeanProbe.NativeClipboard do
  @moduledoc false

  alias Mob.Clipboard

  @doc "Copy text through the native clipboard, with a host-test replacement."
  def put(socket, text) when is_binary(text) do
    case Application.get_env(:handbean_probe, :clipboard_put) do
      fun when is_function(fun, 1) ->
        fun.(text)
        socket

      _ ->
        Clipboard.put(socket, text)
    end
  end
end
