defmodule Handbean.Tool.Memory.Scope do
  @moduledoc false

  def options(context) when is_map(context) do
    [
      workspace_id: context_value(context, :workspace_id),
      memory_scope: context_value(context, :memory_scope),
      privacy_mode: context_value(context, :privacy_mode)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  def options(_context), do: []

  def error_message(:invalid_scope),
    do: "A valid explicit memory scope is required for this operation"

  def error_message(:not_found),
    do: "No accessible memory found with that id"

  def error_message(:scope_mismatch),
    do: "Memories can only be associated within the same workspace or when both are global"

  def error_message(%Ecto.Changeset{} = changeset),
    do: "Memory operation failed: #{inspect(changeset.errors)}"

  def error_message(reason), do: "Memory operation failed: #{inspect(reason)}"

  defp context_value(context, key),
    do: Map.get(context, key) || Map.get(context, Atom.to_string(key))
end
