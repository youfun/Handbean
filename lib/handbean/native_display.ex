defmodule Handbean.NativeDisplay do
  @moduledoc """
  Bridgeless native overlay boundary.

  The host installs a 2-arity runner via `:handbean, :native_display`.
  This is not `Mob.UI.webview` and must not inject `window.mob`.
  """

  @spec command(term(), keyword()) :: :ok | {:ok, term()} | {:error, term()}
  def command(cmd, opts \\ []) do
    case Application.get_env(:handbean, :native_display) do
      fun when is_function(fun, 2) -> fun.(cmd, opts)
      _ -> {:error, :not_configured}
    end
  end
end
