defmodule Handbean.ChangeReverter do
  @moduledoc """
  Reverts a single recorded file change when the current file still matches
  the recorded after-state.
  """

  alias Handbean.ChangeSnapshot
  alias Handbean.Security.PathValidator

  @type result :: {:ok, map()} | {:conflict, map()} | {:error, map()}

  @spec revert(map(), Path.t()) :: result()
  def revert(change, workspace_root) when is_map(change) and is_binary(workspace_root) do
    with {:ok, normalized} <- normalize_change(change),
         :ok <- validate_reversible(normalized),
         :ok <- PathValidator.validate_within_workspace(normalized.file_path, workspace_root),
         {:ok, current_state} <- current_file_state(normalized.file_path),
         :ok <- validate_current_state(normalized, current_state),
         :ok <- apply_revert(normalized) do
      {:ok,
       %{
         "change_id" => normalized.change_id,
         "file_path" => normalized.file_path,
         "revert_status" => "reverted",
         "message" => success_message(normalized)
       }}
    else
      {:conflict, reason} ->
        {:conflict, conflict_result(change, reason)}

      {:error, reason} ->
        {:error, error_result(change, reason)}
    end
  end

  defp normalize_change(change) do
    file_path = value(change, "file_path")
    change_id = value(change, "change_id")

    cond do
      not is_binary(file_path) or file_path == "" ->
        {:error, "missing file_path"}

      not is_binary(change_id) or change_id == "" ->
        {:error, "missing change_id"}

      true ->
        {:ok,
         %{
           change_id: change_id,
           file_path: file_path,
           reversible: truthy?(value(change, "reversible")),
           existed_before: truthy?(value(change, "existed_before")),
           before_content: value(change, "before_content"),
           after_sha256: value(change, "after_sha256")
         }}
    end
  end

  defp validate_reversible(%{reversible: true}), do: :ok
  defp validate_reversible(_change), do: {:error, "change is not reversible"}

  defp current_file_state(file_path) do
    if File.exists?(file_path) do
      case File.read(file_path) do
        {:ok, content} -> {:ok, {:exists, content, ChangeSnapshot.sha256(content)}}
        {:error, reason} -> {:error, "failed to read current file: #{inspect(reason)}"}
      end
    else
      {:ok, :missing}
    end
  end

  defp validate_current_state(%{after_sha256: after_sha256}, {:exists, _content, after_sha256})
       when is_binary(after_sha256),
       do: :ok

  defp validate_current_state(%{existed_before: false}, :missing), do: :ok

  defp validate_current_state(%{existed_before: true}, :missing) do
    {:conflict, "file is missing; refusing to recreate it silently"}
  end

  defp validate_current_state(_change, {:exists, _content, _hash}) do
    {:conflict, "file changed since this diff"}
  end

  defp apply_revert(%{existed_before: true, before_content: before_content, file_path: file_path})
       when is_binary(before_content) do
    case File.write(file_path, before_content) do
      :ok -> :ok
      {:error, reason} -> {:error, "failed to restore file: #{inspect(reason)}"}
    end
  end

  defp apply_revert(%{existed_before: true}) do
    {:error, "missing before_content"}
  end

  defp apply_revert(%{existed_before: false, file_path: file_path}) do
    if File.exists?(file_path) do
      case File.rm(file_path) do
        :ok -> :ok
        {:error, reason} -> {:error, "failed to delete created file: #{inspect(reason)}"}
      end
    else
      :ok
    end
  end

  defp success_message(%{existed_before: true}), do: "Reverted file to the recorded before state."
  defp success_message(%{existed_before: false}), do: "Reverted by deleting the created file."

  defp conflict_result(change, reason) do
    base_result(change, "conflict", reason)
  end

  defp error_result(change, reason) do
    base_result(change, "error", reason)
  end

  defp base_result(change, status, reason) do
    %{
      "change_id" => value(change, "change_id"),
      "file_path" => value(change, "file_path"),
      "revert_status" => status,
      "message" => to_string(reason)
    }
  end

  defp value(map, key) when is_map(map) and is_binary(key) do
    Handbean.Utils.SafeMap.get(map, key)
  end

  defp truthy?(value), do: value in [true, "true", 1, "1"]
end
