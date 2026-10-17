defmodule Handbeam.Agent.Provider.ModelCatalog do
  @moduledoc """
  Pulls an OpenAI-compatible `GET /v1/models` list into one provider.

  Chat Completions bases already end in `/v1`, so the request is `{base}/models`.
  Responses bases do not, so the request is `{base}/v1/models`. An xAI
  subscription uses the same list with its OAuth transport key. Ollama Cloud
  uses `GET /api/tags`. Anthropic, Codex, and Cursor keep their own catalogs.

  Existing rows keep custom names, enabled flags, and hand-edited limits.
  Missing llm_db fields are filled. Remote ids that disappear stay in the
  catalog and are marked unavailable, so an open conversation does not lose
  its model. An empty or failed response never replaces the saved list.
  """

  alias Handbeam.Agent.ModelConfig
  alias Handbeam.Agent.Provider.Ollama.Models, as: OllamaModels
  alias Handbeam.Agent.Provider.Xai.Models, as: XaiModels
  alias Handbeam.LlmDbDefaults

  @fetchable_apis ~w(openai openai-responses openai-chat-completions openai-compatible custom)
  @receive_timeout 15_000

  @spec fetchable?(map()) :: boolean()
  def fetchable?(%{"authType" => "oauth"} = provider), do: XaiModels.remote_catalog?(provider)

  def fetchable?(provider),
    do: compatible_catalog?(provider) or OllamaModels.remote_catalog?(provider)

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

        true ->
          discover_compatible(provider_id, provider, opts)
      end
    end
  end

  defp discover_compatible(provider_id, provider, opts) do
    with :ok <- ensure_fetchable(provider),
         {:ok, url, api_key} <- request_target(provider),
         {:ok, remote} <- fetch_remote(url, api_key, opts) do
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

  @spec merge([map()], [map()]) :: [map()]
  def merge(existing, remote) when is_list(existing) and is_list(remote) do
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
            existing
            |> Map.merge(remote_model, fn _key, current, incoming ->
              prefer_existing(current, incoming)
            end)
            |> Map.put("id", remote_model["id"])
            |> Map.delete("unavailable")
        end
      end)

    kept =
      Enum.flat_map(existing, fn
        %{"id" => id} = model when is_binary(id) ->
          if MapSet.member?(remote_ids, id), do: [], else: [Map.put(model, "unavailable", true)]

        _ ->
          []
      end)

    discovered ++ kept
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

  defp fetch_remote(url, api_key, opts) do
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
        parse_models(body)

      {:ok, %{status: status}} ->
        {:error, "Model list request failed (HTTP #{status}). The existing list was kept."}

      {:error, _reason} ->
        {:error, "Model list is unavailable. The existing list was kept."}
    end
  end

  defp parse_models(%{"data" => data}) when is_list(data) do
    entries =
      data
      |> Enum.flat_map(fn
        %{"id" => id} = model when is_binary(id) and id != "" ->
          [{id, model["name"] || model["display_name"], explicit_input(model)}]

        _ ->
          []
      end)
      |> Enum.uniq_by(&elem(&1, 0))

    enriched =
      entries
      |> Enum.map(fn {id, name, _input} -> {id, name} end)
      |> LlmDbDefaults.enrich_models()

    models =
      Enum.map(entries, fn {id, _name, input} ->
        enriched |> Map.fetch!(id) |> maybe_put_input(input)
      end)

    case models do
      [] -> {:error, "The provider returned no models. The existing list was kept."}
      models -> {:ok, models}
    end
  end

  defp parse_models(body) when is_binary(body) do
    case Handbeam.JSON.decode(body) do
      {:ok, decoded} -> parse_models(decoded)
      _ -> {:error, "The provider returned an unreadable model list. The existing list was kept."}
    end
  end

  defp parse_models(_body) do
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
      |> Enum.filter(&(&1 in ["text", "image"]))
      |> Enum.uniq()

    case normalized do
      [] -> nil
      modalities -> ["text" | Enum.reject(modalities, &(&1 == "text"))]
    end
  end

  defp normalize_input(_modalities), do: nil

  defp maybe_put_input(model, nil), do: model
  defp maybe_put_input(model, input), do: Map.put(model, "input", input)

  defp prefer_existing(existing, remote) when existing in [nil, "", []], do: remote
  defp prefer_existing(existing, _remote), do: existing

  defp added_count(provider, remote) do
    existing = MapSet.new(Map.get(provider, "models", []), & &1["id"])
    Enum.count(remote, &(not MapSet.member?(existing, &1["id"])))
  end
end
