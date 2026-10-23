defmodule Handbean.Agent.ModelConfig.Policy do
  @moduledoc false

  alias Handbean.Agent.ModelConfig.Loader

  @doc """
  Returns the path to the workspace-level settings file that contains model policy.
  """
  @spec workspace_policy_path(Path.t()) :: Path.t()
  def workspace_policy_path(workspace_root) do
    Handbean.WorkspaceSettings.path(workspace_root)
  end

  @doc """
  Load the workspace-level model access policy.

  Returns:
    - `:unrestricted` when settings or `models` are absent → all global models allowed
    - `{:ok, policy_map}` when a valid `models` settings block exists
    - `{:error, reason}` when the settings file is malformed (no fallback!)
  """
  @spec load_workspace_policy(Path.t()) :: :unrestricted | {:ok, map()} | {:error, String.t()}
  def load_workspace_policy(workspace_root) do
    Handbean.WorkspaceSettings.models_policy(workspace_root)
  end

  @doc """
  List available models for a workspace, respecting the policy if present.

  Returns a list of model maps with `:id` (composite `provider_id/model_id`),
  `:name`, `:provider_id`, and `:model_id` keys.
  """
  @spec available_models_for_workspace(Path.t()) :: [map()]
  def available_models_for_workspace(workspace_root, opts \\ []) do
    all_models = Loader.models_for_workspace(Keyword.get(opts, :checkout_path, workspace_root))

    case load_workspace_policy(workspace_root) do
      :unrestricted ->
        all_models

      {:ok, policy} ->
        filter_models_by_policy(all_models, policy)

      {:error, _reason} ->
        []
    end
  end

  @doc """
  Returns the default model id for a workspace.

  - Unrestricted → global default model (from provider_config)
  - Restricted with valid policy default in allowlist → composite id
  - Restricted, default not in allowlist → first allowed model
  - Restricted, no allowed models → nil
  - Malformed policy → nil
  """
  @spec default_model_for_workspace(Path.t()) :: String.t() | nil
  def default_model_for_workspace(workspace_root, opts \\ []) do
    available = available_models_for_workspace(workspace_root, opts)

    case load_workspace_policy(workspace_root) do
      :unrestricted ->
        config = Loader.provider_config(workspace_root)
        default_provider = config[:provider_key]
        default_model = config[:model]

        composite =
          if default_provider && default_model, do: "#{default_provider}/#{default_model}"

        if composite && Enum.any?(available, &(&1.id == composite)) do
          composite
        else
          available |> List.first() |> then(&if &1, do: &1.id)
        end

      {:ok, policy} ->
        default = Map.get(policy, "default", %{})
        default_provider = Map.get(default, "provider")
        default_model_id = Map.get(default, "model")

        if default_provider && default_model_id do
          composite = "#{default_provider}/#{default_model_id}"

          if Enum.any?(available, &(&1.id == composite)) do
            composite
          else
            available |> List.first() |> then(&if(&1, do: &1.id))
          end
        else
          available |> List.first() |> then(&if(&1, do: &1.id))
        end

      {:error, _reason} ->
        nil
    end
  end

  @doc """
  Return the explicitly configured default model only when it is currently available.

  Unlike `default_model_for_workspace/1`, this never substitutes another catalog
  entry when the configured default is missing or invalid.
  """
  @spec strict_default_model_for_workspace(Path.t()) :: String.t() | nil
  def strict_default_model_for_workspace(workspace_root, opts \\ []) do
    available_ids =
      workspace_root
      |> available_models_for_workspace(opts)
      |> Enum.map(& &1.id)
      |> MapSet.new()

    configured =
      case load_workspace_policy(workspace_root) do
        :unrestricted ->
          Loader.configured_default_model()

        {:ok, policy} ->
          default = Map.get(policy, "default", %{})
          composite_model_id(default["provider"], default["model"])

        {:error, _reason} ->
          nil
      end

    if is_binary(configured) and MapSet.member?(available_ids, configured), do: configured
  end

  @doc """
  Check whether a composite model id is allowed in the workspace.
  """
  @spec model_allowed_for_workspace?(Path.t(), String.t()) :: boolean()
  def model_allowed_for_workspace?(workspace_root, model_id, opts \\ []) do
    available = available_models_for_workspace(workspace_root, opts)
    Enum.any?(available, &model_matches?(&1, model_id))
  end

  defp composite_model_id(provider, model)
       when is_binary(provider) and provider != "" and is_binary(model) and model != "",
       do: provider <> "/" <> model

  defp composite_model_id(_provider, _model), do: nil

  defp model_matches?(model, model_id) do
    model.id == model_id or model.model_id == model_id
  end

  @doc """
  Resolve a composite model id to the actual model_id and provider config.

  Returns `{:ok, provider_config, actual_model_id}` or `{:error, reason}`.
  """
  @spec resolve_model_for_workspace(Path.t(), String.t()) ::
          {:ok, map(), String.t()} | {:error, String.t()}
  def resolve_model_for_workspace(workspace_root, composite_id, opts \\ []) do
    available = available_models_for_workspace(workspace_root, opts)

    model_entry = Enum.find(available, &(&1.id == composite_id))

    if model_entry do
      provider_id = model_entry.provider_id
      actual_model_id = model_entry.model_id

      checkout = Keyword.get(opts, :checkout_path, workspace_root)

      case Loader.provider_config_for(checkout, provider_id, actual_model_id) do
        {:ok, provider_config} ->
          {:ok, provider_config, actual_model_id}

        {:error, _} = error ->
          error
      end
    else
      {:error, "Model #{composite_id} is not allowed in this workspace"}
    end
  end

  @doc """
  Resolve a composite model id from the unrestricted global catalog.

  Returns `{:ok, provider_config, actual_model_id}` or `{:error, reason}`.
  """
  @spec resolve_global_model(String.t()) ::
          {:ok, map(), String.t()} | {:error, String.t()}
  def resolve_global_model(composite_id) do
    case Enum.find(Loader.all_global_models(), &(&1.id == composite_id)) do
      nil ->
        {:error, "Model #{composite_id} is not available"}

      model_entry ->
        case Loader.provider_config_for(
               :global,
               model_entry.provider_id,
               model_entry.model_id
             ) do
          {:ok, provider_config} -> {:ok, provider_config, model_entry.model_id}
          {:error, _} = error -> error
        end
    end
  end

  defp filter_models_by_policy(all_models, policy) do
    allow = Map.get(policy, "allow", %{})
    allowed_providers = allowed_providers_from_allow(allow)

    if allowed_providers == %{} do
      all_models
    else
      Enum.filter(all_models, fn model ->
        case Map.get(allowed_providers, model.provider_id) do
          %{"models" => allowed_model_ids} when is_list(allowed_model_ids) ->
            model.model_id in allowed_model_ids

          _ ->
            false
        end
      end)
    end
  end

  defp allowed_providers_from_allow(%{"providers" => providers}) when is_map(providers),
    do: providers

  defp allowed_providers_from_allow(allow) when is_map(allow), do: allow
  defp allowed_providers_from_allow(_allow), do: %{}
end
