defmodule HandbeanProbe.HomeScreen.AppSettings do
  @moduledoc """
  App settings page controller.

  Status, grant, and system-settings requests are correlated on the
  `:app_settings` scope. A page switch bumps that scope so a late grant cannot
  update a page the user has left.
  """

  use Gettext, backend: HandbeanProbe.Gettext
  import Mob.Socket, only: [assign: 3]

  alias HandbeanProbe.AppSettings
  alias HandbeanProbe.Bridge.Inbound
  alias HandbeanProbe.HomeScreen.Requests
  alias HandbeanProbe.Platform

  @scope :app_settings

  def load(socket) do
    {_generation, socket} = Requests.bump(socket, @scope)
    start(assign(socket, :app_settings, %{current(socket) | busy: true, notice: nil}), :status)
  end

  def handle({:tap, :request_calendar}, socket), do: start(socket, :request)
  def handle({:tap, :open_app_settings}, socket), do: start(socket, :open)

  def handle({:engine_result, %Inbound.EngineResult{} = wire}, socket) do
    case Requests.take(socket, wire.request_id, wire.generation || :any) do
      {:ok, _entry, socket} -> apply_body(socket, wire.body)
      {:error, _reason, socket} -> socket
    end
  end

  def handle(_event, socket), do: socket

  defp start(socket, action) do
    request_id = Ecto.UUID.generate()
    generation = Requests.generation(socket, @scope)
    socket = assign(socket, :app_settings, %{current(socket) | busy: true, notice: nil})

    with {:ok, req} <- build(action, request_id, generation),
         {:ok, :async} <- Platform.start(req) do
      Requests.register(socket, request_id, :app_settings,
        scope: @scope,
        generation: generation,
        ctx: %{kind: :app_settings}
      )
    else
      {:error, reason} -> failed(socket, reason)
      other -> failed(socket, other)
    end
  end

  defp build(:status, request_id, generation),
    do: AppSettings.status_request(self(), request_id, generation)

  defp build(:request, request_id, generation),
    do: AppSettings.request_calendar(self(), request_id, generation)

  defp build(:open, request_id, generation),
    do: AppSettings.open_system_settings(self(), request_id, generation)

  defp apply_body(socket, {:ok, map}) when is_map(map) do
    assign(socket, :app_settings, AppSettings.apply_result(current(socket), map))
  end

  defp apply_body(socket, {:error, reason}), do: failed(socket, reason)
  defp apply_body(socket, _), do: failed(socket, :invalid_platform_result)

  defp current(socket), do: socket.assigns.app_settings || AppSettings.new()

  defp failed(socket, reason) do
    notice =
      case reason do
        :needs_foreground -> gettext("Bring Handbean to the front and try again.")
        "needs_foreground" -> gettext("Bring Handbean to the front and try again.")
        "unsupported_on_ios" -> gettext("App settings are not available on this device.")
        _ -> gettext("Could not read calendar access.")
      end

    assign(socket, :app_settings, %{current(socket) | busy: false, notice: notice})
  end
end
