defmodule Handbean.Settings.ModelCatalog do
  @moduledoc """
  Read-only helpers over `models.json` provider entries for settings UIs.

  These describe stored catalog entries (API key presence, effective
  `maxTokens`) without resolving secrets or applying env overrides.
  """

  alias Handbean.Agent.ModelConfig

  @type key_status :: :missing | :configured | {:env, String.t()}

  @doc """
  Describe how a provider entry's `apiKey` is configured.

  Never returns the key itself.
  """
  @spec key_status(map() | nil) :: key_status()
  def key_status(nil), do: :missing

  def key_status(provider) when is_map(provider) do
    case provider["apiKey"] do
      "env:" <> var -> {:env, var}
      key when is_binary(key) and key != "" -> :configured
      _ -> :missing
    end
  end

  @doc """
  Effective `maxTokens` for a model, mirroring the runtime rule: a provider
  override wins over the model value.
  """
  @spec effective_max_tokens(map() | nil, map() | nil) :: %{
          value: pos_integer() | nil,
          source: :provider | :model | :unset
        }
  def effective_max_tokens(provider, model_meta) do
    cond do
      match?(%{"maxTokens" => n} when is_integer(n), provider) ->
        %{value: provider["maxTokens"], source: :provider}

      match?(%{"maxTokens" => n} when is_integer(n), model_meta) ->
        %{value: model_meta["maxTokens"], source: :model}

      true ->
        %{value: nil, source: :unset}
    end
  end

  @doc "The `max_tokens` a request for `composite_id` would use in `workspace_path`."
  @spec request_max_tokens(Path.t(), String.t()) ::
          {:ok, pos_integer() | nil} | {:error, String.t()}
  def request_max_tokens(workspace_path, composite_id) do
    with {:ok, config, _model_id} <-
           ModelConfig.resolve_model_for_workspace(workspace_path, composite_id) do
      {:ok, config[:max_tokens]}
    end
  end
end
