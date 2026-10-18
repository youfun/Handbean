defmodule Handbean.Search.Backend do
  @moduledoc """
  Workspace file-search backend contract.

  The backend owns workspace inventory startup and path ranking. Content search
  and semantic code search may consume the same inventory without sharing their
  query semantics.
  """

  @type index :: term()
  @type result :: %{
          required(:paths) => [map()],
          required(:query) => String.t(),
          required(:duration_ms) => non_neg_integer(),
          required(:status) => :indexing | :ready
        }

  @callback ensure_started(workspace :: String.t()) :: {:ok, index()} | {:error, term()}
  @callback await(index(), timeout()) :: :ok | {:error, term()}
  @callback search(index(), query :: String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  @callback files(index(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback touch(index(), path :: String.t()) :: :ok
  @callback update_paths(index(), paths :: [String.t()]) :: :ok
  @callback set_git_status(index(), [{String.t(), atom()}]) :: :ok
  @callback ignored_path?(workspace :: String.t(), path :: String.t()) :: boolean()
  @callback refresh(index()) :: :ok
end
