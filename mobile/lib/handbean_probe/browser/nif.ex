defmodule HandbeanProbe.Browser.Nif do
  @moduledoc """
  Bridgeless browser NIF boundary.

  Host loads the safe Erlang stub. Device runtime uses the static NIF.
  """

  @spec ensure_loaded() :: :ok | {:error, term()}
  def ensure_loaded do
    case Code.ensure_loaded(:handbean_browser) do
      {:module, :handbean_browser} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec command(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def command(cmd, opts \\ []) do
    case Application.get_env(:handbean_probe, :browser_engine_fake) do
      fun when is_function(fun, 2) -> fun.(cmd, opts)
      _ -> device_command(cmd)
    end
  end

  # Every key `c_src/handbean_browser.c` reads with enif_get_map_value, plus the
  # `overlay` flag NativeOverlay adds. String keys outside this schema are
  # dropped instead of minted into atoms (the NIF would ignore them anyway).
  @wire_keys %{
    "op" => :op,
    "session_id" => :session_id,
    "id" => :id,
    "request_id" => :request_id,
    "owner" => :owner,
    "conversation_id" => :conversation_id,
    "url" => :url,
    "js" => :js,
    "control" => :control,
    "generation" => :generation,
    "caller" => :caller,
    "overlay" => :overlay
  }

  def wire_keys, do: Map.values(@wire_keys)

  defp device_command(cmd) do
    case Code.ensure_loaded(:handbean_browser) do
      {:module, :handbean_browser} -> :handbean_browser.command(wire_map(cmd))
      {:error, _reason} -> {:error, :nif_not_loaded}
    end
  end

  @doc """
  Exact map handed to the C NIF. Atom keys pass through; string keys are mapped
  through the fixed wire schema and unknown ones are dropped. Never calls
  `String.to_atom/1`.
  """
  @spec wire_map(map()) :: map()
  def wire_map(cmd) when is_map(cmd) do
    Enum.reduce(cmd, %{}, fn
      {k, v}, acc when is_atom(k) ->
        Map.put(acc, k, nif_value(v))

      {k, v}, acc when is_binary(k) ->
        case Map.fetch(@wire_keys, k) do
          {:ok, atom} -> Map.put_new(acc, atom, nif_value(v))
          :error -> acc
        end

      {_k, _v}, acc ->
        acc
    end)
  end

  defp nif_value(v) when is_pid(v), do: v
  defp nif_value(v) when is_atom(v), do: Atom.to_string(v)
  defp nif_value(v) when is_binary(v), do: v
  defp nif_value(v) when is_integer(v), do: v
  defp nif_value(v), do: to_string(v)
end
