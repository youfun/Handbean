defmodule Handbean.Agent.Provider.OpenCodeGo.Models do
  @moduledoc """
  Pulls the OpenCode Go catalog from `GET /v1/models`.

  That list is the subscription catalog and its model objects are persisted as
  upstream facts. It is not a Handbean price table. Requests send the Handbean
  user agent. A failed or empty response never replaces the saved rows. Re-
  pulling refreshes upstream facts and keeps only the local enabled choice.
  """

  alias Handbean.Agent.ModelConfig
  alias Handbean.Agent.Provider.ModelCatalog
  alias Handbean.Agent.Provider.RequestIdentity
  alias Handbean.LlmDbDefaults

  @receive_timeout 15_000

  @spec remote_catalog?(map()) :: boolean()
  def remote_catalog?(%{"api" => "opencode-go", "baseUrl" => base_url})
      when is_binary(base_url) and base_url != "",
      do: true

  def remote_catalog?(_provider), do: false

  @spec discover(String.t(), map(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def discover(provider_id, provider, opts \\ [])
      when is_binary(provider_id) and is_map(provider) do
    with {:ok, key} <- api_key(provider),
         {:ok, listed} <- fetch(models_url(provider["baseUrl"]), key, opts),
         {:ok, remote} <- catalog(listed) do
      models = ModelCatalog.merge(Map.get(provider, "models", []), remote)
      :ok = ModelConfig.update_provider(provider_id, %{"models" => models})
      {:ok, %{added: added_count(provider, remote), total: length(models)}}
    end
  end

  @doc "OpenCode Go model list for a saved base URL."
  @spec models_url(String.t()) :: String.t()
  def models_url(base_url) when is_binary(base_url) do
    base =
      base_url
      |> String.trim()
      |> String.trim_trailing("/")

    if String.ends_with?(base, "/models"), do: base, else: base <> "/models"
  end

  @doc "Builds catalog rows from an OpenAI-style `{data: [%{id}]}` body."
  @spec catalog(term()) :: {:ok, [map()]} | {:error, String.t()}
  def catalog(body) do
    with {:ok, data} <- decode(body) do
      entries =
        data
        |> Enum.flat_map(fn
          %{"id" => id} = model when is_binary(id) and id != "" -> [{id, model}]
          _model -> []
        end)
        |> Enum.uniq_by(&elem(&1, 0))

      enriched =
        entries
        |> Enum.map(fn {id, _model} -> {id, id} end)
        |> LlmDbDefaults.enrich_models()

      models =
        Enum.map(entries, fn {id, raw} ->
          ModelCatalog.normalize_entry(raw, Map.fetch!(enriched, id))
        end)

      case models do
        [] -> {:error, "The provider returned no models. The existing list was kept."}
        models -> {:ok, models}
      end
    end
  end

  defp fetch(url, api_key, opts) do
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

  defp headers(api_key) do
    [
      {"authorization", "Bearer #{api_key}"},
      {"accept", "application/json"},
      {"user-agent", RequestIdentity.user_agent()}
    ]
  end

  defp api_key(%{"apiKey" => "env:" <> var}) do
    case System.get_env(var) do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, "API key is not configured"}
    end
  end

  defp api_key(%{"apiKey" => key}) when is_binary(key) and key != "", do: {:ok, key}
  defp api_key(_provider), do: {:error, "API key is not configured"}

  defp decode(%{"data" => data}) when is_list(data), do: {:ok, data}

  defp decode(body) when is_binary(body) do
    case Handbean.JSON.decode(body) do
      {:ok, decoded} -> decode(decoded)
      _ -> {:error, "The provider returned an unreadable model list. The existing list was kept."}
    end
  end

  defp decode(_body) do
    {:error, "The provider returned an unreadable model list. The existing list was kept."}
  end

  defp added_count(provider, remote) do
    existing = MapSet.new(Map.get(provider, "models", []), & &1["id"])
    Enum.count(remote, &(not MapSet.member?(existing, &1["id"])))
  end
end
