defmodule Handbean.Terminal do
  @moduledoc false

  @doc """
  True when the host declared a terminal and this build can load Ghostty.

  Desktop builds (Linux, macOS, and Windows) compile Ghostty NIFs; mobile
  builds omit the dependency and do not offer the in-browser terminal.
  """
  @spec available?() :: boolean()
  def available? do
    Handbean.Host.terminal?() and Code.ensure_loaded?(Ghostty.PTY)
  end
end
