defmodule HandbeanWeb.RestoreLocale do
  @moduledoc """
  An `on_mount` hook to restore and apply the locale in LiveViews.
  """
  import Phoenix.Component

  def on_mount(:default, params, session, socket) do
    params = if is_map(params), do: params, else: %{}
    locale = HandbeanWeb.Locale.resolve(params, Map.get(session, "locale"))
    Gettext.put_locale(Handbean.Gettext, locale)
    {:cont, assign(socket, locale: locale, theme: Handbean.Settings.UI.theme())}
  end
end
