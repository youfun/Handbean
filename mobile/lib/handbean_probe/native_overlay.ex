defmodule HandbeanProbe.NativeOverlay do
  @moduledoc """
  Bridgeless native overlay commands.

  Does not create Mob.UI.webview instances and does not write MobBridge.webView.
  """

  @spec command(map(), keyword()) :: :ok | {:ok, term()} | {:error, term()}
  def command(cmd, opts \\ []) when is_map(cmd) do
    case Application.get_env(:handbean_probe, :native_overlay_fake) do
      fun when is_function(fun, 2) -> fun.(cmd, opts)
      _ -> nif_command(cmd, opts)
    end
  end

  defp nif_command(cmd, _opts) do
    HandbeanProbe.Browser.Nif.command(Map.put(cmd, :overlay, true), [])
  end
end
