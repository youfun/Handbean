defmodule Handbean.Browser.Chrome do
  @moduledoc """
  Product owner for controlling the user's existing Chrome profile.

  Enablement is global and explicit. While enabled, the bundled extension may
  expose ordinary tabs to the existing `browser` tool through the local CDP
  relay. Per-tab debugger attachment is an implementation detail; users stop
  the whole connection with one switch.
  """

  alias Handbean.Browser.{ChromeRelay.Server, Cli, Runtime}
  alias Handbean.Settings

  @topic "browser_chrome:status"
  @settings_key "chrome_browser"

  @spec supported?() :: boolean()
  def supported? do
    Application.get_env(:handbean, :chrome_control, true) and
      Handbean.Tool.Builtin.Browser.backend() == :cli
  end

  @spec enabled?(keyword()) :: boolean()
  def enabled?(opts \\ []) do
    {:ok, settings} = Settings.load_global(opts)
    match?(%{"enabled" => true}, Map.get(settings, @settings_key, %{}))
  end

  @spec set_enabled(boolean(), keyword()) :: :ok | {:error, term()}
  def set_enabled(enabled, opts \\ [])

  def set_enabled(true, opts) do
    with true <- supported?() || {:error, :unavailable},
         {:ok, section} <- ensure_pairing_token(opts),
         :ok <-
           Settings.save_global_section(@settings_key, Map.put(section, "enabled", true), opts) do
      broadcast({:chrome_browser_enabled, true})
      :ok
    end
  end

  def set_enabled(false, opts) do
    with {:ok, section} <- settings_section(opts),
         :ok <-
           Settings.save_global_section(@settings_key, Map.put(section, "enabled", false), opts) do
      Server.stop_all()
      broadcast({:chrome_browser_enabled, false})
      :ok
    end
  end

  @spec status() :: map()
  def status do
    if supported?() do
      relay = Server.status()
      compatibility = Cli.chrome_relay_compatibility()

      %{
        supported: true,
        enabled: enabled?(),
        relay_available: relay.listener_port != nil,
        extension_connected: relay.extension_connected,
        controlled_tabs: relay.tabs,
        client_count: relay.client_count,
        pairing_url: pairing_url(relay.listener_port),
        extension_path: extension_path(),
        agent_browser: compatibility
      }
    else
      %{
        supported: false,
        enabled: false,
        relay_available: false,
        extension_connected: false,
        controlled_tabs: 0,
        client_count: 0,
        pairing_url: nil,
        extension_path: nil,
        agent_browser: %{available: false, compatible: false, version: nil, message: nil}
      }
    end
  end

  @spec browser_options() :: {:ok, keyword()} | {:error, String.t()}
  def browser_options do
    cond do
      not enabled?() ->
        {:ok, []}

      not Server.extension_connected?() ->
        {:error,
         "Chrome control is enabled but the Handbean extension is not connected. " <>
           "Open Computer Control settings and pair the extension, or turn Chrome control off."}

      true ->
        case Server.cdp_url() do
          url when is_binary(url) -> {:ok, cdp_url: url, pin_tab: true}
          _ -> {:error, "Chrome relay is unavailable"}
        end
    end
  end

  @spec authorize_extension(String.t()) :: boolean()
  def authorize_extension(token) when is_binary(token) do
    enabled?() and secure_compare(token, pairing_token())
  end

  def authorize_extension(_token), do: false

  @spec extension_origin_allowed?(String.t() | nil) :: boolean()
  def extension_origin_allowed?(origin) when is_binary(origin) do
    case Application.get_env(:handbean, :chrome_extension_id) do
      id when is_binary(id) and id != "" -> origin == "chrome-extension://#{id}"
      _ -> String.starts_with?(origin, "chrome-extension://")
    end
  end

  def extension_origin_allowed?(_origin), do: false

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Handbean.PubSub, @topic)

  @doc false
  def broadcast(message) do
    if Process.whereis(Handbean.PubSub),
      do: Phoenix.PubSub.broadcast(Handbean.PubSub, @topic, message),
      else: :ok
  end

  defp pairing_url(nil), do: nil

  defp pairing_url(port) do
    if enabled?() do
      case pairing_token() do
        token when is_binary(token) and token != "" ->
          "ws://127.0.0.1:#{port}/extension/#{token}"

        _ ->
          nil
      end
    end
  end

  defp extension_path, do: Runtime.chrome_extension_path()

  defp ensure_pairing_token(opts) do
    with {:ok, section} <- settings_section(opts) do
      case Map.get(section, "pairing_token") do
        token when is_binary(token) and byte_size(token) >= 32 -> {:ok, section}
        _ -> {:ok, Map.put(section, "pairing_token", random_token())}
      end
    end
  end

  defp pairing_token do
    with {:ok, section} <- settings_section([]),
         token when is_binary(token) <- Map.get(section, "pairing_token") do
      token
    else
      _ -> nil
    end
  end

  defp settings_section(opts) do
    with {:ok, settings} <- Settings.load_global(opts) do
      case Map.get(settings, @settings_key, %{}) do
        section when is_map(section) -> {:ok, section}
        _ -> {:ok, %{}}
      end
    end
  end

  defp random_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp secure_compare(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right) do
    Plug.Crypto.secure_compare(left, right)
  end

  defp secure_compare(_left, _right), do: false
end
