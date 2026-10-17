defmodule Handbean.Terminal do
  @moduledoc false

  @doc """
  True when the host declared a terminal and this build can load Ghostty.

  Ghostty publishes NIFs for Linux and macOS only. A Windows package still
  boots the Web UI; it just does not offer the in-browser terminal.
  """
  @spec available?() :: boolean()
  def available? do
    Handbean.Host.terminal?() and Code.ensure_loaded?(Ghostty.PTY)
  end
end
