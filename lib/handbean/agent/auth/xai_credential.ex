defmodule Handbean.Agent.Auth.XaiCredential do
  @moduledoc """
  Resolves an xAI transport API key from stored OAuth credentials.

  Near-expiry tokens are refreshed through the device-flow refresh grant.
  Refresh failure deletes the stored credential and asks the user to
  reconnect. It never falls back to an unrelated environment API key.
  """

  alias Handbean.Agent.Auth.{Storage, XaiOAuth}

  @reconnect_message "xAI subscription expired. Sign in with SuperGrok or X Premium to reconnect."
  @sign_in_message "Sign in with SuperGrok or X Premium to connect xAI."

  @spec resolve_transport_key(String.t(), keyword()) ::
          {:ok, %{api_key: String.t()}} | {:error, String.t()}
  def resolve_transport_key(provider_id, opts \\ []) when is_binary(provider_id) do
    with_refresh_lock(provider_id, fn ->
      do_resolve_transport_key(provider_id, opts)
    end)
  end

  @spec provider_preset() :: map()
  def provider_preset do
    %{
      "name" => "xAI",
      "provider" => "openai",
      "baseUrl" => "https://api.x.ai/v1",
      "api" => "openai-responses",
      "authType" => "oauth",
      "models" => []
    }
  end

  defp do_resolve_transport_key(provider_id, opts) do
    case Storage.get(provider_id, opts) do
      {:ok, credential} ->
        if expired?(credential, opts) do
          refresh_and_store(provider_id, credential, opts)
        else
          {:ok, XaiOAuth.to_auth(credential)}
        end

      {:error, :not_found} ->
        {:error, @sign_in_message}

      {:error, message} ->
        {:error, message}
    end
  end

  defp refresh_and_store(provider_id, credential, opts) do
    refresh_token = credential["refresh"]
    oauth_opts = Keyword.take(opts, [:req_module, :now_ms])

    case XaiOAuth.refresh(refresh_token, oauth_opts) do
      {:ok, refreshed} ->
        case Storage.put(provider_id, refreshed, opts) do
          :ok ->
            {:ok, XaiOAuth.to_auth(refreshed)}

          {:error, message} ->
            {:error, message}
        end

      {:error, _reason} ->
        _ = Storage.delete(provider_id, opts)
        {:error, @reconnect_message}
    end
  end

  defp expired?(credential, opts) do
    now_ms = Keyword.get(opts, :now_ms, System.system_time(:millisecond))
    expires = Handbean.Utils.SafeMap.get_any(credential, "expires", :expires) || 0
    expires <= now_ms
  end

  defp with_refresh_lock(provider_id, fun) do
    lock_id = {:handbean_xai_oauth_refresh, provider_id}

    case :global.trans({lock_id, self()}, fun, [Node.self()]) do
      :aborted ->
        {:error, "xAI token refresh is already in progress"}

      result ->
        result
    end
  end
end
