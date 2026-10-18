defmodule Handbean.Agent.Provider.SubscriptionCatalog do
  @moduledoc """
  Provider blocks for API-key coding subscriptions.

  Model rows are not stored here. Ollama Cloud comes from `GET /api/tags`.
  OpenCode Go comes from `GET /v1/models`.
  """

  @doc """
  Provider block written into `models.json` for an API-key subscription.

  `api` names the subscription. OpenCode Go still routes individual models
  to Chat Completions, Messages, or Responses. The model list stays empty
  until the user pulls it.
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
      "models" => []
    }
  end

  def preset(_provider_id), do: nil
end
