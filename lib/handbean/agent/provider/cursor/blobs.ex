defmodule Handbean.Agent.Provider.Cursor.Blobs do
  @moduledoc """
  SHA-256 content-addressed blob store for Cursor conversation state.

  Blob IDs on the wire are the raw 32-byte digest. Local maps are keyed by hex.
  """

  def new, do: %{}

  def put(store, data) when is_binary(data) do
    id = :crypto.hash(:sha256, data)
    {id, Map.put(store, Base.encode16(id, case: :lower), data)}
  end

  def put_id(store, id, data) when is_binary(id) and is_binary(data) do
    Map.put(store, hex(id), data)
  end

  def fetch(store, id) when is_binary(id) do
    Map.get(store, hex(id))
  end

  def hex(id) when is_binary(id) do
    if byte_size(id) == 32 do
      Base.encode16(id, case: :lower)
    else
      String.downcase(id)
    end
  end

  def merge(store, other) when is_map(other), do: Map.merge(store, other)
end
