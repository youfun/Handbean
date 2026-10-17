defmodule Handbeam.Agent.Auth.CodexCredential do
  @moduledoc """
  ChatGPT credentials for Codex, isolated from OpenAI Platform API keys.
  Login replacement and rotating refreshes share the subscription refresh lock.
  """

  alias Handbeam.Agent.Auth.{CodexOAuth, Epoch, RefreshLock, Storage}
  alias Handbeam.Agent.BuiltinModels

  def store_login(provider_id, credential, opts \\ []) do
    access = Handbeam.Utils.SafeMap.get_any(credential, :access, "access")

    with {:ok, _account} <- CodexOAuth.account_id(access) do
      RefreshLock.trans(provider_id, fn ->
        with :ok <- Storage.put(provider_id, credential, opts) do
          Epoch.bump(provider_id)
          :ok
        end
      end)
    end
  end

  def resolve_transport_key(provider_id, opts \\ []) do
    RefreshLock.trans(provider_id, fn ->
      with {:ok, stored} <- Storage.get(provider_id, opts),
           {:ok, credential} <- refresh_if_expired(provider_id, stored, opts),
           {:ok, account_id} <- CodexOAuth.account_id(credential["access"]) do
        {:ok,
         %{
           api_key: credential["access"],
           account_id: account_id,
           auth_generation: Epoch.current(provider_id)
         }}
      else
        {:error, :not_found} -> {:error, "Sign in with ChatGPT to use the Codex subscription."}
        error -> error
      end
    end)
  end

  def provider_preset do
    %{
      "name" => "ChatGPT (Codex)",
      "provider" => "openai_codex",
      "api" => "openai-codex-responses",
      "authType" => "oauth",
      "baseUrl" => "https://chatgpt.com/backend-api/codex",
      # Offline fallback from the Codex CLI rust-v0.163.0 bundled catalog.
      # Refresh replaces this with the account's live /models response.
      # gpt-5.4 is visibility=hide there and was retired from ChatGPT Codex.
      "models" => BuiltinModels.codex()
    }
  end

  defp refresh_if_expired(provider_id, stored, opts) do
    now = Keyword.get(opts, :now_ms, System.system_time(:millisecond))

    if stored["expires"] > now do
      {:ok, stored}
    else
      # Preserve the previous credentials on failure, including network failures.
      # Never retry a rotating refresh automatically or fall back to an API key.
      with {:ok, refreshed} <- CodexOAuth.refresh(stored["refresh"], opts),
           :ok <- Storage.put(provider_id, refreshed, opts) do
        Storage.get(provider_id, opts)
      end
    end
  end
end
