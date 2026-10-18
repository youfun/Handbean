defmodule Handbean.Agent.Provider.Xai.Models do
  @moduledoc """
  Pulls the signed-in xAI account's model list.

  `GET /v1/models` is the OpenAI-compatible catalog: ids, context length, and
  per-token prices. `GET /v1/language-models` narrows that list to chat and
  image-understanding models and supplies input modalities. Image, video, and
  voice models stay out of the coding picker.

  Prices are the vendor's short-context rates, converted from USD cents per
  100 million tokens to dollars per million tokens. A failed list never
  replaces the saved rows. Re-pulling refreshes vendor fields and keeps a
  custom name and enabled flag.
  """

  alias Handbean.Agent.Auth.XaiCredential
  alias Handbean.Agent.ModelConfig
  alias Handbean.LlmDbDefaults

  @receive_timeout 15_000
  @vendor_keys ~w(contextWindow maxTokens cost input reasoning defaultReasoning thinkingLevelMap)
  @compatible_apis ~w(openai openai-responses openai-chat-completions openai-compatible custom)

  @spec remote_catalog?(map()) :: boolean()
  def remote_catalog?(%{"api" => api, "baseUrl" => base_url}) when api in @compatible_apis do
    xai_host?(base_url)
  end

  def remote_catalog?(_provider), do: false

  @spec discover(String.t(), map(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def discover(provider_id, provider, opts \\ [])
      when is_binary(provider_id) and is_map(provider) do
    with {:ok, url, api_key} <- request_target(provider_id, provider, opts),
         {:ok, listed} <- get_json(url, api_key, opts),
         language = language_list(url, api_key, opts),
         {:ok, remote} <- catalog(listed, language) do
      models = refresh_merge(Map.get(provider, "models", []), remote)
      :ok = ModelConfig.update_provider(provider_id, %{"models" => models})
      {:ok, %{added: added_count(provider, remote), total: length(models)}}
    end
  end

  @doc """
  Builds catalog rows from a models-list body and an optional language-list body.

  Pass `:unavailable` when the language list could not be fetched. Text-priced
  rows from `/v1/models` are kept in that case.
  """
  @spec catalog(term(), term()) :: {:ok, [map()]} | {:error, String.t()}
  def catalog(models_body, language_body) do
    with {:ok, listed} <- decode_models(models_body) do
      by_id = Map.new(listed, &{&1["id"], &1})

      entries =
        case decode_language(language_body) do
          {:ok, language_models} ->
            Enum.map(language_models, fn model ->
              Map.merge(Map.get(by_id, model["id"], %{}), model)
            end)

          :unavailable ->
            Enum.filter(listed, &text_model?/1)
        end

      build(entries)
    end
  end

  defp request_target(provider_id, %{"authType" => "oauth"} = provider, opts) do
    oauth_opts = Keyword.take(opts, [:req_module, :now_ms])

    case XaiCredential.resolve_transport_key(provider_id, oauth_opts) do
      {:ok, %{api_key: key}} when is_binary(key) and key != "" ->
        {:ok, models_url(provider), key}

      {:error, message} when is_binary(message) ->
        {:error, message}

      _ ->
        {:error, "Sign in with SuperGrok or X Premium to connect xAI."}
    end
  end

  defp request_target(_provider_id, provider, _opts) do
    case resolve_api_key(provider) do
      key when is_binary(key) and key != "" ->
        {:ok, models_url(provider), key}

      _ ->
        {:error, "API key is not configured"}
    end
  end

  defp models_url(provider) do
    Handbean.Agent.Provider.ModelCatalog.models_url(provider["baseUrl"], provider["api"])
  end

  defp resolve_api_key(%{"apiKey" => "env:" <> var}), do: System.get_env(var)
  defp resolve_api_key(%{"apiKey" => key}) when is_binary(key), do: key
  defp resolve_api_key(_provider), do: nil

  defp language_list(models_url, api_key, opts) do
    case get_json(language_url(models_url), api_key, opts) do
      {:ok, body} -> body
      _ -> :unavailable
    end
  end

  defp language_url(models_url) do
    String.replace_suffix(models_url, "/models", "/language-models")
  end

  defp get_json(url, api_key, opts) do
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
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, "Model list request failed (HTTP #{status}). The existing list was kept."}

      {:error, _reason} ->
        {:error, "Model list is unavailable. The existing list was kept."}
    end
  end

  defp decode_models(%{"data" => data}) when is_list(data) do
    {:ok, Enum.filter(data, &is_map/1)}
  end

  defp decode_models(body) when is_binary(body) do
    case Handbean.JSON.decode(body) do
      {:ok, decoded} -> decode_models(decoded)
      _ -> {:error, "The provider returned an unreadable model list. The existing list was kept."}
    end
  end

  defp decode_models(_body) do
    {:error, "The provider returned an unreadable model list. The existing list was kept."}
  end

  defp decode_language(:unavailable), do: :unavailable

  defp decode_language(%{"models" => models}) when is_list(models) do
    {:ok, Enum.filter(models, &is_map/1)}
  end

  defp decode_language(body) when is_binary(body) do
    case Handbean.JSON.decode(body) do
      {:ok, decoded} -> decode_language(decoded)
      _ -> :unavailable
    end
  end

  defp decode_language(_body), do: :unavailable

  defp build(entries) do
    entries =
      entries
      |> Enum.filter(fn
        %{"id" => id} when is_binary(id) and id != "" -> true
        _ -> false
      end)
      |> Enum.uniq_by(& &1["id"])

    case entries do
      [] ->
        {:error, "The provider returned no models. The existing list was kept."}

      entries ->
        enriched =
          entries
          |> Enum.map(&{&1["id"], nil})
          |> LlmDbDefaults.enrich_models()

        models =
          Enum.map(entries, fn entry ->
            enriched
            |> Map.fetch!(entry["id"])
            |> overlay(entry)
          end)

        {:ok, models}
    end
  end

  defp overlay(model, entry) do
    model
    |> maybe_put("contextWindow", positive_integer(entry["context_length"]))
    |> maybe_put("input", input_modalities(entry["input_modalities"]))
    |> put_prices(entry)
    |> Map.merge(reasoning_fields(entry["capabilities"]))
  end

  defp text_model?(%{"prompt_text_token_price" => price} = model) when is_integer(price) do
    is_nil(model["image_price"])
  end

  defp text_model?(_model), do: false

  defp input_modalities(modalities) when is_list(modalities) do
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

  defp input_modalities(_modalities), do: nil

  defp reasoning_fields(%{"reasoning_effort" => efforts} = capabilities) when is_list(efforts) do
    efforts = Enum.filter(efforts, &is_binary/1)

    if efforts == [] do
      %{"reasoning" => false}
    else
      %{
        "reasoning" => true,
        "thinkingLevelMap" => thinking_level_map(efforts)
      }
      |> maybe_put("defaultReasoning", default_effort(capabilities, efforts))
    end
  end

  defp reasoning_fields(_capabilities), do: %{}

  defp thinking_level_map(efforts) do
    ~w(none minimal low medium high xhigh max ultra)
    |> Map.new(fn level ->
      if level in efforts, do: {level, level}, else: {level, nil}
    end)
  end

  defp default_effort(capabilities, efforts) do
    case capabilities["default_reasoning_effort"] do
      effort when is_binary(effort) ->
        if effort in efforts, do: effort, else: nil

      _ ->
        nil
    end
  end

  defp put_prices(model, entry) do
    prices =
      %{}
      |> put_price("input", entry["prompt_text_token_price"])
      |> put_price("output", entry["completion_text_token_price"])
      |> put_price("cacheRead", entry["cached_prompt_text_token_price"])

    if prices == %{} do
      model
    else
      Map.put(model, "cost", Map.merge(Map.get(model, "cost") || %{}, prices))
    end
  end

  defp put_price(prices, _key, cents) when not is_integer(cents), do: prices
  defp put_price(prices, key, cents), do: Map.put(prices, key, cents / 10_000)

  defp refresh_merge(existing, remote) when is_list(existing) and is_list(remote) do
    existing_by_id =
      Map.new(existing, fn
        %{"id" => id} = model when is_binary(id) -> {id, model}
        _model -> {nil, nil}
      end)

    remote_ids = MapSet.new(remote, & &1["id"])

    discovered =
      Enum.map(remote, fn remote_model ->
        case Map.get(existing_by_id, remote_model["id"]) do
          nil ->
            remote_model

          existing ->
            existing
            |> Map.merge(Map.take(remote_model, @vendor_keys))
            |> Map.put("id", remote_model["id"])
            |> Map.put("name", existing["name"] || remote_model["name"])
            |> Map.delete("unavailable")
        end
      end)

    kept =
      Enum.flat_map(existing, fn
        %{"id" => id} = model when is_binary(id) ->
          if MapSet.member?(remote_ids, id), do: [], else: [Map.put(model, "unavailable", true)]

        _model ->
          []
      end)

    discovered ++ kept
  end

  defp refresh_merge(_existing, remote), do: remote

  defp added_count(provider, remote) do
    existing = MapSet.new(Map.get(provider, "models", []), & &1["id"])
    Enum.count(remote, &(not MapSet.member?(existing, &1["id"])))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil

  defp xai_host?(base_url) when is_binary(base_url) do
    URI.parse(base_url).host == "api.x.ai"
  end

  defp xai_host?(_base_url), do: false
end
