defmodule Handbean.Agent.Auth.RefreshLock do
  @moduledoc """
  Serializes OAuth refresh per provider.

  `:global.trans/4` locks are `{resource, requester}`. Using the provider
  id as the requester lets every process re-enter the same lock. This
  module uses `self()` as the requester so concurrent callers wait.
  """

  @spec trans(String.t(), (-> result)) :: result | {:error, String.t()} when result: term()
  def trans(provider_id, fun) when is_binary(provider_id) and is_function(fun, 0) do
    id = {{:handbean_oauth_refresh, provider_id}, self()}

    case :global.trans(id, fun, [Node.self()], 30_000) do
      :aborted ->
        {:error, "OAuth token refresh is already in progress"}

      {:error, :aborted} ->
        {:error, "OAuth token refresh is already in progress"}

      result ->
        result
    end
  end
end
