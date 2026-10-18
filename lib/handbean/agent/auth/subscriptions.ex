defmodule Handbean.Agent.Auth.Subscriptions do
  @moduledoc """
  Catalog of subscription / OAuth login methods that Settings can list.

  The menu is generic like pi's `/login` selector: each entry has a
  provider id, display name, and login label. xAI, Cursor, and ChatGPT Codex
  are implemented; later subscriptions register here without changing
  the LiveView entry point.
  """

  alias Handbean.Agent.Auth.{CodexCredential, CursorCredential, XaiCredential}

  @type method :: %{
          id: String.t(),
          name: String.t(),
          login_label: String.t(),
          auth_type: :oauth,
          subscription?: boolean()
        }

  @spec methods() :: [method()]
  def methods do
    [
      %{
        id: "xai",
        name: "xAI",
        login_label: "xAI (Grok/X subscription)",
        auth_type: :oauth,
        subscription?: true,
        preset: XaiCredential.provider_preset()
      },
      %{
        id: "cursor",
        name: "Cursor",
        login_label: "Cursor (account subscription)",
        auth_type: :oauth,
        subscription?: true,
        preset: CursorCredential.provider_preset()
      },
      %{
        id: "openai_codex",
        name: "ChatGPT (Codex)",
        login_label: "ChatGPT (Codex subscription)",
        auth_type: :oauth,
        subscription?: true,
        preset: CodexCredential.provider_preset()
      }
    ]
  end

  @spec get(String.t()) :: {:ok, method()} | {:error, String.t()}
  def get(provider_id) when is_binary(provider_id) do
    case Enum.find(methods(), &(&1.id == provider_id)) do
      nil -> {:error, "Subscription provider #{provider_id} is not available"}
      method -> {:ok, method}
    end
  end
end
