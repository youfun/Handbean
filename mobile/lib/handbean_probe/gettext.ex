defmodule HandbeanProbe.Gettext do
  @moduledoc """
  Gettext backend for the native Mob UI.

  Translations are compiled from priv/gettext into this module. Device runtime
  does not load Mix config or priv .po files.

  `HomeScreen.mount/3` calls `locale/0` instead of hard-coding a locale.
  Resolution order:

  1. `Application.get_env(:handbean_probe, :locale)` (tests, device overrides)
  2. Mob does not expose the Android system locale on the pinned version, so
     that level is skipped.
  3. `@default_locale` (`zh_CN`).

  Unknown or malformed values fall back to the default so a bad setting can
  never leave the UI without translations.
  """
  use Gettext.Backend, otp_app: :handbean_probe

  @default_locale "zh_CN"

  @doc "Locale the native UI should render in (see moduledoc for precedence)."
  def locale do
    :handbean_probe
    |> Application.get_env(:locale)
    |> normalize()
  end

  @doc false
  def default_locale, do: @default_locale

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
