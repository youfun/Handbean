defmodule HandbeanWeb.FileBrowserHarness do
  @moduledoc false
  use HandbeanWeb, :live_view

  alias HandbeanWeb.FileBrowserComponent

  @impl true
  def mount(_params, session, socket) do
    {:ok,
     socket
     |> assign(:current_path, session["path"])
     |> assign(:show_browser, session["show"])}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component
      module={FileBrowserComponent}
      id="file-browser"
      show_browser={@show_browser}
      current_path={@current_path}
    />
    """
  end
end
