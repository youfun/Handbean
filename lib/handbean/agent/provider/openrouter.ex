defmodule Handbean.Agent.Provider.OpenRouter do
  @moduledoc """
  OpenRouter provider adapter.

  OpenRouter exposes an OpenAI-compatible Chat Completions API at
  `https://openrouter.ai/api/v1/chat/completions`, with provider-prefixed
  model ids such as `openai/gpt-4o`. Routing options belong in the request
  body's `provider` object. This adapter keeps OpenRouter defaults separate
  from the generic OpenAI-compatible provider.
  """

  @behaviour Handbean.Agent.Provider

  alias Handbean.Agent.Provider.OpenAICompat

  @default_base_url "https://openrouter.ai/api/v1"
  @default_model "openai/gpt-4o"

  @impl true
  def context_editing?, do: true

  @impl true
  def complete(messages, tool_defs, config) do
    config
    |> normalize_config()
    |> require_api_key()
    |> case do
      {:ok, normalized_config} ->
        OpenAICompat.complete(messages, tool_defs, normalized_config)

      {:error, :missing_api_key} ->
        {:error,
         "OPENROUTER_API_KEY not configured. Set `apiKey` in ~/.handbean/models.json, pass :api_key in config, or set OPENROUTER_API_KEY."}
    end
  end

  @impl true
  def stream(messages, tool_defs, config, on_chunk) do
    config
    |> normalize_config()
    |> require_api_key()
    |> case do
      {:ok, normalized_config} ->
        normalized_config =
          normalized_config
          |> Map.put(:stream, true)
          |> Map.put(:on_chunk, on_chunk)

        OpenAICompat.complete(messages, tool_defs, normalized_config)

      {:error, :missing_api_key} ->
        {:error,
         "OPENROUTER_API_KEY not configured. Set `apiKey` in ~/.handbean/models.json, pass :api_key in config, or set OPENROUTER_API_KEY."}
    end
  end

  defp normalize_config(config) do
    config
    |> Map.put_new(:base_url, @default_base_url)
    |> Map.put_new(:model, @default_model)
    |> maybe_put_openrouter_api_key()
    |> remap_provider_routing()
    |> maybe_put_ranking_headers()
  end

  defp maybe_put_openrouter_api_key(%{api_key: key} = config) when is_binary(key) and key != "",
    do: config

  defp maybe_put_openrouter_api_key(config) do
    case System.get_env("OPENROUTER_API_KEY") do
      key when is_binary(key) and key != "" -> Map.put(config, :api_key, key)
      _ -> config
    end
  end

  # OpenRouter's routing object is `provider` in the JSON body. Config still
  # accepts `:provider_options` (same key ZenMux uses) and remaps it so the
  # generic compat layer does not emit `provider_options`.
  defp remap_provider_routing(%{provider_routing: _} = config), do: config

  defp remap_provider_routing(%{provider_options: opts} = config) when not is_nil(opts) do
    config
    |> Map.put(:provider_routing, opts)
    |> Map.delete(:provider_options)
  end

  defp remap_provider_routing(config), do: config

  defp maybe_put_ranking_headers(config) do
    extra =
      []
      |> maybe_header("HTTP-Referer", config[:http_referer] || config[:referer])
      |> maybe_header("X-OpenRouter-Title", config[:app_title] || config[:title])

    case extra do
      [] -> config
      headers -> Map.update(config, :extra_headers, headers, &(headers ++ &1))
    end
  end

  defp maybe_header(headers, _name, value) when value in [nil, ""], do: headers
  defp maybe_header(headers, name, value) when is_binary(value), do: [{name, value} | headers]

  defp require_api_key(%{api_key: key} = config) when is_binary(key) and key != "",
    do: {:ok, config}

  defp require_api_key(_config), do: {:error, :missing_api_key}
end
