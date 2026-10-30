defmodule HandbeanWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use HandbeanWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    info = Phoenix.Flash.get(assigns.flash, :info)
    error = Phoenix.Flash.get(assigns.flash, :error)

    assigns =
      assigns
      |> assign(:info, info)
      |> assign(:error, error)
      |> assign(:info_navigate, flash_navigate(info))
      |> assign(:error_navigate, flash_navigate(error))
      |> assign(:info_click, flash_click(info))
      |> assign(:error_click, flash_click(error))

    ~H"""
    <div id={@id} aria-live="polite">
      <.flash
        :if={@info_navigate}
        kind={:info}
        title={flash_title(@info)}
        navigate={@info_navigate}
        phx-click={@info_click}
      >
        {flash_body(@info)}
      </.flash>
      <.flash
        :if={!@info_navigate}
        kind={:info}
        title={flash_title(@info)}
        flash={%{"info" => flash_body(@info)}}
      />
      <.flash
        :if={@error_navigate}
        kind={:error}
        title={flash_title(@error)}
        navigate={@error_navigate}
        phx-click={@error_click}
      >
        {flash_body(@error)}
      </.flash>
      <.flash
        :if={!@error_navigate}
        kind={:error}
        title={flash_title(@error)}
        flash={%{"error" => flash_body(@error)}}
      />
    </div>
    """
  end

  defp flash_navigate(%{navigate: path}) when is_binary(path) and path != "", do: path
  defp flash_navigate(_), do: nil

  defp flash_click(%{navigate: path, navigate_with: :patch})
       when is_binary(path) and path != "" do
    JS.patch(path)
  end

  defp flash_click(%{navigate: path}) when is_binary(path) and path != "" do
    JS.navigate(path)
  end

  defp flash_click(_), do: nil

  defp flash_title(%{title: title}) when is_binary(title), do: title
  defp flash_title(_), do: nil

  defp flash_body(%{body: body}) when is_binary(body), do: body
  defp flash_body(message) when is_binary(message), do: message
  defp flash_body(_message), do: nil
end
