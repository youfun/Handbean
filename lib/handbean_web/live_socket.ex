defmodule HandbeanWeb.LiveSocket do
  @moduledoc false

  use Phoenix.LiveView.Socket

  @impl Phoenix.Socket
  defdelegate id(socket), to: Phoenix.LiveView.Socket

  @impl Phoenix.Socket
  def connect(params, socket, connect_info) do
    session = connect_info[:session] || %{}

    if authorized?(HandbeanWeb.Access.mode(), session, connect_info) do
      super(params, socket, connect_info)
    else
      :error
    end
  end

  defp authorized?(:local, _session, connect_info),
    do: HandbeanWeb.Access.local_connect_info?(connect_info)

  defp authorized?(:password, session, _connect_info),
    do: HandbeanWeb.Access.authenticated_session?(session)

  defp authorized?(_invalid_mode, _session, _connect_info), do: false
end
