defmodule HandbeanWeb.Live.Settings.ComputerUsePanel do
  @moduledoc "Computer control settings panel, state, and event owner."

  use HandbeanWeb, :html

  require Phoenix.LiveView

  attr(:browser_status, :map, required: true)
  attr(:computer_status, :map, required: true)

  def render(assigns) do
    ~H"""
    <div class="settings-content-wrap">
      <div class="settings-content-card settings-form-section computer-control-settings">
        <div class="settings-section-heading">
          <div class="settings-section-title">{gettext("Computer Control")}</div>
          <div class="settings-help-text">
            {gettext(
              "Manage the browser connection and the native macOS capability available to this Agent."
            )}
          </div>
        </div>

        <div class="computer-control-group-label">{gettext("Browser")}</div>
        <div id="browser-extension-settings" class="settings-card">
          <div class="settings-field-row">
            <div class="settings-field-copy computer-control-product">
              <div class="computer-control-product-icon" aria-hidden="true">◎</div>
              <div>
                <div class="settings-field-title">
                  {gettext("Google Chrome")}
                  <span class="settings-badge-experimental">
                    {cond do
                      !@browser_status.supported -> gettext("Unavailable")
                      @browser_status.extension_connected -> gettext("Connected")
                      @browser_status.enabled -> gettext("Waiting for extension")
                      true -> gettext("Off")
                    end}
                  </span>
                </div>
                <div class="settings-field-desc">
                  {gettext(
                    "Connect Handbean to ordinary tabs in your current Chrome profile. Tabs are managed automatically while this switch is on; risky actions still use Handbean confirmations."
                  )}
                </div>
              </div>
            </div>
            <div class="settings-field-control">
              <button
                id="browser-extension-toggle"
                type="button"
                phx-click="toggle_chrome_browser"
                disabled={!@browser_status.supported}
                class="settings-toggle-button speech-settings-toggle"
                role="switch"
                aria-checked={to_string(@browser_status.enabled)}
                aria-label={gettext("Enable Chrome extension connection")}
              >
                <span class="settings-toggle-track" aria-hidden="true">
                  <span class="settings-toggle-thumb"></span>
                </span>
              </button>
            </div>
          </div>

          <div :if={@browser_status.enabled} class="settings-field-row computer-control-status-row">
            <div class="settings-field-copy">
              <div class="settings-field-title">{gettext("Extension connection")}</div>
              <div class="computer-control-status-list">
                <span>
                  {gettext("Relay:")}
                  <strong>
                    {if @browser_status.relay_available,
                      do: gettext("Ready"),
                      else: gettext("Unavailable")}
                  </strong>
                </span>
                <span>
                  {gettext("Extension:")}
                  <strong>
                    {if @browser_status.extension_connected,
                      do: gettext("Connected"),
                      else: gettext("Not connected")}
                  </strong>
                </span>
                <span>
                  {gettext("Available tabs:")}
                  <strong>{@browser_status.controlled_tabs}</strong>
                </span>
                <span>
                  {gettext("agent-browser:")}
                  <strong>
                    <%= cond do %>
                      <% @browser_status.agent_browser.compatible -> %>
                        {@browser_status.agent_browser.version}
                      <% @browser_status.agent_browser.available -> %>
                        {gettext("%{version} · upgrade required",
                          version: @browser_status.agent_browser.version
                        )}
                      <% true -> %>
                        {gettext("Not found")}
                    <% end %>
                  </strong>
                </span>
              </div>
              <div class="settings-field-desc computer-control-pairing-help">
                {gettext(
                  "Load the unpacked extension from %{path}, then paste the pairing URL into its popup. Packaged desktop builds include the browser runtime.",
                  path: @browser_status.extension_path
                )}
              </div>
            </div>
            <div class="settings-field-control computer-control-browser-actions">
              <button
                :if={@browser_status.pairing_url}
                id="browser-extension-copy-pairing"
                type="button"
                class="settings-btn"
                phx-hook="CopyText"
                data-copy={@browser_status.pairing_url}
              >
                {gettext("Copy pairing URL")}
              </button>
              <button
                id="browser-extension-refresh"
                type="button"
                phx-click="refresh_chrome_browser_status"
                class="settings-btn"
              >
                {gettext("Refresh")}
              </button>
            </div>
          </div>
        </div>

        <div class="computer-control-group-label">{gettext("Desktop")}</div>
        <div id="computer-use-settings" class="settings-card">
          <div class="settings-field-row">
            <div class="settings-field-copy">
              <div class="settings-field-title">
                {gettext("Enable computer control")}
                <span class="settings-badge-experimental">
                  {if @computer_status.supported,
                    do: gettext("macOS native"),
                    else: gettext("Unavailable on this platform")}
                </span>
              </div>
              <div class="settings-field-desc">
                {gettext(
                  "Allows the Agent to observe and control one approved window for the current run. Approve the target once; Stop, run end, or two idle minutes revokes control."
                )}
              </div>
            </div>
            <div class="settings-field-control">
              <button
                id="computer-use-enabled-toggle"
                type="button"
                phx-click="toggle_computer_use"
                disabled={!@computer_status.supported}
                class="settings-toggle-button speech-settings-toggle"
                role="switch"
                aria-checked={to_string(@computer_status.enabled)}
                aria-label={gettext("Enable computer control")}
              >
                <span class="settings-toggle-track" aria-hidden="true">
                  <span class="settings-toggle-thumb"></span>
                </span>
              </button>
            </div>
          </div>

          <div class="settings-field-row computer-control-status-row">
            <div class="settings-field-copy">
              <div class="settings-field-title">{gettext("macOS permissions")}</div>
              <div class="computer-control-status-list">
                <span>
                  {gettext("Screen Recording")}
                  <strong>{permission_label(
                    if is_map(@computer_status.permissions),
                      do: @computer_status.permissions.screen_recording,
                      else: :unknown
                  )}</strong>
                </span>
                <span>
                  {gettext("Accessibility")}
                  <strong>{permission_label(
                    if is_map(@computer_status.permissions),
                      do: @computer_status.permissions.accessibility,
                      else: :unknown
                  )}</strong>
                </span>
                <span>
                  {gettext("Input control")}
                  <strong>{permission_label(
                    if is_map(@computer_status.permissions),
                      do: @computer_status.permissions.event_post,
                      else: :unknown
                  )}</strong>
                </span>
              </div>
            </div>
            <div class="settings-field-control">
              <button
                id="computer-use-refresh"
                type="button"
                phx-click="refresh_computer_use_status"
                disabled={!@computer_status.supported}
                class="settings-btn"
              >
                {gettext("Refresh")}
              </button>
            </div>
          </div>

          <div class="settings-field-row">
            <div class="settings-field-copy">
              <div class="settings-field-title">{gettext("Pointer input")}</div>
              <div class="settings-field-desc">
                {gettext(
                  "Typing and supported keys are available. Click and scroll stay closed until real-device targeting acceptance passes."
                )}
              </div>
            </div>
            <div class="settings-field-control">
              <span class="settings-badge-experimental">
                {action_label(@computer_status, "click")}
              </span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  def init(socket) do
    socket
    |> assign(:computer_use_status, initial_status())
    |> assign(:browser_extension_status, Handbean.Browser.Chrome.status())
    |> subscribe_to_computer_use()
    |> subscribe_to_chrome_browser()
    |> maybe_refresh_status()
  end

  def handle_event("toggle_computer_use", _params, socket) do
    enabled = not socket.assigns.computer_use_status.enabled

    case Handbean.ComputerUse.set_enabled(enabled) do
      :ok ->
        {:noreply,
         socket
         |> update(:computer_use_status, &Map.put(&1, :enabled, enabled))
         |> refresh_status()}

      {:error, :unavailable} ->
        {:noreply,
         Phoenix.LiveView.put_flash(
           socket,
           :error,
           gettext("Computer control is unavailable in this host.")
         )}

      {:error, _reason} ->
        {:noreply,
         Phoenix.LiveView.put_flash(
           socket,
           :error,
           gettext("Could not save computer control setting.")
         )}
    end
  end

  def handle_event("refresh_computer_use_status", _params, socket) do
    {:noreply, refresh_status(socket)}
  end

  def handle_event("toggle_chrome_browser", _params, socket) do
    enabled = not socket.assigns.browser_extension_status.enabled

    case Handbean.Browser.Chrome.set_enabled(enabled) do
      :ok ->
        {:noreply, assign(socket, :browser_extension_status, Handbean.Browser.Chrome.status())}

      {:error, :unavailable} ->
        {:noreply,
         Phoenix.LiveView.put_flash(
           socket,
           :error,
           gettext("Chrome control is unavailable in this host.")
         )}

      {:error, _reason} ->
        {:noreply,
         Phoenix.LiveView.put_flash(
           socket,
           :error,
           gettext("Could not save Chrome control setting.")
         )}
    end
  end

  def handle_event("refresh_chrome_browser_status", _params, socket) do
    {:noreply, assign(socket, :browser_extension_status, Handbean.Browser.Chrome.status())}
  end

  def handle_async(:computer_use_status, {:ok, status}, socket) when is_map(status) do
    {:noreply, assign(socket, :computer_use_status, status)}
  end

  def handle_async(:computer_use_status, {:exit, _reason}, socket) do
    {:noreply,
     update(socket, :computer_use_status, &Map.put(&1, :error, :native_host_unavailable))}
  end

  def handle_info({:computer_use_enabled, enabled}, socket) do
    {:noreply,
     socket
     |> update(:computer_use_status, &Map.put(&1, :enabled, enabled))
     |> refresh_status()}
  end

  def handle_info({:chrome_browser_enabled, _enabled}, socket) do
    {:noreply, assign(socket, :browser_extension_status, Handbean.Browser.Chrome.status())}
  end

  def handle_info({:chrome_browser_status, _status}, socket) do
    {:noreply, assign(socket, :browser_extension_status, Handbean.Browser.Chrome.status())}
  end

  defp permission_label(true), do: gettext("Allowed")
  defp permission_label(false), do: gettext("Permission required")
  defp permission_label(_unknown), do: gettext("Unknown")

  defp action_label(status, action) do
    case get_in(status, [:actions, action]) do
      true -> gettext("Ready")
      false -> gettext("In verification")
      _ -> gettext("Unavailable")
    end
  end

  defp initial_status do
    supported = Handbean.ComputerUse.supported?()

    %{
      supported: supported,
      enabled: Handbean.ComputerUse.enabled?(),
      backend: if(supported, do: :native_macos, else: :none),
      permissions: :unknown,
      actions: %{}
    }
  end

  defp maybe_refresh_status(socket) do
    if Phoenix.LiveView.connected?(socket) and socket.assigns.computer_use_status.supported,
      do: refresh_status(socket),
      else: socket
  end

  defp refresh_status(socket) do
    if socket.assigns.computer_use_status.supported,
      do:
        Phoenix.LiveView.start_async(socket, :computer_use_status, &Handbean.ComputerUse.status/0),
      else: socket
  end

  defp subscribe_to_computer_use(socket) do
    if Phoenix.LiveView.connected?(socket), do: Handbean.ComputerUse.subscribe()
    socket
  end

  defp subscribe_to_chrome_browser(socket) do
    if Phoenix.LiveView.connected?(socket), do: Handbean.Browser.Chrome.subscribe()
    socket
  end
end
