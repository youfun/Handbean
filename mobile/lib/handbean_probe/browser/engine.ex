defmodule HandbeanProbe.Browser.Engine do
  @moduledoc """
  Host-installed WebView engine runner.

  Device uses the NIF. Host tests inject a fake engine and never load NIF.
  """

  @spec install!() :: :ok
  def install! do
    Application.delete_env(:handbean, :browser_webview)
    Application.put_env(:handbean, :browser_engine, &command/2)
    Application.put_env(:handbean, :native_display, &HandbeanProbe.NativeOverlay.command/2)
    _ = HandbeanProbe.Browser.Nif.ensure_loaded()
    :ok
  end

  def command(cmd, opts \\ []) when is_map(cmd) do
    HandbeanProbe.Browser.Nif.command(cmd, opts)
  end
end
