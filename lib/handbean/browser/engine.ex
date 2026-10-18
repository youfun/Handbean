defmodule Handbean.Browser.Engine do
  @moduledoc """
  Host-installed runner for the independent WebView engine.

  Host tests inject a fake engine. The Android NIF is never loaded here.
  Every call carries session_id, request_id, and generation.
  """

  @spec command(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def command(cmd, opts \\ []) when is_map(cmd) do
    case Application.get_env(:handbean, :browser_engine) do
      fun when is_function(fun, 2) -> fun.(cmd, opts)
      _ -> {:error, :engine_not_configured}
    end
  end
end
