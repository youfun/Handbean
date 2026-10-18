defmodule Handbean.Agent.Auth.CursorCredential do
  @moduledoc """
  Resolves a Cursor transport token from `~/.handbean/auth.json`.

  Temporary refresh or network failures keep the stored credential.
  Only an explicit invalid grant for the *same* refresh token deletes it.
  A later login that replaced the refresh token is left intact.
  """

  alias Handbean.Agent.Auth.{CursorOAuth, Epoch, RefreshLock, Storage}

  @sign_in_message "Sign in with a Cursor subscription to connect."

  @spec resolve_transport_key(String.t(), keyword()) ::
          {:ok, %{api_key: String.t(), auth_generation: integer()}} | {:error, String.t()}
  def resolve_transport_key(provider_id, opts \\ []) when is_binary(provider_id) do
    RefreshLock.trans(provider_id, fn ->
      do_resolve_transport_key(provider_id, opts)
    end)
  end

  @spec bump_epoch(String.t()) :: integer()
  def bump_epoch(provider_id \\ "cursor") do
    Epoch.bump(provider_id)
  end

  @spec current_epoch(String.t()) :: integer()
  def current_epoch(provider_id \\ "cursor") do
    Epoch.current(provider_id)
  end

  @spec provider_preset() :: map()
  def provider_preset do
    %{
      "name" => "Cursor",
      "provider" => "cursor",
      "baseUrl" => "https://api2.cursor.sh",
      "api" => "cursor-agent",
      "authType" => "oauth",
      "unofficial" => true,
      "models" => []
    }
  end

  @doc "Persist a newly authorized credential under the refresh lock."
  @spec store_login(String.t(), map(), keyword()) :: :ok | {:error, String.t()}
  def store_login(provider_id, credential, opts \\ [])
      when is_binary(provider_id) and is_map(credential) do
    RefreshLock.trans(provider_id, fn ->
      case Storage.put(provider_id, credential, opts) do
        :ok ->
          Epoch.bump(provider_id)
          :ok

        other ->
          other
      end
    end)
  end

  @doc "Call after a successful browser login writes a new credential."
  @spec mark_login(String.t()) :: integer()
  def mark_login(provider_id \\ "cursor") do
    Epoch.bump(provider_id)
  end

  defp do_resolve_transport_key(provider_id, opts) do
    generation = Epoch.current(provider_id)

    case Storage.get(provider_id, opts) do
      {:ok, credential} ->
        if expired?(credential, opts) do
          refresh_and_store(provider_id, credential, generation, opts)
        else
          {:ok, auth_snapshot(credential, generation)}
        end

      {:error, :not_found} ->
        {:error, @sign_in_message}

      {:error, message} ->
        {:error, message}
    end
  end

  defp refresh_and_store(provider_id, credential, generation, opts) do
    refresh_token = credential["refresh"]
    oauth_opts = Keyword.take(opts, [:req_module, :now_ms])

    case CursorOAuth.refresh(refresh_token, oauth_opts) do
      {:ok, refreshed} ->
        put_if_same_refresh(provider_id, credential, refreshed, generation, opts)

      {:error, {:invalid, message}} ->
        delete_if_same_refresh(provider_id, credential, opts)
        {:error, message}

      {:error, {:temporary, message}} ->
        {:error, message}

      {:error, message} when is_binary(message) ->
        {:error, message}
    end
  end

  defp put_if_same_refresh(provider_id, previous, refreshed, generation, opts) do
    if Epoch.current(provider_id) != generation do
      {:error, "Cursor token refresh was discarded after a newer login"}
    else
      case Storage.get(provider_id, opts) do
        {:ok, current} ->
          if current["refresh"] == previous["refresh"] do
            case Storage.put(provider_id, refreshed, opts) do
              :ok -> {:ok, auth_snapshot(refreshed, generation)}
              {:error, message} -> {:error, message}
            end
          else
            {:ok, auth_snapshot(current, Epoch.current(provider_id))}
          end

        {:error, :not_found} ->
          {:error, @sign_in_message}

        {:error, message} ->
          {:error, message}
      end
    end
  end

  defp delete_if_same_refresh(provider_id, previous, opts) do
    case Storage.get(provider_id, opts) do
      {:ok, current} ->
        if current["refresh"] == previous["refresh"] do
          Storage.delete(provider_id, opts)
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  defp auth_snapshot(credential, generation) do
    CursorOAuth.to_auth(credential, auth_generation: generation)
  end

  defp expired?(credential, opts) do
    now_ms = Keyword.get(opts, :now_ms, System.system_time(:millisecond))
    expires = Handbean.Utils.SafeMap.get_any(credential, "expires", :expires) || 0
    expires <= now_ms
  end
end
