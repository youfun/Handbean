defmodule HandbeanProbe.ModelSettings.Policy do
  @moduledoc """
  Workspace model allowlist editing for the native model settings.

  The form shape is `Handbean.Settings.ModelPolicy.form/1`; edits stay in memory
  until `save/2`.
  """

  use Gettext, backend: HandbeanProbe.Gettext
  alias Handbean.Agent.ModelConfig
  alias Handbean.Settings.ModelPolicy
  alias HandbeanProbe.ModelSettings
  alias HandbeanProbe.ModelSettings.Defaults

  def set_mode(state, mode) when mode in [:unrestricted, :restricted] do
    %{state | policy: %{state.policy | mode: mode}}
  end

  def set_mode(state, _mode), do: state

  def toggle_model(state, provider, model) do
    allowed = Map.get(state.policy, :allowed, %{})
    models = Map.get(allowed, provider, MapSet.new())

    models =
      if MapSet.member?(models, model),
        do: MapSet.delete(models, model),
        else: MapSet.put(models, model)

    allowed =
      if MapSet.size(models) == 0,
        do: Map.delete(allowed, provider),
        else: Map.put(allowed, provider, models)

    policy =
      state.policy
      |> Map.put(:mode, :restricted)
      |> Map.put(:allowed, allowed)
      |> clear_invalid_default()

    %{state | policy: policy}
  end

  def set_default(state, model) do
    %{state | policy: Map.put(state.policy, :default_model, Defaults.blank_to_nil(model))}
  end

  def set_provider_models(state, provider, :all) when is_binary(provider) do
    ids =
      state.models
      |> Enum.filter(&(&1.provider_id == provider))
      |> Enum.map(& &1.model_id)
      |> MapSet.new()

    allowed = Map.put(state.policy.allowed || %{}, provider, ids)
    %{state | policy: %{state.policy | mode: :restricted, allowed: allowed}}
  end

  def set_provider_models(state, provider, :none) when is_binary(provider) do
    allowed = Map.delete(state.policy.allowed || %{}, provider)

    policy =
      state.policy
      |> Map.put(:mode, :restricted)
      |> Map.put(:allowed, allowed)
      |> clear_invalid_default()

    %{state | policy: policy}
  end

  def set_provider_models(state, _provider, _action), do: state

  def save(state, workspace) do
    case ModelPolicy.save(workspace["path"], state.policy) do
      :ok -> ModelSettings.reload(state, workspace, Defaults.saved_notice())
      {:error, _} -> %{state | notice: Defaults.save_failed()}
    end
  end

  @doc "Why chat is blocked by the workspace policy, or `nil`."
  def chat_blocked(path, allowed, default) do
    policy = ModelConfig.load_workspace_policy(path)

    cond do
      match?({:error, _}, policy) ->
        gettext("Workspace model policy is invalid. Fix settings before sending.")

      allowed == [] and restricted_allowlist?(policy) ->
        gettext("No model is allowed in this workspace. Fix the allowlist before sending.")

      is_binary(default) and allowed != [] and not Enum.any?(allowed, &(&1.id == default)) ->
        gettext("Current default model is not allowed. Choose an allowed model before sending.")

      true ->
        nil
    end
  end

  defp restricted_allowlist?({:ok, policy}) do
    allow = Map.get(policy, "allow", %{})
    providers = Map.get(allow, "providers", allow)
    is_map(providers) and providers != %{}
  end

  defp restricted_allowlist?(_), do: false

  defp clear_invalid_default(%{default_model: nil} = policy), do: policy

  defp clear_invalid_default(%{default_model: default} = policy) do
    allowed? =
      case String.split(to_string(default), "/", parts: 2) do
        [provider, model] ->
          policy.allowed |> Map.get(provider, MapSet.new()) |> MapSet.member?(model)

        _ ->
          false
      end

    if allowed?, do: policy, else: Map.put(policy, :default_model, nil)
  end
end
