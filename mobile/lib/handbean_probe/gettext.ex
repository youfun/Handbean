defmodule HandbeanProbe.Gettext do
  @moduledoc """
  Gettext backend for the native Mob UI.

  Translations are compiled from priv/gettext into this module. Device runtime
  does not load Mix config or priv .po files.

  `HomeScreen.mount/3` calls `locale/0` instead of hard-coding a locale.
  Resolution order:

  1. `Application.get_env(:handbean_probe, :locale)` (tests)
  2. `Handbean.Settings.UI.locale/0` (`ui.locale` in SQLite, same as Web)
  3. `@default_locale` (`zh_CN`).

  Unknown or malformed values fall back to the default so a bad setting can
  never leave the UI without translations.
  """
  use Gettext.Backend, otp_app: :handbean_probe

  alias Handbean.Settings.UI

  @default_locale "zh_CN"

  @doc "Locale the native UI should render in (see moduledoc for precedence)."
  def locale do
    :handbean_probe
    |> Application.get_env(:locale)
    |> Kernel.||(persisted_locale())
    |> normalize()
  end

  @doc "Apply a supported locale to this process and both Gettext backends."
  def apply(locale) do
    locale = normalize(locale)
    Gettext.put_locale(__MODULE__, locale)
    Gettext.put_locale(locale)

    if Code.ensure_loaded?(Handbean.Gettext) do
      Gettext.put_locale(Handbean.Gettext, locale)
    end

    locale
  end

  @doc false
  def default_locale, do: @default_locale

  defp persisted_locale do
    case Process.whereis(Handbean.Repo) do
      pid when is_pid(pid) -> UI.locale()
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp normalize(locale) when is_atom(locale) and not is_nil(locale),
    do: locale |> Atom.to_string() |> normalize()

  defp normalize(locale) when is_binary(locale) do
    candidate = String.replace(locale, "-", "_")

    if candidate in Gettext.known_locales(__MODULE__),
      do: candidate,
      else: @default_locale
  end

  defp normalize(_), do: @default_locale
end
