defmodule HandbeanWeb.AvailableModelsLive.Forms do
  @moduledoc false

  alias Handbean.Agent.Provider.SubscriptionCatalog
  alias Handbean.Agent.Reasoning
  alias Handbean.LlmDbDefaults
  alias HandbeanWeb.AvailableModelsLive.Projection

  @subscription_presets ["ollama", "ollama-cloud", "ollama_cloud", "opencode-go", "opencode_go"]

  def reset_add_provider do
    %{
      "name" => "",
      "id" => "",
      "api" => "openai",
      "base_url" => "",
      "api_key" => "",
      "provider_runtime" => "",
      "model_id" => "",
      "model_name" => "",
      "context_window" => "128000",
      "max_tokens" => "8192",
      "price_input" => "",
      "price_output" => "",
      "price_cache_read" => "",
      "price_cache_write" => "",
      "price_reasoning" => "",
      "reasoning" => "false",
      "reasoning_levels" => []
    }
  end

  def reset_add_model do
    %{
      "id" => "",
      "name" => "",
      "type" => "text",
      "context_window" => "128000",
      "max_tokens" => "8192",
      "price_input" => "",
      "price_output" => "",
      "price_cache_read" => "",
      "price_cache_write" => "",
      "price_reasoning" => "",
      "reasoning" => "false",
      "reasoning_levels" => []
    }
  end

  def merge_add_provider(previous, params) do
    previous
    |> Map.merge(params)
    |> apply_subscription_preset()
  end

  def add_provider_submission(current, submitted, providers) do
    params =
      current
      |> Map.merge(submitted)
      |> apply_subscription_preset()
      |> hydrate_add_provider(true)

    name = params["name"] |> to_string() |> String.trim()
    api = params["api"] |> to_string() |> String.trim()
    base_url = params["base_url"] |> to_string() |> String.trim()
    api_key = params["api_key"] |> to_string() |> String.trim()

    provider_id =
      params["id"]
      |> to_string()
      |> String.trim()
      |> present_or(generated_provider_id(name, providers))

    cond do
      provider_id == "" ->
        {:error, :provider_id_empty}

      not String.match?(provider_id, ~r/^[a-z0-9_-]+$/) ->
        {:error, :provider_id_invalid}

      true ->
        attrs = %{
          "provider" => runtime_provider(params, provider_id),
          "baseUrl" => base_url,
          "api" => api,
          "apiKey" => api_key,
          "name" => present_or(name, Projection.display_name(provider_id)),
          "models" => subscription_seed_models(provider_id)
        }

        {:ok, provider_id, attrs}
    end
  end

  def edit_provider_form(provider) do
    %{
      "name" => provider.name,
      "api" => provider.api,
      "base_url" => provider.base_url,
      "api_key" => form_api_key(provider.api_key)
    }
  end

  def edit_provider_attrs(current, submitted) do
    params = Map.merge(current, submitted)

    %{
      "name" => params["name"],
      "api" => params["api"],
      "baseUrl" => params["base_url"]
    }
    |> maybe_put_api_key(params["api_key"])
  end

  def add_model_submission(current, submitted, provider_id) do
    params = current |> Map.merge(submitted) |> hydrate_add_model(true)
    model_id = params["id"] |> to_string() |> String.trim()

    if model_id == "" do
      {:error, :model_id_empty}
    else
      model_name = params["name"] |> to_string() |> String.trim()
      type = params["type"] |> to_string() |> String.trim()

      attrs =
        %{
          "name" => present_or(model_name, model_id),
          "input" => [type || "text"],
          "contextWindow" => parse_int(params["context_window"], 128_000),
          "maxTokens" => parse_int(params["max_tokens"], 8192),
          "cost" => build_cost_map(params)
        }
        |> maybe_put_reasoning(Map.put(params, "provider_id", provider_id), model_id)
        |> maybe_drop_empty_cost()

      {:ok, model_id, attrs}
    end
  end

  def reasoning_level_checked?(form, level) do
    selected = selected_reasoning_levels(form)
    selected == [] or level in selected
  end

  def configurable_reasoning_levels(form) do
    model_id = form["model_id"] || form["id"]
    provider_id = form["provider_id"] || form["id"]

    Reasoning.configurable_levels(%{id: model_id, provider_id: provider_id, reasoning: true})
  end

  defp apply_subscription_preset(form) do
    case SubscriptionCatalog.preset(form["id"]) do
      nil ->
        form

      preset ->
        form
        |> Map.put("id", preset["provider"])
        |> Map.put("name", preset["name"])
        |> Map.put("base_url", preset["baseUrl"])
        |> Map.put("api", preset["api"])
        |> Map.put("provider_runtime", preset["provider"])
        |> Map.put("subscription_preset", true)
    end
  end

  defp subscription_seed_models(provider_id) do
    case SubscriptionCatalog.preset(provider_id) do
      %{"models" => models} when provider_id in @subscription_presets and is_list(models) ->
        models

      _ ->
        []
    end
  end

  defp hydrate_add_provider(%{"subscription_preset" => true} = form, _force?), do: form

  defp hydrate_add_provider(form, force?) do
    defaults = LlmDbDefaults.defaults_for(form["id"], form["name"], form["base_url"], nil)

    form
    |> put_default("id", defaults.provider_id, false)
    |> put_default("name", defaults.provider[:provider_name], force?)
    |> put_default("base_url", defaults.provider[:base_url], force?)
    |> put_default("api", defaults.provider[:api], force?)
    |> put_default("provider_runtime", defaults.provider[:provider_runtime], force?)
  end

  defp hydrate_add_model(form, force?) do
    defaults = LlmDbDefaults.model_form_defaults(form["id"])

    form
    |> put_default("name", defaults[:model_name], force?)
    |> put_default("context_window", to_string_or_nil(defaults[:context_window]), force?)
    |> put_default("max_tokens", to_string_or_nil(defaults[:max_tokens]), force?)
    |> put_default("price_input", to_string_or_nil(defaults[:price_input]), force?)
    |> put_default("price_output", to_string_or_nil(defaults[:price_output]), force?)
    |> put_default("price_cache_read", to_string_or_nil(defaults[:price_cache_read]), force?)
    |> put_default("price_cache_write", to_string_or_nil(defaults[:price_cache_write]), force?)
    |> put_default("price_reasoning", to_string_or_nil(defaults[:price_reasoning]), force?)
  end

  defp generated_provider_id(name, providers) do
    existing = Enum.map(providers, & &1.id)

    base =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> case do
        "" -> "provider"
        slug -> slug
      end

    if base in existing do
      Stream.iterate(2, &(&1 + 1))
      |> Enum.find_value(fn number ->
        candidate = "#{base}-#{number}"
        unless candidate in existing, do: candidate
      end)
    else
      base
    end
  end

  defp runtime_provider(params, provider_id) do
    params
    |> Map.get("provider_runtime")
    |> present_or(provider_id)
  end

  defp form_api_key("env:" <> _var), do: ""
  defp form_api_key(key) when is_binary(key), do: key
  defp form_api_key(_), do: ""

  defp maybe_put_api_key(attrs, api_key) do
    case api_key |> to_string() |> String.trim() do
      "" -> attrs
      key -> Map.put(attrs, "apiKey", key)
    end
  end

  defp build_cost_map(params) do
    %{}
    |> maybe_put_cost("input", params["price_input"])
    |> maybe_put_cost("output", params["price_output"])
    |> maybe_put_cost("cache_read", params["price_cache_read"])
    |> maybe_put_cost("cache_write", params["price_cache_write"])
    |> maybe_put_cost("reasoning", params["price_reasoning"])
  end

  defp maybe_put_cost(costs, _key, nil), do: costs

  defp maybe_put_cost(costs, key, value) do
    case parse_float(value) do
      nil -> costs
      number -> Map.put(costs, key, number)
    end
  end

  defp maybe_drop_empty_cost(%{"cost" => cost} = model) when map_size(cost) == 0,
    do: Map.delete(model, "cost")

  defp maybe_drop_empty_cost(model), do: model

  defp maybe_put_reasoning(model, params, model_id) do
    if truthy?(params["reasoning"]) do
      fields =
        Reasoning.catalog_fields(
          %{id: model_id, provider_id: params["provider_id"] || params["id"]},
          selected_reasoning_levels(params)
        )

      Map.merge(model, fields)
    else
      model
    end
  end

  defp selected_reasoning_levels(params) do
    params
    |> Map.get("reasoning_levels", [])
    |> List.wrap()
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  defp truthy?(value) when value in [true, "true", "on", "1"], do: true
  defp truthy?(_value), do: false

  defp put_default(form, _key, nil, _force?), do: form
  defp put_default(form, key, value, true), do: Map.put(form, key, value)

  defp put_default(form, key, value, false) do
    case Map.get(form, key) do
      nil -> Map.put(form, key, value)
      "" -> Map.put(form, key, value)
      _existing -> form
    end
  end

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value) when is_binary(value), do: value
  defp to_string_or_nil(value), do: to_string(value)

  defp present_or(value, fallback) when is_binary(value) do
    if String.trim(value) == "", do: fallback, else: value
  end

  defp present_or(nil, fallback), do: fallback
  defp present_or(value, _fallback), do: value

  defp parse_int(string, default) when is_binary(string) do
    case Integer.parse(String.trim(string)) do
      {integer, _} -> integer
      :error -> default
    end
  end

  defp parse_int(nil, default), do: default
  defp parse_int(integer, _default) when is_integer(integer), do: integer

  defp parse_float(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, ""} -> number
      {number, _rest} -> number
      :error -> nil
    end
  end

  defp parse_float(value) when is_integer(value), do: :erlang.float(value)
  defp parse_float(value) when is_float(value), do: value
end
