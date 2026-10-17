defmodule Handbean.Agent.Provider.ZenMux do
  @moduledoc """
  ZenMux provider adapter.

  ZenMux exposes an OpenAI-compatible Chat Completions API at
  `https://zenmux.ai/api/v1/chat/completions`, but uses provider-prefixed model
  ids such as `openai/gpt-5` and may accept routing options. This adapter keeps
  ZenMux defaults separate from the generic OpenAI-compatible provider.
  """

  @behaviour Handbean.Agent.Provider

  alias Handbean.Agent.Provider.OpenAICompat

  @default_base_url "https://zenmux.ai/api/v1"
  @default_model "openai/gpt-5"

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
         "ZENMUX_API_KEY not configured. Set `apiKey` in ~/.handbean/models.json, pass :api_key in config, or set ZENMUX_API_KEY."}
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
         "ZENMUX_API_KEY not configured. Set `apiKey` in ~/.handbean/models.json, pass :api_key in config, or set ZENMUX_API_KEY."}
    end
  end

  defp normalize_config(config) do
    config
    |> Map.put_new(:base_url, @default_base_url)
    |> Map.put_new(:model, @default_model)
    |> maybe_put_zenmux_api_key()
  end

  defp maybe_put_zenmux_api_key(%{api_key: key} = config) when is_binary(key) and key != "",
    do: config

  defp maybe_put_zenmux_api_key(config) do
    case System.get_env("ZENMUX_API_KEY") do
      key when is_binary(key) and key != "" -> Map.put(config, :api_key, key)
      _ -> config
    end
  end

  defp require_api_key(%{api_key: key} = config) when is_binary(key) and key != "",
    do: {:ok, config}

  defp require_api_key(_config), do: {:error, :missing_api_key}
end
