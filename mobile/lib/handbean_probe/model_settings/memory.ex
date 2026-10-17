defmodule HandbeanProbe.ModelSettings.Memory do
  @moduledoc """
  Observational memory processing fields of the Model/AI form (models, scope,
  privacy, recent-context limit). Saves through
  `HandbeanProbe.ModelSettings.Defaults`, so scope rules apply unchanged.
  """

  use Gettext, backend: HandbeanProbe.Gettext
  alias HandbeanProbe.ModelSettings.Defaults
  alias HandbeanProbe.SettingsSupport

  def set_model(state, model, workspace) do
    Defaults.save_field(state, workspace, :om_model, Defaults.blank_to_nil(model))
  end

  def set_scope(state, scope, workspace) do
    Defaults.save_field(state, workspace, :om_memory_scope, scope)
  end

  def set_privacy(state, mode, workspace) do
    Defaults.save_field(state, workspace, :om_privacy_mode, mode)
  end

  @doc "Validate the recent-context limit typed into the form, then save the form."
  def save_details(state, workspace) do
    case SettingsSupport.parse_non_negative(to_string(state.defaults.om_max_recent_context)) do
      {:ok, :omit} ->
        Defaults.save_form(state, workspace, state.defaults)

      {:ok, n} ->
        Defaults.save_form(state, workspace, %{state.defaults | om_max_recent_context: n})

      {:error, _} ->
        %{state | notice: gettext("Recent context limit must be zero or a positive integer")}
    end
  end
end
