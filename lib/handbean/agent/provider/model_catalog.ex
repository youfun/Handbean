defmodule Handbean.Agent.Provider.ModelCatalog do
  @moduledoc """
  Pulls an OpenAI-compatible `GET /v1/models` list into one provider.

  Chat Completions bases already end in `/v1`, so the request is `{base}/models`.
  Responses bases do not, so the request is `{base}/v1/models`. An xAI
  subscription uses the same list with its OAuth transport key. Ollama Cloud
  uses `GET /api/tags`. OpenCode Go uses `GET /v1/models` with the Handbean
  user agent. Anthropic, Codex, and Cursor keep their own catalogs.

  The provider response is the first source of truth. Its full model object is
  persisted under `upstream`, while known fields are projected into Handbean's
  stable catalog shape. Exact bundled/llm_db data only fills fields the
  provider omitted.

  Refresh replaces upstream facts and preserves the local `enabled` choice.
  Remote ids that disappear stay in the catalog and are marked unavailable, so
  an open conversation does not lose its model. An empty or failed response
  never replaces the saved list.
  """

  alias Handbean.Agent.ModelConfig
  alias Handbean.Agent.Provider.Ollama.Models, as: OllamaModels
  alias Handbean.Agent.Provider.OpenCodeGo.Models, as: OpenCodeGoModels
  alias Handbean.Agent.Provider.Xai.Models, as: XaiModels
  alias Handbean.LlmDbDefaults

  @fetchable_apis ~w(openai openai-responses openai-chat-completions openai-compatible custom)
  @receive_timeout 15_000
  @reasoning_levels ~w(none minimal low medium high xhigh max ultra)

  @spec fetchable?(map()) :: boolean()
  def fetchable?(%{"authType" => "oauth"} = provider), do: XaiModels.remote_catalog?(provider)

  def fetchable?(provider) do
    compatible_catalog?(provider) or OllamaModels.remote_catalog?(provider) or
      OpenCodeGoModels.remote_catalog?(provider)
  end

  defp compatible_catalog?(%{"api" => api, "baseUrl" => base_url})
       when api in @fetchable_apis and is_binary(base_url) and base_url != "",
       do: true

  defp compatible_catalog?(_provider), do: false

  @spec discover(String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def discover(provider_id, opts \\ []) when is_binary(provider_id) do
    with {:ok, config} <- ModelConfig.read_config(),
         {:ok, provider} <- fetch_provider(config, provider_id) do
      cond do
        XaiModels.remote_catalog?(provider) ->
          XaiModels.discover(provider_id, provider, opts)

        OllamaModels.remote_catalog?(provider) ->
          OllamaModels.discover(provider_id, provider, opts)

        OpenCodeGoModels.remote_catalog?(provider) ->
          OpenCodeGoModels.discover(provider_id, provider, opts)

        true ->
          discover_compatible(provider_id, provider, opts)
      end
    end
  end

  defp discover_compatible(provider_id, provider, opts) do
    with :ok <- ensure_fetchable(provider),
         {:ok, url, api_key} <- request_target(provider),
         {:ok, remote} <- fetch_remote(url, api_key, provider, opts) do
      models = merge(Map.get(provider, "models", []), remote)
      :ok = ModelConfig.update_provider(provider_id, %{"models" => models})
      {:ok, %{added: added_count(provider, remote), total: length(models)}}
    end
  end

  @spec models_url(String.t(), String.t()) :: String.t()
  def models_url(base_url, api) when is_binary(base_url) do
    base = String.trim_trailing(base_url, "/")

    cond do
      String.ends_with?(base, "/models") ->
        base

      api in ["openai", "openai-responses"] ->
        base
        |> String.replace_suffix("/v1/responses", "")
        |> String.replace_suffix("/v1", "")
        |> Kernel.<>("/v1/models")

      true ->
        base <> "/models"
    end
  end

  @doc """
  Refresh a persisted model list from normalized upstream rows.

  Upstream facts replace the previous row. Only `enabled` is local state and
  survives a refresh. Missing rows are marked unavailable by default; account-
  scoped subscription catalogs may pass `missing: :drop`.
  """
  @spec refresh_merge([map()], [map()], keyword()) :: [map()]
  def refresh_merge(existing, remote, opts \\ []) when is_list(existing) and is_list(remote) do
    existing_by_id =
      Map.new(existing, fn
        %{"id" => id} = model when is_binary(id) -> {id, model}
        model -> {nil, model}
      end)

    remote_ids = MapSet.new(remote, & &1["id"])

    discovered =
      Enum.map(remote, fn remote_model ->
        case Map.get(existing_by_id, remote_model["id"]) do
          nil ->
            remote_model

          existing ->
            remote_model
            |> preserve_enabled(existing)
            |> Map.delete("unavailable")
        end
      end)

    kept = missing_models(existing, remote_ids, Keyword.get(opts, :missing, :mark_unavailable))

    discovered ++ kept
  end

  @doc "Backward-compatible name for catalogs that retain missing rows."
  @spec merge([map()], [map()]) :: [map()]
  def merge(existing, remote), do: refresh_merge(existing, remote)

  @doc """
  Persist one raw provider model and project explicitly reported common fields.

  `fallback` may contain exact catalog data for fields absent in `raw`. An
  upstream value always wins, including explicit `false` capability values.
  """
  @spec normalize_entry(map(), map()) :: map()
  def normalize_entry(raw, fallback \\ %{}) when is_map(raw) and is_map(fallback) do
    id = raw["id"] || raw["slug"] || fallback["id"]

    fallback
    |> clear_upstream_owned_fallbacks(raw)
    |> Map.put("id", id)
    |> maybe_put("name", remote_name(raw))
    |> maybe_put("input", explicit_input(raw))
    |> maybe_put("output", explicit_output(raw))
    |> maybe_put("contextWindow", provider_limit(raw, context_keys()))
    |> maybe_put("maxTokens", provider_limit(raw, output_limit_keys()))
    |> maybe_put("cost", explicit_cost(raw))
    |> overlay_reasoning(raw)
    |> Map.put("upstream", Handbean.Agent.Provider.stringify_keys(raw))
  end

  @doc "Attach a JSON-safe upstream snapshot to an already normalized row."
  @spec put_upstream(map(), term()) :: map()
  def put_upstream(model, upstream) when is_map(model) do
    Map.put(model, "upstream", Handbean.Agent.Provider.stringify_keys(upstream))
  end

  defp fetch_provider(config, provider_id) do
    case get_in(config, ["providers", provider_id]) do
      %{} = provider -> {:ok, provider}
      _ -> {:error, "Provider '#{provider_id}' does not exist"}
    end
  end

  defp ensure_fetchable(provider) do
    if fetchable?(provider) do
      :ok
    else
      {:error, "This provider does not expose an OpenAI-compatible model list"}
    end
  end

  defp request_target(provider) do
    api = provider["api"]
    base_url = provider["baseUrl"]

    case resolve_api_key(provider) do
      key when is_binary(key) and key != "" ->
        {:ok, models_url(base_url, api), key}

      _ ->
        {:error, "API key is not configured"}
    end
  end

  defp resolve_api_key(%{"apiKey" => "env:" <> var}) do
    System.get_env(var)
  end

  defp resolve_api_key(%{"apiKey" => key}) when is_binary(key), do: key
  defp resolve_api_key(_provider), do: nil

  defp fetch_remote(url, api_key, provider, opts) do
    req = Keyword.get(opts, :req_module, Req)

    case req.get(url,
           headers: [
             {"authorization", "Bearer #{api_key}"},
             {"accept", "application/json"}
           ],
           retry: false,
           redirect: false,
           receive_timeout: @receive_timeout,
           connect_options: [timeout: @receive_timeout],
           inet6: true
         ) do
      {:ok, %{status: 200, body: body}} ->
        parse_models(body, provider, opts)

      {:ok, %{status: status}} ->
        {:error, "Model list request failed (HTTP #{status}). The existing list was kept."}

      {:error, _reason} ->
        {:error, "Model list is unavailable. The existing list was kept."}
    end
  end

  defp parse_models(%{"data" => data}, provider, opts) when is_list(data) do
    entries =
      data
      |> Enum.flat_map(fn
        %{"id" => id} = model when is_binary(id) and id != "" ->
          [{id, model["name"] || model["display_name"], model}]

        _ ->
          []
      end)
      |> Enum.uniq_by(&elem(&1, 0))

    llm_db_load = Keyword.get(opts, :llm_db_load)

    fallback_provider_id =
      if is_function(llm_db_load, 0) do
        LlmDbDefaults.resolve_provider_id(
          provider["provider"],
          provider["name"],
          provider["baseUrl"],
          llm_db_load
        )
      else
        LlmDbDefaults.resolve_provider_id(
          provider["provider"],
          provider["name"],
          provider["baseUrl"]
        )
      end

    enrichment_load = if is_function(llm_db_load, 0), do: llm_db_load, else: fn -> :ok end

    enrichment_opts =
      [
        provider_id: fallback_provider_id,
        api: provider["api"],
        provider_scoped: true,
        load: enrichment_load
      ]

    enriched =
      entries
      |> Enum.map(fn {id, name, _raw} -> {id, name} end)
      |> LlmDbDefaults.enrich_models(enrichment_opts)

    models =
      Enum.map(entries, fn {id, _name, raw} ->
        normalize_entry(raw, Map.fetch!(enriched, id))
      end)

    case models do
      [] -> {:error, "The provider returned no models. The existing list was kept."}
      models -> {:ok, models}
    end
  end

  defp parse_models(body, provider, opts) when is_binary(body) do
    case Handbean.JSON.decode(body) do
      {:ok, decoded} -> parse_models(decoded, provider, opts)
      _ -> {:error, "The provider returned an unreadable model list. The existing list was kept."}
    end
  end

  defp parse_models(_body, _provider, _opts) do
    {:error, "The provider returned an unreadable model list. The existing list was kept."}
  end

  defp explicit_input(model) do
    modalities =
      model["input"] ||
        model["input_modalities"] ||
        get_in(model, ["architecture", "input_modalities"])

    normalize_input(modalities)
  end

  defp normalize_input(modalities) when is_list(modalities) do
    normalized =
      modalities
      |> Enum.flat_map(fn
        modality when is_binary(modality) -> [String.downcase(modality)]
        _ -> []
      end)
      |> Enum.uniq()

    case normalized do
      [] ->
        nil

      modalities ->
        Enum.filter(
          Handbean.Agent.ModelCapabilities.supported_input_types(),
          &(&1 in modalities)
        )
    end
  end

  defp normalize_input(_modalities), do: nil

  defp explicit_output(model) do
    model["output"] || model["output_modalities"] ||
      get_in(model, ["architecture", "output_modalities"])
  end

  defp remote_name(model), do: model["display_name"] || model["name"]

  defp clear_upstream_owned_fallbacks(fallback, raw) do
    fallback
    |> maybe_delete_if(raw, "input", ["input", "input_modalities"], [
      ["architecture", "input_modalities"]
    ])
    |> maybe_delete_if(raw, "output", ["output", "output_modalities"], [
      ["architecture", "output_modalities"]
    ])
    |> maybe_delete_if(raw, "cost", ["cost", "pricing", "pricings"], [])
    |> clear_declared_reasoning_levels(raw)
  end

  defp clear_declared_reasoning_levels(model, raw) do
    capabilities = if is_map(raw["capabilities"]), do: raw["capabilities"], else: %{}

    declared? =
      Enum.any?(["reasoning_levels", "supported_reasoning_levels"], &Map.has_key?(raw, &1)) or
        Enum.any?(["reasoning_effort", "reasoning_levels"], &Map.has_key?(capabilities, &1)) or
        match?(%{"effort" => _}, capabilities["reasoning"])

    if declared? do
      model
      |> Map.delete("reasoningLevels")
      |> Map.delete("thinkingLevelMap")
    else
      model
    end
  end

  defp maybe_delete_if(model, raw, key, direct_keys, nested_paths) do
    present? =
      Enum.any?(direct_keys, &Map.has_key?(raw, &1)) or
        Enum.any?(nested_paths, &(not is_nil(get_in(raw, &1))))

    if present?, do: Map.delete(model, key), else: model
  end

  defp explicit_cost(%{"cost" => cost}) when is_map(cost), do: cost

  defp explicit_cost(%{"pricings" => pricings}) when is_map(pricings) do
    %{}
    |> maybe_put_price("input", pricings["prompt"])
    |> maybe_put_price("output", pricings["completion"])
    |> maybe_put_price("cacheRead", pricings["input_cache_read"])
    |> maybe_put_price("cacheWrite", pricings["input_cache_write"])
    |> case do
      cost when map_size(cost) == 0 -> nil
      cost -> cost
    end
  end

  defp explicit_cost(_raw), do: nil

  defp maybe_put_price(cost, key, prices) when is_list(prices) do
    values =
      prices
      |> Enum.flat_map(fn
        %{"value" => value, "unit" => "perMTokens"} when is_number(value) -> [value]
        _ -> []
      end)

    if values == [], do: cost, else: Map.put(cost, key, Enum.max(values))
  end

  defp maybe_put_price(cost, _key, _prices), do: cost

  defp overlay_reasoning(model, raw) do
    capabilities = if is_map(raw["capabilities"]), do: raw["capabilities"], else: %{}
    reasoning = explicit_reasoning(raw, capabilities)
    levels = explicit_reasoning_levels(raw, capabilities)
    default = explicit_default_reasoning(raw, capabilities)

    model
    |> maybe_put("reasoning", reasoning)
    |> maybe_put("reasoningLevels", levels)
    |> maybe_put("defaultReasoning", default)
    |> drop_stale_reasoning_fields(reasoning)
    |> reconcile_reasoning_default()
  end

  defp explicit_reasoning(raw, capabilities) do
    cond do
      is_boolean(capabilities["reasoning"]) -> capabilities["reasoning"]
      is_map(capabilities["reasoning"]) -> capabilities["reasoning"]["enabled"]
      is_boolean(raw["reasoning"]) -> raw["reasoning"]
      explicit_reasoning_levels(raw, capabilities) not in [nil, []] -> true
      true -> nil
    end
  end

  defp explicit_reasoning_levels(raw, capabilities) do
    reasoning = capabilities["reasoning"]
    nested_efforts = if is_map(reasoning), do: get_in(reasoning, ["effort", "values"])

    levels =
      raw["reasoning_levels"] ||
        raw["supported_reasoning_levels"] ||
        capabilities["reasoning_effort"] ||
        capabilities["reasoning_levels"] ||
        nested_efforts

    normalize_reasoning_levels(levels)
  end

  defp explicit_default_reasoning(raw, capabilities) do
    reasoning = capabilities["reasoning"]
    nested_default = if is_map(reasoning), do: get_in(reasoning, ["effort", "default"])

    raw["default_reasoning_level"] ||
      raw["default_reasoning_effort"] ||
      capabilities["default_reasoning_level"] ||
      capabilities["default_reasoning_effort"] ||
      nested_default
  end

  defp normalize_reasoning_levels(levels) when is_list(levels) do
    normalized =
      levels
      |> Enum.flat_map(fn
        level when is_binary(level) -> [String.downcase(level)]
        %{"effort" => level} when is_binary(level) -> [String.downcase(level)]
        _ -> []
      end)
      |> Enum.filter(&(&1 in @reasoning_levels))
      |> Enum.uniq()

    if normalized == [], do: nil, else: normalized
  end

  defp normalize_reasoning_levels(_levels), do: nil

  defp drop_stale_reasoning_fields(model, false) do
    model
    |> Map.put("reasoning", false)
    |> Map.delete("reasoningLevels")
    |> Map.delete("defaultReasoning")
    |> Map.delete("thinkingLevelMap")
  end

  defp drop_stale_reasoning_fields(model, _reasoning), do: model

  defp reconcile_reasoning_default(model) do
    levels = model["reasoningLevels"]
    default = model["defaultReasoning"]

    cond do
      is_nil(default) -> model
      is_list(levels) and default in levels -> model
      true -> Map.delete(model, "defaultReasoning")
    end
  end

  defp context_keys,
    do: ["context_length", "context_window", "max_context_length", "contextWindow"]

  defp output_limit_keys,
    do: ["max_tokens", "max_output_tokens", "max_completion_tokens", "maxTokens"]

  defp provider_limit(map, keys) do
    first_positive_integer(map, keys) || first_positive_integer(map["top_provider"] || %{}, keys)
  end

  defp first_positive_integer(map, keys) do
    Enum.find_value(keys, fn key -> positive_integer(map[key]) end)
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp preserve_enabled(model, %{"enabled" => enabled}) when is_boolean(enabled),
    do: Map.put(model, "enabled", enabled)

  defp preserve_enabled(model, _existing), do: model

  defp missing_models(_existing, _remote_ids, :drop), do: []

  defp missing_models(existing, remote_ids, :mark_unavailable) do
    Enum.flat_map(existing, fn
      %{"id" => id} = model when is_binary(id) ->
        if MapSet.member?(remote_ids, id), do: [], else: [Map.put(model, "unavailable", true)]

      _ ->
        []
    end)
  end

  defp added_count(provider, remote) do
    existing = MapSet.new(Map.get(provider, "models", []), & &1["id"])
    Enum.count(remote, &(not MapSet.member?(existing, &1["id"])))
  end
end
