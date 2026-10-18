defmodule Handbean.Tool.Builtin.ArtifactFile do
  @moduledoc false

  alias Handbean.ArtifactDelivery
  alias Handbean.ArtifactDelivery.Input
  alias Handbean.ExportSnapshot.Binding

  @path_keys ["path", "description"]

  def take_path(input) do
    with {:ok, fields} <- Input.take(input, @path_keys),
         path when is_binary(path) and path != "" <- fields["path"],
         {:ok, rel} <- relative_path(path) do
      {:ok, rel, fields["description"]}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_path}
    end
  end

  def execute(op, input, context) when op in [:open_file, :share_file] do
    workspace = context[:working_directory]
    conversation_id = context[:conversation_id] || "anon"
    tool_call_id = context[:tool_call_id]

    with {:ok, rel, _desc} <- take_path(input),
         {:ok, binding} <-
           resolve_binding(conversation_id, tool_call_id, rel, op, workspace),
         {:ok, result} <-
           ArtifactDelivery.dispatch(
             %{
               op: op,
               snapshot_id: field(binding, :snapshot_id),
               owner_request_id: field(binding, :owner_request_id),
               relative_path: rel
             },
             context
           ) do
      finish(result)
    else
      {:error, :raw_intent_rejected} ->
        {:error, "raw Intent fields are not allowed"}

      {:error, :unexpected_fields} ->
        {:error, "only a workspace-relative path is accepted"}

      {:error, :invalid_path} ->
        {:error, "path must be a workspace-relative file"}

      {:error, :too_large} ->
        {:error, "file exceeds the export size limit"}

      {:error, :unavailable} ->
        {:error, "file open/share is not available on this host"}

      {:error, :snapshot_mismatch} ->
        {:error, "the approved export copy does not match this path"}

      {:error, :file_unavailable} ->
        {:error, ArtifactDelivery.format_outcome("file_unavailable")}

      {:error, :timeout} ->
        {:error, ArtifactDelivery.format_outcome("cancelled_before_launch")}

      {:error, reason} ->
        {:error, ArtifactDelivery.format_outcome(to_string(reason))}
    end
  end

  defp resolve_binding(conversation_id, tool_call_id, rel, op, workspace)
       when is_binary(tool_call_id) and is_binary(workspace) do
    Binding.consume(conversation_id, tool_call_id, %{
      workspace_path: workspace,
      relative_path: rel,
      action: op
    })
  end

  defp resolve_binding(_, _, _, _, _), do: {:error, :file_unavailable}

  defp field(map, key) when is_atom(key) do
    Handbean.Utils.SafeMap.get_any(map, [key, Atom.to_string(key)])
  end

  # Same component rule as WorkspaceFiles.relative_names/1: only a literal
  # ".." path component is traversal; "foo..bar.txt" is a plain file name.
  defp relative_path(path) do
    cond do
      String.trim(path) == "" -> {:error, :invalid_path}
      String.contains?(path, <<0>>) -> {:error, :invalid_path}
      Path.type(path) == :absolute -> {:error, :invalid_path}
      ".." in Path.split(path) -> {:error, :invalid_path}
      true -> {:ok, path}
    end
  end

  defp finish(%{outcome: outcome} = result) do
    text = ArtifactDelivery.format_outcome(outcome)
    details = Map.take(result, [:outcome, :snapshot_id, :relative_path])

    if ArtifactDelivery.presented?(outcome) do
      {:ok, text, details}
    else
      {:error, text, details}
    end
  end

  defp finish(result) when is_map(result) do
    finish(%{
      outcome:
        to_string(
          Handbean.Utils.SafeMap.get_any(result, :outcome, "outcome") ||
            "outcome_unknown"
        ),
      snapshot_id: Handbean.Utils.SafeMap.get_any(result, :snapshot_id, "snapshot_id"),
      relative_path: Handbean.Utils.SafeMap.get_any(result, :relative_path, "relative_path")
    })
  end

  defp finish(_), do: {:error, ArtifactDelivery.format_outcome("outcome_unknown")}
end
