defmodule HandbeanProbe.ModelSettings.Subscriptions do
  @moduledoc """
  Device-code subscription login for the native Model settings screen.

  The protocol stays in `Handbean.Agent.Auth.CodexOAuth`, `CursorOAuth`, and
  `XaiOAuth`. This module only lists `Handbean.Agent.Auth.Subscriptions.methods/0`,
  starts a flow, polls once, and persists through the same credential writers
  desktop uses. Catalog refresh calls the existing Codex, Cursor, and xAI
  discovery functions. The screen process must not call the network functions directly.
  """

  use Gettext, backend: HandbeanProbe.Gettext

  alias Handbean.Agent.Auth.{
    CodexCredential,
    CodexOAuth,
    CursorCredential,
    CursorOAuth,
    Epoch,
    Storage,
    Subscriptions,
    XaiOAuth
  }

  alias Handbean.Agent.ModelConfig
  alias Handbean.Agent.Provider.Codex.Models, as: CodexModels
  alias Handbean.Agent.Provider.Cursor.Models, as: CursorModels
  alias Handbean.Agent.Provider.ModelCatalog

  @secret_keys [:device_code, :verifier, :access, :refresh, :api_key, :authorization]

  @doc "Subscription methods Settings can start. Same catalog desktop lists."
  def methods, do: Subscriptions.methods()

  @doc """
  Start device login for `provider_id`.

  Returns a public session (user code and verification URI only) plus the
  private device map the poll task must keep. Neither is written to disk.
  """
  def start(provider_id, opts \\ []) when is_binary(provider_id) do
    with {:ok, method} <- Subscriptions.get(provider_id),
         :ok <- ensure_provider(method),
         {:ok, device} <- start_device_flow(method, opts) do
      {:ok,
       %{
         provider_id: method.id,
         login_label: method.login_label,
         user_code: user_code(device),
         verification_uri: verification_uri(method.id, device),
         hint: hint(method.id),
         interval_ms: poll_interval_ms(device),
         device: device
       }}
    end
  end

  @doc "One poll of the private device session. Does not persist."
  def poll(provider_id, device, opts \\ []) when is_binary(provider_id) and is_map(device) do
    case poll_once(provider_id, device, opts) do
      {status, updated} when status in [:pending, :slow_down] ->
        {:continue, status, public_device(updated), poll_interval_ms(updated), updated}

      {:authorized, credential} ->
        {:authorized, credential}

      {:error, message} ->
        {:error, safe_message(message)}
    end
  end

  @doc """
  Persist an authorized credential with the desktop writer for that provider.

  Returns the epoch captured before discovery so a later login can drop a
  stale Codex catalog. The credential itself is not returned.
  """
  def persist(provider_id, credential, opts \\ []) when is_binary(provider_id) do
    case store_login(provider_id, credential, opts) do
      :ok ->
        {:ok, %{provider_id: provider_id, generation: Epoch.current(provider_id)}}

      {:error, message} ->
        {:error, safe_message(message)}
    end
  end

  @doc "Discover and save the account catalog. Codex checks `generation`."
  def discover(provider_id, generation \\ nil, opts \\ [])

  def discover("openai_codex", generation, opts) do
    if Epoch.current("openai_codex") == generation do
      case CodexModels.discover(opts) do
        {:ok, models} ->
          if Epoch.current("openai_codex") == generation do
            write_models("openai_codex", preserve_enabled(models, "openai_codex"))
          else
            {:error, gettext("ChatGPT sign-in changed before the model list was saved.")}
          end

        {:error, message} ->
          {:error, safe_message(message)}
      end
    else
      {:error, gettext("ChatGPT sign-in changed before the model list was saved.")}
    end
  end

  def discover("cursor", _generation, opts) do
    case CursorModels.discover(opts) do
      {:ok, models} -> write_models("cursor", preserve_enabled(models, "cursor"))
      {:error, message} -> {:error, safe_message(message)}
    end
  end

  def discover("xai", _generation, opts) do
    case ModelCatalog.discover("xai", opts) do
      {:ok, _summary} -> :ok
      {:error, message} -> {:error, safe_message(message)}
    end
  end

  def discover(_provider_id, _generation, _opts), do: :ok

  @doc "Fields safe to keep on the screen. Drops device secrets and tokens."
  def public_session(session) when is_map(session) do
    session
    |> Map.take([:provider_id, :login_label, :user_code, :verification_uri, :hint, :status])
    |> Map.put(:status, :waiting)
  end

  def public_device(device) when is_map(device) do
    device
    |> Map.drop(@secret_keys)
    |> Map.drop(Enum.map(@secret_keys, &Atom.to_string/1))
  end

  def poll_interval_ms(device) when is_map(device) do
    cond do
      is_integer(device[:interval_ms]) -> max(1, device.interval_ms)
      is_integer(device[:interval_seconds]) -> max(1, device.interval_seconds) * 1000
      true -> XaiOAuth.default_poll_interval_seconds() * 1000
    end
  end

  @doc """
  Copy `text` with `Mob.Clipboard.put/2`, the same NIF markdown copy uses.

  Host tests have no clipboard NIF. `:handbean_probe, :clipboard_put` may
  replace the call; it receives only the text being copied.
  """
  def copy(socket, text) when is_binary(text) do
    HandbeanProbe.NativeClipboard.put(socket, text)
  end

  def connected_message("openai_codex"), do: gettext("Connected ChatGPT / Codex subscription")
  def connected_message("cursor"), do: gettext("Connected Cursor subscription")
  def connected_message("xai"), do: gettext("Connected xAI / Grok subscription")
  def connected_message(_), do: gettext("Connected subscription")

  def hint("openai_codex") do
    gettext(
      "Open the link and enter the user code to authorize ChatGPT. This uses the Codex subscription, not an OpenAI API balance. Available models and limits depend on the account."
    )
  end

  def hint("cursor") do
    gettext(
      "Open the link and authorize with your Cursor account. This uses an unofficial protocol. Cost is unknown and is not shown as free."
    )
  end

  def hint("xai"),
    do: gettext("Open the link and enter the user code to authorize the xAI subscription.")

  def hint(_), do: gettext("Open the link to finish subscription sign-in.")

  defp start_device_flow(%{id: "xai"}, opts), do: XaiOAuth.start(opts)
  defp start_device_flow(%{id: "openai_codex"}, opts), do: CodexOAuth.start(opts)
  defp start_device_flow(%{id: "cursor"}, opts), do: CursorOAuth.start(opts)

  defp start_device_flow(%{id: id}, _opts),
    do: {:error, gettext("Subscription login for %{id} is not available yet.", id: id)}

  defp verification_uri("xai", device), do: XaiOAuth.browser_verification_uri(device)
  defp verification_uri("openai_codex", device), do: CodexOAuth.browser_verification_uri(device)
  defp verification_uri("cursor", device), do: CursorOAuth.browser_verification_uri(device)
  defp verification_uri(_id, device), do: device[:verification_uri]

  defp poll_once("xai", device, opts), do: XaiOAuth.poll_once(device, opts)
  defp poll_once("openai_codex", device, opts), do: CodexOAuth.poll_once(device, opts)
  defp poll_once("cursor", device, opts), do: CursorOAuth.poll_once(device, opts)

  defp poll_once(id, _device, _opts),
    do: {:error, gettext("Subscription login for %{id} is not available yet.", id: id)}

  defp store_login("openai_codex", credential, opts),
    do: CodexCredential.store_login("openai_codex", credential, opts)

  defp store_login("cursor", credential, opts),
    do: CursorCredential.store_login("cursor", credential, opts)

  defp store_login(provider_id, credential, opts), do: Storage.put(provider_id, credential, opts)

  defp user_code(%{user_code: code}) when is_binary(code) and code != "", do: code
  defp user_code(_), do: nil

  defp ensure_provider(%{id: provider_id, preset: preset}) do
    case ModelConfig.add_provider(provider_id, preset) do
      :ok ->
        :ok

      {:error, message} ->
        if String.contains?(to_string(message), "already exists") do
          ModelConfig.update_provider(provider_id, Map.drop(preset, ["models"]))
        else
          {:error, safe_message(message)}
        end
    end
  end

  defp write_models(provider_id, models) do
    case ModelConfig.update_provider(provider_id, %{"models" => models}) do
      :ok -> :ok
      {:error, message} -> {:error, safe_message(message)}
    end
  end

  defp preserve_enabled(models, provider_id) do
    previous =
      case ModelConfig.read_config() do
        {:ok, %{"providers" => %{^provider_id => %{"models" => existing}}}}
        when is_list(existing) ->
          Map.new(existing, fn model -> {model["id"], model["enabled"]} end)

        _ ->
          %{}
      end

    Enum.map(models, fn model ->
      case Map.get(previous, model["id"]) do
        enabled when is_boolean(enabled) -> Map.put(model, "enabled", enabled)
        _ -> model
      end
    end)
  end

  defp safe_message(message) when is_binary(message) do
    if credential_text?(message), do: gettext("Subscription sign-in failed."), else: message
  end

  defp safe_message(_), do: gettext("Subscription sign-in failed.")

  defp credential_text?(text) do
    String.contains?(text, ["refresh_token", "access_token", "api_key", "Bearer "]) or
      String.contains?(text, "eyJ")
  end
end
