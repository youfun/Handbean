defmodule Handbean.Gettext do
  @moduledoc """
  Shared Gettext backend for domain errors and presentation adapters.

  Presentation layers choose when and how to render translated text, while
  shared runtime adapters can use the same locale catalog without depending on
  a concrete Web module.
  """

  use Gettext.Backend, otp_app: :handbean
end
