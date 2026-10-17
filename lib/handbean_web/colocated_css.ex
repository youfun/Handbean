defmodule HandbeanWeb.ColocatedCSS do
  @moduledoc """
  Scopes colocated component styles to the template roots that declare them.
  """

  use Phoenix.LiveView.ColocatedCSS

  @impl true
  def transform("style", _attrs, css, %{file: file, line: line}) do
    scope =
      :sha256
      |> :crypto.hash("#{file}:#{line}")
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 10)

    attribute = "data-hb-css-#{scope}"
    scoped_css = "@scope ([#{attribute}]) {\n#{css}\n}\n"

    {:ok, scoped_css, root_tag_attribute: {attribute, true}}
  end
end
