defmodule HandbeanProbe.ModelSettings.Memory do
  @moduledoc """
  Memory reflection settings in the native Model/AI form. Saves through
  `HandbeanProbe.ModelSettings.Defaults`, so scope rules apply unchanged.
  """

  alias HandbeanProbe.ModelSettings.Defaults

  def set_model(state, model, workspace) do
    Defaults.save_field(state, workspace, :om_model, Defaults.blank_to_nil(model))
  end

  def set_scope(state, scope, workspace) do
    Defaults.save_field(state, workspace, :om_memory_scope, scope)
  end

  def set_privacy(state, mode, workspace) do
    Defaults.save_field(state, workspace, :om_privacy_mode, mode)
  end

  @doc "Save memory reflection details from the current scope's form."
  def save_details(state, workspace) do
    Defaults.save_form(state, workspace, state.defaults)
  end
end
