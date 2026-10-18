defmodule Handbean.Media.BackendRegistry do
  @moduledoc """
  Fixed mapping from persisted backend identifiers to trusted modules.

  Persisted strings are only map keys. They are never converted to atoms or
  interpreted as module names.
  """

  alias Handbean.Media.Backends.Local

  @backends %{"local" => Local}

  @spec all() :: %{String.t() => module()}
  def all, do: @backends

  @spec default_id() :: String.t()
  def default_id, do: "local"

  @spec fetch(String.t(), map()) :: {:ok, module()} | {:error, :unknown_backend}
  def fetch(id, registry \\ @backends)

  def fetch(id, registry) when is_binary(id) and is_map(registry) do
    case Map.fetch(registry, id) do
      {:ok, backend} when is_atom(backend) -> {:ok, backend}
      _ -> {:error, :unknown_backend}
    end
  end

  def fetch(_id, _registry), do: {:error, :unknown_backend}
end
