defmodule HandbeanProbe.ModelSettings.Defaults do
  @moduledoc """
  Model/AI defaults (scope, default model, reasoning, inherit) for the native
  model settings. Persists through `Handbean.Settings.ModelAIOverride`.
  """

  use Gettext, backend: HandbeanProbe.Gettext
  alias Handbean.Agent.ModelConfig
  alias Handbean.Settings.ModelAIOverride
  alias HandbeanProbe.ModelSettings

  def set_scope(state, scope, _workspace) when scope in [:global, :workspace] do
    state
    |> ModelSettings.select_scope(scope)
    |> Map.put(:notice, nil)
  end

  def form_for_scope(:global, _workspace), do: Handbean.Settings.global_model_ai()

  def form_for_scope(:workspace, workspace) do
    case Handbean.Settings.fetch_effective_model_ai(workspace["path"]) do
      {:ok, settings} -> settings
      {:error, _} -> Handbean.Settings.global_model_ai()
    end
  end

  def set_default_model(state, model, workspace) do
    save_field(state, workspace, :default_model, blank_to_nil(model))
  end

  def set_reasoning(state, level, workspace), do: save_field(state, workspace, :reasoning, level)

  @doc "Save one field of the current scope's form, honouring the workspace policy."
  def save_field(state, workspace, field, value) do
    if field == :default_model and state.scope == :workspace and is_binary(value) and
         not ModelConfig.model_allowed_for_workspace?(workspace["path"], value) do
      %{state | notice: gettext("Workspace policy does not allow this model")}
    else
      save_form(state, workspace, Map.put(state.defaults, field, value))
    end
  end

  def save_form(state, workspace, form) do
    target = if state.scope == :global, do: :global, else: {:workspace, workspace["path"]}

    case ModelAIOverride.save(target, form) do
      :ok -> ModelSettings.reload(state, workspace, saved_notice())
      {:error, _} -> %{state | notice: save_failed()}
    end
  end

  def inherit(%{scope: :workspace} = state, field, workspace) do
    case ModelAIOverride.inherit(workspace["path"], [field]) do
      :ok -> %{ModelSettings.reload(state, workspace, saved_notice()) | scope: :workspace}
      {:error, _} -> %{state | notice: save_failed()}
    end
  end

  def inherit(state, _field, _workspace), do: state

  def inherit_all(%{scope: :workspace} = state, workspace) do
    case ModelAIOverride.inherit_all(workspace["path"]) do
      :ok -> %{ModelSettings.reload(state, workspace, saved_notice()) | scope: :workspace}
      {:error, _} -> %{state | notice: save_failed()}
    end
  end

  def inherit_all(state, _workspace), do: state

  def saved_notice, do: gettext("Saved. Takes effect on the next send.")
  def save_failed, do: gettext("Save failed. Check that the workspace is writable.")

  def blank_to_nil(""), do: nil
  def blank_to_nil(v), do: v
end
