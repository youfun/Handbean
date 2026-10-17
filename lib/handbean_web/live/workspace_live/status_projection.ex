defmodule HandbeanWeb.WorkspaceLive.StatusProjection do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  def update_status(socket, overrides),
    do: assign(socket, :status_info, Map.merge(socket.assigns.status_info, overrides))

  def maybe_update_status(socket, overrides) do
    if Map.has_key?(socket.assigns, :status_info),
      do: update_status(socket, overrides),
      else: socket
  end
end
