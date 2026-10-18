defmodule HandbeanWeb.Locale do
  @moduledoc "Shared locale resolution for browser requests and LiveView mounts."

  alias Handbean.Settings.UI

  def resolve(params, session_locale, accept_language \\ nil) do
    UI.valid_locale(params["locale"]) || UI.locale() || UI.valid_locale(session_locale) ||
      parse_accept_language(accept_language) || default_locale()
  end

  defp default_locale do
    config = Application.get_env(:handbean, Handbean.Gettext, [])
    UI.valid_locale(config[:default_locale]) || "zh_CN"
  end

  defp parse_accept_language(nil), do: nil

  defp parse_accept_language(header) do
    header
    |> String.split(",")
    |> Enum.flat_map(fn tag ->
      [range | options] = String.split(String.trim(tag), ";")

      locale =
        case range |> String.downcase() |> String.replace("_", "-") |> String.split("-") do
          ["zh" | _] -> "zh_CN"
          ["en" | _] -> "en"
          _ -> nil
        end

      quality =
        Enum.find_value(options, 1.0, fn option ->
          case String.split(String.trim(option), "=", parts: 2) do
            ["q", value] ->
              case Float.parse(value) do
                {q, ""} when q >= 0.0 and q <= 1.0 -> q
                _ -> 0.0
              end

            _ ->
              nil
          end
        end)

      if locale && quality > 0, do: [{locale, quality}], else: []
    end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
    |> List.first()
    |> case do
      {locale, _quality} -> locale
      nil -> nil
    end
  end
end
