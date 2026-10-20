defmodule HandbeanWeb.AvailableModelsLive.Projection do
  @moduledoc false

  alias Handbean.Agent.ModelConfig
  alias Handbean.Agent.Provider.ModelCatalog
  alias Handbean.LlmDbDefaults

  def load_raw_config do
    path = ModelConfig.config_file_path()

    case File.read(path) do
      {:ok, content} ->
        case Handbean.JSON.decode(content) do
          {:ok, json} when is_map(json) -> json
          _ -> empty_config()
        end

      _ ->
        empty_config()
    end
  end

  def parse_providers(config) do
    providers = Map.get(config, "providers", %{})
    default = Map.get(config, "defaultProvider", "")

    Enum.map(providers, fn {id, provider_config} ->
      %{
        id: id,
        name: Map.get(provider_config, "name", display_name(id)),
        api: Map.get(provider_config, "api", ""),
        base_url: Map.get(provider_config, "baseUrl", ""),
        api_key: Map.get(provider_config, "apiKey", ""),
        auth_type: Map.get(provider_config, "authType", "api_key"),
        fetchable: ModelCatalog.fetchable?(provider_config),
        is_default: id == default,
        provider: Map.get(provider_config, "provider", id),
        models: Enum.map(Map.get(provider_config, "models", []), &project_model/1)
      }
    end)
  end

  def find_provider(id, providers), do: Enum.find(providers, &(&1.id == id))

  def maybe_reselect(current_id, providers) do
    if current_id && Enum.any?(providers, &(&1.id == current_id)) do
      current_id
    else
      providers |> List.first() |> then(&if(&1, do: &1.id))
    end
  end

  def stored_models(provider_id) do
    case load_raw_config() do
      %{"providers" => %{^provider_id => %{"models" => models}}} when is_list(models) -> models
      _ -> []
    end
  end

  def catalog_discover_opts do
    case Application.get_env(:handbean, :catalog_req_module) do
      module when is_atom(module) and not is_nil(module) -> [req_module: module]
      _ -> []
    end
  end

  def lookup_catalog_prices(ids), do: LlmDbDefaults.prices_for_model_ids(ids)

  def unpriced_model_ids(providers) do
    providers
    |> Enum.flat_map(& &1.models)
    |> Enum.filter(&(map_size(&1.cost) == 0))
    |> Enum.map(& &1.id)
    |> Enum.filter(&is_binary/1)
  end

  def apply_catalog_prices(providers, prices) do
    Enum.map(providers, fn provider ->
      models =
        Enum.map(provider.models, fn model ->
          case Map.get(prices, model.id) do
            %{} = cost when map_size(cost) > 0 and map_size(model.cost) == 0 ->
              %{model | cost: cost}

            _ ->
              model
          end
        end)

      %{provider | models: models}
    end)
  end

  def model_enabled?(providers, provider_id, model_id) do
    provider = find_provider(provider_id, providers)
    model = provider && Enum.find(provider.models, &(&1.id == model_id))
    (model && model.enabled) || false
  end

  def display_name(id), do: String.capitalize(id)

  defp project_model(model) do
    %{
      id: Map.get(model, "id", ""),
      name: Map.get(model, "name", ""),
      type: List.first(Map.get(model, "input", ["text"])) || "text",
      reasoning: Map.get(model, "reasoning") == true,
      reasoning_levels: Map.get(model, "reasoningLevels", []),
      default_reasoning: Map.get(model, "defaultReasoning"),
      thinking_level_map: Map.get(model, "thinkingLevelMap", %{}),
      context_window: Map.get(model, "contextWindow"),
      max_tokens: Map.get(model, "maxTokens"),
      cost: display_cost(model),
      enabled: Map.get(model, "enabled") != false
    }
  end

  defp display_cost(%{"cost" => cost}) when is_map(cost) and map_size(cost) > 0, do: cost
  defp display_cost(_), do: %{}

  defp empty_config, do: %{"defaultProvider" => "", "providers" => %{}}
end
