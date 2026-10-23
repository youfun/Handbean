defmodule Handbean.Extension.Provider do
  @moduledoc """
  Behaviour and Agent.Provider adapter for trusted extension model providers.

  Implement `name/0` (`ext:<extension>:<provider>`) and the normal provider
  `complete/3` contract. `stream/4` is optional. Each request resolves the
  currently registered implementation in its original selection scope.
  """

  @behaviour Handbean.Agent.Provider
  @callback name() :: String.t()
  @callback complete([Handbean.Agent.Message.t()], [map()], map()) ::
              {:ok, Handbean.Agent.Provider.completion_response()} | {:error, term()}
  @callback stream([Handbean.Agent.Message.t()], [map()], map(), function()) ::
              {:ok, Handbean.Agent.Provider.completion_response()} | {:error, term()}
  @optional_callbacks stream: 4

  alias Handbean.Extension.Registry

  def models(scope) do
    Registry.capabilities(:providers, scope)
    |> Enum.flat_map(fn provider ->
      provider.declaration["models"]
      |> Enum.reject(&(&1["enabled"] == false))
      |> Enum.map(fn model ->
        %{
          id: provider.name <> "/" <> model["id"],
          name: model["name"] || model["id"],
          provider_id: provider.name,
          model_id: model["id"],
          input: model["input"] || [],
          reasoning: model["reasoning"],
          reasoning_levels: model["reasoningLevels"] || [],
          default_reasoning: model["defaultReasoning"],
          thinking_level_map: model["thinkingLevelMap"] || %{},
          context_window: model["contextWindow"],
          max_tokens: model["maxTokens"],
          cost: model["cost"] || %{},
          enabled: true
        }
      end)
    end)
  end

  def config(scope, provider_id, model_id) do
    with {:ok, provider, model} <- resolve(scope, provider_id, model_id) do
      declaration = provider.declaration

      {:ok,
       %{
         api: :extension,
         provider: provider_id,
         provider_key: provider_id,
         extension_scope: scope,
         working_directory: if(is_binary(scope), do: scope),
         extension_generation: provider.revision,
         model: model["id"],
         model_meta: model,
         base_url: declaration["base_url"],
         api_key: api_key(declaration["api_key_env"]),
         max_tokens: model["maxTokens"]
       }}
    end
  end

  @impl true
  def complete(messages, tools, config) do
    with {:ok, provider} <- current_provider(config) do
      provider.module.complete(messages, tools, config)
    end
  end

  @impl true
  def stream(messages, tools, config, on_chunk) do
    with {:ok, provider} <- current_provider(config) do
      if function_exported?(provider.module, :stream, 4) do
        provider.module.stream(messages, tools, config, on_chunk)
      else
        provider.module.complete(messages, tools, config)
      end
    end
  end

  @impl true
  def context_editing?, do: false

  defp current_provider(config) do
    with {:ok, provider, _model} <-
           resolve(config[:extension_scope], config[:provider_key], config[:model]),
         :ok <- validate_request_scope(config, provider) do
      if provider.revision == config[:extension_generation],
        do: {:ok, provider},
        else: {:error, "Extension provider changed; select the model again"}
    end
  end

  defp validate_request_scope(_config, %{scope: :user}), do: :ok

  defp validate_request_scope(%{extension_scope: scope, working_directory: cwd}, _provider)
       when is_binary(scope) and is_binary(cwd) do
    with {:ok, canonical} <- Handbean.Security.PathValidator.canonicalize(scope),
         {:ok, ^canonical} <- Handbean.Security.PathValidator.canonicalize(cwd) do
      :ok
    else
      _ -> {:error, "Extension provider selection belongs to a different checkout"}
    end
  end

  defp validate_request_scope(_, _), do: {:error, "Extension provider scope is unavailable"}

  defp resolve(scope, provider_id, model_id) do
    provider = Enum.find(Registry.capabilities(:providers, scope), &(&1.name == provider_id))
    models = if provider, do: provider.declaration["models"], else: []
    model = Enum.find(models, &(&1["id"] == model_id and &1["enabled"] != false))

    if provider && model,
      do: {:ok, provider, model},
      else: {:error, "Extension provider or model is unavailable in this scope"}
  end

  defp api_key(name) when is_binary(name) and name != "", do: System.get_env(name)
  defp api_key(_), do: nil
end
