defmodule Handbean.Agent.Provider.OpenCodeGo do
  @moduledoc """
  OpenCode Go subscription adapter.

  One API key and one base URL (`https://opencode.ai/zen/go/v1`) serve three
  wire protocols. The catalog comes from `GET /v1/models`. The model id selects the path:

    * Chat Completions for GLM, Kimi, DeepSeek, MiMo, and Hy
    * Anthropic Messages for MiniMax and Qwen
    * OpenAI Responses for Grok, GPT, and Muse Spark

  Go asks coding agents to send a dedicated user agent and a stable
  `x-opencode-session` header per conversation. Both are attached here.
  """

  @behaviour Handbean.Agent.Provider

  alias Handbean.Agent.Provider.{Anthropic, OpenAI, OpenAICompat, RequestIdentity}

  @default_base_url "https://opencode.ai/zen/go/v1"
  @default_model "glm-5.3-flash"

  @messages_models ~w(
    minimax-m3
    minimax-m2.7
    minimax-m2.5
    qwen3.8-max
    qwen3.8-flash
    qwen3.7-max
    qwen3.7-plus
    qwen3.6-plus
  )

  @responses_models ~w(
    grok-4.7
    grok-4.6
    gpt-6-luna
    gpt-5.6-luna
    muse-spark-1.3-contributor
    muse-spark-1.2-contributor
  )

  @impl true
  def complete(messages, tool_defs, config) do
    dispatch(messages, tool_defs, config, nil)
  end

  @impl true
  def stream(messages, tool_defs, config, on_chunk) do
    dispatch(messages, tool_defs, config, on_chunk)
  end

  @doc """
  Wire protocol for a Go model id.

  Unknown ids stay on Chat Completions, which is the path used by the
  majority of the current catalog.
  """
  @spec api_for(String.t() | nil) :: :openai | :anthropic | :openai_responses
  def api_for(model) when is_binary(model) do
    cond do
      model in @messages_models -> :anthropic
      model in @responses_models -> :openai_responses
      true -> :openai
    end
  end

  def api_for(_model), do: :openai

  defp dispatch(messages, tool_defs, config, on_chunk) do
    config
    |> normalize_config()
    |> require_api_key()
    |> case do
      {:ok, normalized_config} ->
        call(messages, tool_defs, normalized_config, on_chunk)

      {:error, :missing_api_key} ->
        {:error, missing_api_key_message()}
    end
  end

  defp call(messages, tool_defs, config, on_chunk) do
    case api_for(config[:model]) do
      :anthropic ->
        call_anthropic(messages, tool_defs, config, on_chunk)

      :openai_responses ->
        call_responses(messages, tool_defs, config, on_chunk)

      :openai ->
        call_chat(messages, tool_defs, config, on_chunk)
    end
  end

  defp call_chat(messages, tool_defs, config, nil) do
    OpenAICompat.complete(messages, tool_defs, config)
  end

  defp call_chat(messages, tool_defs, config, on_chunk) do
    config = config |> Map.put(:stream, true) |> Map.put(:on_chunk, on_chunk)
    OpenAICompat.complete(messages, tool_defs, config)
  end

  defp call_anthropic(messages, tool_defs, config, nil) do
    Anthropic.complete(messages, tool_defs, anthropic_config(config))
  end

  defp call_anthropic(messages, tool_defs, config, on_chunk) do
    Anthropic.stream(messages, tool_defs, anthropic_config(config), on_chunk)
  end

  defp call_responses(messages, tool_defs, config, nil) do
    OpenAI.complete(messages, tool_defs, responses_config(config))
  end

  defp call_responses(messages, tool_defs, config, on_chunk) do
    OpenAI.stream(messages, tool_defs, responses_config(config), on_chunk)
  end

  # Go's Messages route is `{base}/v1/messages`, while Anthropic appends
  # `/v1/messages` itself. Strip the version segment so the path is not doubled.
  defp anthropic_config(config) do
    config
    |> Map.put(:api_url, strip_v1(config[:base_url]))
    |> Map.put(:api, :anthropic)
    |> Map.put(:auth_header, "authorization")
  end

  # Responses appends `/v1/responses`. The Go catalog already includes `/v1`.
  defp responses_config(config) do
    config
    |> Map.put(:api_url, strip_v1(config[:base_url]))
    |> Map.put(:api, :openai_responses)
  end

  defp strip_v1(base) when is_binary(base) do
    base
    |> String.trim_trailing("/")
    |> String.replace_suffix("/v1", "")
  end

  defp strip_v1(_base), do: String.replace_suffix(@default_base_url, "/v1", "")

  defp normalize_config(config) do
    config
    |> Map.put_new(:base_url, @default_base_url)
    |> Map.put_new(:model, @default_model)
    |> maybe_put_opencode_api_key()
    |> put_identity_headers()
  end

  defp maybe_put_opencode_api_key(%{api_key: key} = config) when is_binary(key) and key != "",
    do: config

  defp maybe_put_opencode_api_key(config) do
    case System.get_env("OPENCODE_GO_API_KEY") do
      key when is_binary(key) and key != "" -> Map.put(config, :api_key, key)
      _ -> config
    end
  end

  defp put_identity_headers(config) do
    headers = RequestIdentity.headers(config, session: true)
    Map.update(config, :extra_headers, headers, &(headers ++ &1))
  end

  defp require_api_key(%{api_key: key} = config) when is_binary(key) and key != "",
    do: {:ok, config}

  defp require_api_key(_config), do: {:error, :missing_api_key}

  defp missing_api_key_message do
    "OPENCODE_GO_API_KEY not configured. Set `apiKey` in ~/.handbean/models.json, " <>
      "pass :api_key in config, or set OPENCODE_GO_API_KEY."
  end
end
