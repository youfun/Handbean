defmodule Handbean.Tool.Memory.Scope do
  @moduledoc false

  def options(context, extra \\ [])

  def options(context, extra) when is_map(context) and is_list(extra) do
    provenance =
      %{
        actor: :agent_tool,
        operation_conversation_id: context_value(context, :conversation_id),
        operation_run_id: context_value(context, :run_id),
        operation_tool_call_id: context_value(context, :tool_call_id),
        trigger_entry_id: context_value(context, :trigger_entry_id),
        citations: Keyword.get(extra, :citations, [])
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == [] end)
      |> Map.new()
      |> put_idempotency_key()

    [
      workspace_id: context_value(context, :workspace_id),
      memory_scope: context_value(context, :memory_scope),
      privacy_mode: context_value(context, :privacy_mode),
      provenance: provenance
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  def options(_context, _extra), do: []

  def citation_schema do
    %{
      type: "object",
      additionalProperties: false,
      properties: %{
        conversation_id: %{type: "string", description: "Source conversation ID"},
        entry_id: %{type: "string", description: "First source entry ID"},
        sequence: %{type: "integer", description: "First source entry sequence"},
        revision: %{type: "integer", description: "First source entry revision"},
        end_entry_id: %{type: "string", description: "Optional last source entry ID"},
        end_sequence: %{type: "integer", description: "Optional last source entry sequence"},
        end_revision: %{type: "integer", description: "Optional last source entry revision"}
      },
      required: ["conversation_id", "entry_id", "sequence", "revision"]
    }
  end

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

  defp put_idempotency_key(
         %{
           actor: :agent_tool,
           operation_conversation_id: conversation_id,
           operation_run_id: run_id,
           operation_tool_call_id: tool_call_id
         } = provenance
       )
       when is_binary(conversation_id) and conversation_id != "" and is_binary(run_id) and
              run_id != "" and is_binary(tool_call_id) and tool_call_id != "" do
    Map.put(
      provenance,
      :idempotency_key,
      "memory-tool:#{conversation_id}:#{run_id}:#{tool_call_id}"
    )
  end

  defp put_idempotency_key(provenance), do: provenance
end
