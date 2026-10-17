defmodule Handbean.Agent.Provider.Ollama.Models do
  @moduledoc """
  Pulls the Ollama Cloud catalog from `GET /api/tags`.

  The OpenAI `/v1/models` list only has ids. Tags also reports vision and
  thinking, which the chat picker needs. Completion models stay; decision-only
  models do not. A failed list never replaces the saved rows. Re-pulling
  refreshes capabilities and keeps a custom name and enabled flag.
  """

  alias Handbean.Agent.ModelConfig
  alias Handbean.LlmDbDefaults

  @receive_timeout 15_000

  @spec remote_catalog?(map()) :: boolean()
  def remote_catalog?(%{"api" => "ollama-cloud", "baseUrl" => base_url})
      when is_binary(base_url) and base_url != "",
      do: true

  def remote_catalog?(_provider), do: false

  @spec discover(String.t(), map(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def discover(provider_id, provider, opts \\ [])
      when is_binary(provider_id) and is_map(provider) do
    with {:ok, listed} <- fetch_tags(tags_url(provider["baseUrl"]), api_key(provider), opts),
         {:ok, remote} <- catalog(listed) do
      models = refresh_merge(Map.get(provider, "models", []), remote)
      :ok = ModelConfig.update_provider(provider_id, %{"models" => models})
      {:ok, %{added: added_count(provider, remote), total: length(models)}}
    end
  end

  @doc "Builds catalog rows from an `/api/tags` body."
  @spec catalog(term()) :: {:ok, [map()]} | {:error, String.t()}
  def catalog(body) do
    with {:ok, models} <- decode_models(body) do
      entries =
        models
        |> Enum.flat_map(&entry/1)
        |> Enum.uniq_by(&elem(&1, 0))

      enriched =
        entries
        |> Enum.map(fn {id, _input, _reasoning} -> {id, id} end)
        |> LlmDbDefaults.enrich_models()

      built =
        Enum.map(entries, fn {id, input, reasoning} ->
          enriched
          |> Map.fetch!(id)
          |> Map.put("input", input)
          |> put_reasoning(reasoning)
        end)

      case built do
        [] -> {:error, "The provider returned no models. The existing list was kept."}
        models -> {:ok, models}
      end
    end
  end

  @spec tags_url(String.t()) :: String.t()
  def tags_url(base_url) when is_binary(base_url) do
    origin =
      base_url
      |> String.trim()
      |> String.trim_trailing("/")
      |> String.replace_suffix("/v1", "")
      |> String.replace_suffix("/api", "")

    origin <> "/api/tags"
  end

  defp fetch_tags(url, api_key, opts) do
    req = Keyword.get(opts, :req_module, Req)

    case req.get(url,
           headers: headers(api_key),
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

  defp headers(key) when is_binary(key) and key != "" do
    [{"authorization", "Bearer #{key}"}, {"accept", "application/json"}]
  end

  defp headers(_key), do: [{"accept", "application/json"}]

  defp api_key(%{"apiKey" => "env:" <> var}), do: System.get_env(var)
  defp api_key(%{"apiKey" => key}) when is_binary(key), do: key
  defp api_key(_provider), do: nil

  defp decode_models(%{"models" => models}) when is_list(models), do: {:ok, models}

  defp decode_models(body) when is_binary(body) do
    case Handbean.JSON.decode(body) do
      {:ok, decoded} -> decode_models(decoded)
      _ -> {:error, "The provider returned an unreadable model list. The existing list was kept."}
    end
  end

  defp decode_models(_body) do
    {:error, "The provider returned an unreadable model list. The existing list was kept."}
  end

  defp entry(%{"name" => name} = model) when is_binary(name) and name != "" do
    capabilities = model["capabilities"] || []

    if is_list(capabilities) and "completion" in capabilities do
      [{name, input(capabilities), "thinking" in capabilities}]
    else
      []
    end
  end

  defp entry(%{"model" => name} = model) when is_binary(name) and name != "" do
    entry(Map.put(model, "name", name))
  end

  defp entry(_model), do: []

  defp input(capabilities) do
    if "vision" in capabilities, do: ["text", "image"], else: ["text"]
  end

  defp put_reasoning(model, true), do: Map.put(model, "reasoning", true)

  defp put_reasoning(model, false) do
    model
    |> Map.put("reasoning", false)
    |> Map.delete("reasoningLevels")
    |> Map.delete("defaultReasoning")
    |> Map.delete("thinkingLevelMap")
  end

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
            merged =
              existing
              |> Map.merge(remote_model)
              |> Map.put("id", remote_model["id"])
              |> Map.put("name", existing["name"] || remote_model["name"])
              |> Map.delete("unavailable")
              |> drop_reasoning_fields(remote_model["reasoning"])

            case Map.fetch(existing, "enabled") do
              {:ok, enabled} -> Map.put(merged, "enabled", enabled)
              :error -> Map.delete(merged, "enabled")
            end
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

  defp drop_reasoning_fields(model, true), do: model

  defp drop_reasoning_fields(model, _reasoning) do
    model
    |> Map.delete("reasoningLevels")
    |> Map.delete("defaultReasoning")
    |> Map.delete("thinkingLevelMap")
  end

  defp added_count(provider, remote) do
    existing = MapSet.new(Map.get(provider, "models", []), & &1["id"])
    Enum.count(remote, &(not MapSet.member?(existing, &1["id"])))
  end
end
