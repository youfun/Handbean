defmodule HandbeanWeb.AvailableModelsLive.Presentation do
  @moduledoc false

  use HandbeanWeb, :html

  alias Handbean.Agent.Reasoning

  def obscured_api_key(key) when is_binary(key) do
    cond do
      key == "" -> "—"
      String.starts_with?(key, "env:") -> "••••••••"
      String.length(key) > 12 -> String.slice(key, 0, 6) <> "..." <> String.slice(key, -4, 4)
      true -> String.slice(key, 0, 4) <> "..."
    end
  end

  def obscured_api_key(nil), do: "—"

  def format_context(nil), do: "—"

  def format_context(number) when is_integer(number) and number >= 1_000_000,
    do: "#{div(number, 1_000_000)}M"

  def format_context(number) when is_integer(number) and number >= 1_000,
    do: "#{div(number, 1_000)}K"

  def format_context(number) when is_integer(number), do: Integer.to_string(number)

  def format_price(%{"input" => input, "output" => output})
      when is_number(input) and is_number(output) do
    "in #{format_price_number(input)} / out #{format_price_number(output)}"
  end

  def format_price(%{input: input, output: output}) when is_number(input) and is_number(output) do
    "in #{format_price_number(input)} / out #{format_price_number(output)}"
  end

  def format_price(_), do: "—"

  def delete_confirm_title(%{type: :provider}), do: gettext("删除供应商")
  def delete_confirm_title(%{type: :model}), do: gettext("删除模型")
  def delete_confirm_title(_), do: gettext("确认删除")

  def delete_confirm_message(%{type: :provider, id: id}, providers) do
    name =
      case Enum.find(providers, &(&1.id == id)) do
        nil -> id
        provider -> provider.name
      end

    gettext("确认删除供应商「%{name}」(ID: %{id})？这将同时删除其下所有模型。", name: name, id: id)
  end

  def delete_confirm_message(%{type: :model, model_id: model_id}, _providers) do
    gettext("确认删除模型「%{id}」？", id: model_id)
  end

  def delete_confirm_message(_, _), do: gettext("确认删除？")

  def reasoning_level_label(level) do
    case level do
      "off" -> gettext("None (use provider default)")
      "minimal" -> gettext("Minimal")
      "low" -> gettext("Low")
      "medium" -> gettext("Medium")
      "high" -> gettext("High")
      "xhigh" -> gettext("X-High")
      _ -> level
    end
  end

  def reasoning_levels_for(provider_id, model) do
    model
    |> Map.put(:id, model.id)
    |> Map.put(:provider_id, provider_id)
    |> Map.put(:reasoning, true)
    |> Map.put(:reasoning_levels, Map.get(model, :reasoning_levels, []))
    |> Map.put(:default_reasoning, Map.get(model, :default_reasoning))
    |> Map.put(:thinking_level_map, Map.get(model, :thinking_level_map, %{}))
    |> Reasoning.supported_levels()
  end

  defp format_price_number(value) when is_integer(value), do: Integer.to_string(value)

  defp format_price_number(value) when is_float(value) do
    :erlang.float_to_binary(value, decimals: 6)
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
  end
end
