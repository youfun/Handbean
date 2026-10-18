defmodule Handbean.Media.Backend do
  @moduledoc """
  Storage contract for immutable conversation media objects.

  Backends receive an already verified bounded binary. A storage key is an
  opaque, platform-independent logical key, not an operating-system path.
  """

  @type storage_key :: String.t()
  @type metadata :: map()
  @type delivery :: {:send_file, String.t()} | {:redirect, String.t()}

  @callback put(storage_key(), binary(), metadata()) :: :ok | {:error, term()}
  @callback delivery(storage_key(), metadata()) :: {:ok, delivery()} | {:error, term()}
  @callback delete(storage_key(), metadata()) :: :ok | {:error, term()}
end
