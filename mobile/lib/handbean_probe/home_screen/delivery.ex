defmodule HandbeanProbe.HomeScreen.Delivery do
  @moduledoc """
  User-initiated system delivery: open a URL in the system browser, open or
  share a workspace file through an export snapshot. One `handle/2` clause
  covers every `{:delivery, action, target?}` tap; the work itself lives in
  `HandbeanProbe.NativeArtifactDelivery`, whose typed platform requests complete through
  `HandbeanProbe.HomeScreen.Platform`.
  """

  alias HandbeanProbe.NativeArtifactDelivery

  def handle({:tap, {:delivery, action}}, socket), do: deliver(socket, action, nil)
  def handle({:tap, {:delivery, action, target}}, socket), do: deliver(socket, action, target)

  defp deliver(socket, :open_url, nil),
    do: NativeArtifactDelivery.start_open_url(socket, socket.assigns.open_url_draft || "")

  defp deliver(socket, :open_url, url) when is_binary(url),
    do: NativeArtifactDelivery.start_open_url(socket, url)

  defp deliver(socket, :share_text, text) when is_binary(text),
    do: NativeArtifactDelivery.start_share_text(socket, text)

  defp deliver(socket, action, nil) when action in [:open_file, :share_file],
    do: NativeArtifactDelivery.start_file_action(socket, action, socket.assigns.artifact_path)

  defp deliver(socket, action, target)
       when action in [:open_file, :share_file] and (is_map(target) or is_binary(target)),
       do: NativeArtifactDelivery.start_file_action(socket, action, target)

  defp deliver(socket, _action, _target), do: socket
end
