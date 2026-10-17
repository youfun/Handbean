defmodule Handbeam.Agent.Provider.SubscriptionCatalog do
  @moduledoc """
  Built-in model rows for API-key coding subscriptions.

  Ollama Cloud is not listed here. Its models come from `GET /api/tags`.

  Prices are the vendor's per-million-token rates used to draw down the
  plan, not a separate Handbeam charge. Rows the user later disables stay
  disabled when a preset is merged back in.
  """

  @type model :: %{required(String.t()) => term()}

  @opencode_specs [
    {"glm-5.3-flash", "GLM-5.3 Flash", 200_000, 8_192, true,
     [input: 0.15, output: 0.50, cache_read: 0.03]},
    {"glm-5.3", "GLM-5.3", 200_000, 8_192, true, [input: 1.40, output: 4.40, cache_read: 0.26]},
    {"kimi-k3", "Kimi K3", 256_000, 8_192, true, [input: 3.00, output: 15.00, cache_read: 0.30]},
    {"kimi-k2.7-code", "Kimi K2.7 Code", 256_000, 8_192, true,
     [input: 0.95, output: 4.00, cache_read: 0.19]},
    {"deepseek-v4.1-flash", "DeepSeek V4.1 Flash", 1_000_000, 8_192, true,
     [input: 0.15, output: 0.60, cache_read: 0.003]},
    {"deepseek-v4-pro", "DeepSeek V4 Pro", 1_000_000, 8_192, true,
     [input: 0.66, output: 1.98, cache_read: 0.022]},
    {"minimax-m3", "MiniMax M3", 1_000_000, 8_192, true,
     [input: 0.30, output: 1.20, cache_read: 0.06]},
    {"qwen3.8-max", "Qwen3.8 Max", 256_000, 8_192, true,
     [input: 2.00, output: 6.00, cache_read: 0.25, cache_write: 2.50]},
    {"qwen3.8-flash", "Qwen3.8 Flash", 256_000, 8_192, true,
     [input: 0.15, output: 0.47, cache_read: 0.016, cache_write: 0.20]},
    {"mimo-v2.6-pro", "MiMo-V2.6 Pro", 256_000, 8_192, true,
     [input: 0.435, output: 0.87, cache_read: 0.003625]},
    {"mimo-v2.6-flash", "MiMo-V2.6 Flash", 256_000, 8_192, true,
     [input: 0.14, output: 0.28, cache_read: 0.0028]},
    {"gpt-5.6-luna", "GPT 5.6 Luna", 272_000, 8_192, true,
     [input: 0.20, output: 1.20, cache_read: 0.02, cache_write: 0.25]},
    {"grok-4.7", "Grok 4.7", 200_000, 8_192, true, [input: 2.00, output: 6.00, cache_read: 0.50]}
  ]

  @doc "OpenCode Go models. The adapter picks the wire protocol from the id."
  @spec opencode_go_models() :: [model()]
  def opencode_go_models, do: Enum.map(@opencode_specs, &model/1)

  @doc """
  Provider block written into `models.json` for an API-key subscription.

  `api` names the subscription. OpenCode Go still routes individual models
  to Chat Completions, Messages, or Responses.
  """
  @spec preset(String.t()) :: map() | nil
  def preset("ollama-cloud"), do: preset("ollama")
  def preset("ollama_cloud"), do: preset("ollama")
  def preset("opencode_go"), do: preset("opencode-go")

  def preset("ollama") do
    %{
      "name" => "Ollama",
      "baseUrl" => "https://ollama.com/v1",
      "api" => "ollama-cloud",
      "provider" => "ollama",
      "models" => []
    }
  end

  def preset("opencode-go") do
    %{
      "name" => "OpenCode Go",
      "baseUrl" => "https://opencode.ai/zen/go/v1",
      "api" => "opencode-go",
      "provider" => "opencode-go",
      "models" => opencode_go_models()
    }
  end

  def preset(_provider_id), do: nil

  defp model({id, name, context_window, max_tokens, reasoning, costs}) do
    input = Keyword.fetch!(costs, :input)
    output = Keyword.fetch!(costs, :output)
    cache_read = Keyword.get(costs, :cache_read, 0)
    cache_write = Keyword.get(costs, :cache_write, 0)

    %{
      "id" => id,
      "name" => name,
      "reasoning" => reasoning,
      "input" => ["text"],
      "contextWindow" => context_window,
      "maxTokens" => max_tokens,
      "cost" => %{
        "input" => input,
        "output" => output,
        "cacheRead" => cache_read,
        "cacheWrite" => cache_write
      }
    }
  end
end
