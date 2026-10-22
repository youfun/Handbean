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

  def set_reasoning(state, level, workspace) do
    Defaults.save_field(state, workspace, :om_reasoning, Defaults.blank_to_nil(level))
  end

  def set_enabled(state, enabled, workspace) when is_boolean(enabled) do
    Defaults.save_field(state, workspace, :om_reflector_enabled, enabled)
  end

  def set_workspace_builtin(state, id, enabled) when is_boolean(enabled) do
    case Enum.find(Map.get(state, :memory_workspaces, []), &(&1.id == id)) do
      %{path: path} when is_binary(path) and path != "" ->
        case Handbean.WorkspaceSettings.update_builtin_memory_enabled(path, enabled) do
          :ok ->
            rows =
              Enum.map(state.memory_workspaces, fn item ->
                if item.id == id, do: %{item | enabled: enabled}, else: item
              end)

            %{state | memory_workspaces: rows}

          {:error, _} ->
            %{state | notice: Defaults.save_failed()}
        end

      _ ->
        state
    end
  end

  @doc "Save memory reflection details from the current scope's form."
  def save_details(state, workspace) do
    Defaults.save_form(state, workspace, state.defaults)
  end
end
