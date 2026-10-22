defmodule HandbeanProbe.HomeScreen.UiSettings do
  @moduledoc """
  Native UI settings. Language persists through `Handbean.Settings.UI`
  (`ui.locale`), the same owner as Web. Theme is not offered on mobile yet.
  """

  use Gettext, backend: HandbeanProbe.Gettext
  import HandbeanProbe.NativeUI

  alias Handbean.Settings.UI
  alias HandbeanProbe.HomeScreen.Notice
  alias HandbeanProbe.Gettext, as: ProbeGettext

  def handle({:tap, {:locale, locale}}, socket) when locale in ["zh_CN", "en"] do
    case UI.save_locale(locale) do
      :ok ->
        ProbeGettext.apply(locale)
        Notice.clear(socket)

      {:error, _reason} ->
        Notice.put_error(socket, gettext("Could not save language preference."))
    end
  end

  def handle(_event, socket), do: socket

  def render do
    current = ProbeGettext.locale()

    scroll([
      settings_section(gettext("Language")),
      settings_group([
        settings_check_row(
          gettext("中文 (简体)"),
          current == "zh_CN",
          {:locale, "zh_CN"}
        ),
        settings_check_row(gettext("English"), current == "en", {:locale, "en"})
      ]),
      settings_group([
        settings_value_row(gettext("Theme"), gettext("Not available"))
      ])
    ])
  end

  def language_label("en"), do: gettext("English")
  def language_label(_), do: gettext("中文 (简体)")
end
