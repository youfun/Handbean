defmodule Handbeam.Agent.Provider.Ollama do
  @moduledoc """
  Ollama Cloud subscription adapter.

  Pro and Max are usage-credit plans, not a separate protocol. Direct cloud
  access uses the OpenAI Chat Completions API at `https://ollama.com/v1`
  with `Authorization: Bearer`. Model ids come from `GET /api/tags`, such as
  `gemma4:31b`, not a fixed list or the local `:cloud` suffix.

  This is not the local daemon at `http://localhost:11434`.
  """

  @behaviour Handbeam.Agent.Provider

  alias Handbeam.Agent.Provider.{OpenAICompat, RequestIdentity}

  @default_base_url "https://ollama.com/v1"
  @default_model "gemma4:31b"

  @impl true
  def complete(messages, tool_defs, config) do
    config
    |> normalize_config()
    |> require_api_key()
    |> case do
      {:ok, normalized_config} ->
        OpenAICompat.complete(messages, tool_defs, normalized_config)

      {:error, :missing_api_key} ->
        {:error, missing_api_key_message()}
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
        {:error, missing_api_key_message()}
    end
  end

  defp normalize_config(config) do
    config
    |> Map.put_new(:base_url, @default_base_url)
    |> Map.put_new(:model, @default_model)
    |> maybe_put_ollama_api_key()
    |> put_identity_headers()
  end

  defp maybe_put_ollama_api_key(%{api_key: key} = config) when is_binary(key) and key != "",
    do: config

  defp maybe_put_ollama_api_key(config) do
    case System.get_env("OLLAMA_API_KEY") do
      key when is_binary(key) and key != "" -> Map.put(config, :api_key, key)
      _ -> config
    end
  end

  defp put_identity_headers(config) do
    headers = RequestIdentity.headers(config)
    Map.update(config, :extra_headers, headers, &(headers ++ &1))
  end

  defp require_api_key(%{api_key: key} = config) when is_binary(key) and key != "",
    do: {:ok, config}

  defp require_api_key(_config), do: {:error, :missing_api_key}

  defp missing_api_key_message do
    "OLLAMA_API_KEY not configured. Set `apiKey` in ~/.handbeam/models.json, " <>
      "pass :api_key in config, or set OLLAMA_API_KEY."
  end
end
